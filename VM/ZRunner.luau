---------------------------------------------------------------------
-- The interpreter loop. Mirrors interpret() and direct_call() in Frotz's
-- process.c, and wraps a whole run in the top-level error handling.
--
-- Everything here runs in the one VM coroutine. A nested direct call is an
-- ordinary nested call to `interpret`, so a page fault inside it suspends
-- the whole stack, outer instruction included, and resumes intact.
---------------------------------------------------------------------

local ZState = require("ZState.luau")
local ZOpcodes = require("ZOpcodes.luau")

local ZRunner = {}

-- Raised from a direct call whose routine ended the story. It unwinds the
-- instruction that made the call (a timed read) without letting it carry
-- on, and `play` recognises it.
local QUIT = { quit = true }
ZRunner.QUIT = QUIT

-- Runs instructions until one of them raises `finished` (a direct call's
-- routine returning, or quit), then consumes one count. `quit` sets
-- `finished` to 9999 so that every nested level unwinds.
local function interpret(state: ZState.ZState): ()
    repeat
        state:tick()
        ZOpcodes.step(state)
    until state.finished ~= 0
    state.finished -= 1
end
ZRunner.interpret = interpret

-- Calls a routine to completion and returns its result: used for the
-- routine of a timed read. The nested run overwrites the operands of the
-- instruction that is waiting, so they are saved and restored by value.
function ZRunner.directCall(state: ZState.ZState, routine: number): number
    local savedArgs = table.clone(state.zargs)
    local savedCount = state.zargc

    state:call(routine, 0, {}, ZState.CallType.DIRECT)
    interpret(state)

    if state.finished ~= 0 then
        -- The routine quit the story: `finished` is still counting the
        -- levels down.
        error(QUIT)
    end

    for i = 1, 8 do
        state.zargs[i] = savedArgs[i]
    end
    state.zargc = savedCount
    return state:pop()
end

-- Runs the story from its current position to the end, then tells the
-- Text Service how it ended so it can print the closing line or the
-- error. Returns "quit" or "fatal", and for "fatal" the error table.
function ZRunner.play(state: ZState.ZState, client: any): (string, any)
    local ok, err = pcall(interpret, state)
    if ok or err == QUIT then
        client:finish("quit")
        return "quit"
    end
    -- A fatal Z-machine error is a table with code, pc and message; a
    -- plain string is a bug in the interpreter itself.
    if typeof(err) ~= "table" then
        err = { fatal = true, code = 0, message = tostring(err), pc = state.pc }
    end
    err.start = state.instructionStart
    client:finish("fatal", err)
    return "fatal", err
end

return ZRunner

---------------------------------------------------------------------
-- Tests for ZRunner: the interpreter loop, direct calls (the routine of a
-- timed read), and the top-level play wrapper. Small programs are written
-- into the scratch region of dynamic memory and run through the real
-- dispatcher. No Text Service is needed: `play` is given a recording
-- client.
--
-- Requires the "ZMachine ROM" cards and the Memory Manager. Mutates
-- dynamic memory.
---------------------------------------------------------------------

local ZState = require("../VM/ZState.luau")
local ZRunner = require("../VM/ZRunner.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

-- Inverts ZState:unpackRoutine for a byte address.
local function packRoutine(state: ZState.ZState, byteAddress: number): number
    local version = state.header.version
    if version <= 3 then
        return byteAddress / 2
    elseif version <= 5 then
        return byteAddress / 4
    elseif version <= 7 then
        return (byteAddress - state.header.routinesOffset * 8) / 4
    end
    return byteAddress / 8
end

local function runAllTests()
    local memory = TestFramework.loadMemory(NOTECARD_NAME, { ramFlatLimit = 0 })
    if not memory then
        return
    end
    local state = TestFramework.freshState(memory)
    local base = TestFramework.scratchBase(state)

    -- Writes a routine (no locals) at base + 16 and returns its packed address.
    local function routine(body: { number }): number
        local bytes = { 0 }
        for _, byte in body do
            table.insert(bytes, byte)
        end
        TestFramework.writeBytesAt(state, base + 16, bytes)
        return packRoutine(state, base + 16)
    end

    local function recordingClient()
        local client: any = { finished = {} }
        function client:finish(reason: string, err: any)
            table.insert(self.finished, { reason, err })
        end
        return client
    end

    runTest("interpret runs instructions until quit and consumes one finished count", function()
        TestFramework.writeBytesAt(state, base, { 0xB4, 0xB4, 0xBA })  -- nop nop quit
        state.pc = base
        state.finished = 0
        ZRunner.interpret(state)
        assertEqual(state.pc, base + 3)
        assertEqual(state.finished, 9998, "quit sets 9999 and the loop takes one")
        state.finished = 0
    end)

    runTest("directCall returns the routine's result", function()
        state.finished = 0
        assertEqual(ZRunner.directCall(state, routine({ 0xB0 })), 1, "rtrue")
        assertEqual(ZRunner.directCall(state, routine({ 0xB1 })), 0, "rfalse")
        assertEqual(ZRunner.directCall(state, routine({ 0x9B, 5 })), 5, "ret 5")
        assertEqual(state.finished, 0)
    end)

    runTest("directCall leaves pc, the stack and the operands of the waiting instruction alone", function()
        state.finished = 0
        state.pc = base + 3
        state.zargs[1], state.zargs[2], state.zargc = 77, 88, 2
        local sp, fp, frames = state.sp, state.fp, state.frameCount
        ZRunner.directCall(state, routine({ 0xB0 }))
        assertEqual(state.pc, base + 3)
        assertEqual(state.sp, sp)
        assertEqual(state.fp, fp)
        assertEqual(state.frameCount, frames)
        assertEqual(state.zargs[1], 77)
        assertEqual(state.zargs[2], 88)
        assertEqual(state.zargc, 2)
    end)

    runTest("a routine that quits raises the quit marker instead of returning", function()
        state.finished = 0
        local packed = routine({ 0xBA })
        local ok, err = pcall(ZRunner.directCall, state, packed)
        assertEqual(ok, false)
        assertTrue(err == ZRunner.QUIT, "the quit marker")
        state.finished = 0
    end)

    runTest("play: a story that quits is finished with 'quit'", function()
        TestFramework.writeBytesAt(state, base, { 0xB4, 0xBA })
        state.pc = base
        state.finished = 0
        local client = recordingClient()
        assertEqual(ZRunner.play(state, client), "quit")
        assertEqual(#client.finished, 1)
        assertEqual(client.finished[1][1], "quit")
        state.finished = 0
    end)

    runTest("play: a fatal error is finished with 'fatal' and the error table", function()
        TestFramework.writeBytesAt(state, base, { 0xBE, 0x10, 0xFF })  -- move_window: unsupported
        state.pc = base
        state.finished = 0
        local client = recordingClient()
        assertEqual(ZRunner.play(state, client), "fatal")
        assertEqual(client.finished[1][1], "fatal")
        assertEqual(client.finished[1][2].code, ZState.Errors.UNSUPPORTED)
        assertTrue(client.finished[1][2].pc ~= nil, "the error carries the PC")
        state.finished = 0
    end)

    runTest("play: a plain Lua error becomes a fatal error table", function()
        state.pc = 0xFFFFFF  -- far outside the story
        state.finished = 0
        local client = recordingClient()
        assertEqual(ZRunner.play(state, client), "fatal")
        assertEqual(type(client.finished[1][2]), "table")
        assertEqual(client.finished[1][2].fatal, true)
        state.finished = 0
    end)

    runTest("restartHeader writes the screen size the host reported", function()
        local version = state.header.version
        state.screenRows, state.screenCols = 30, 100
        state:restartHeader()
        if version >= 4 then
            assertEqual(memory:readU8(0x20), 30, "rows")
            assertEqual(memory:readU8(0x21), 100, "columns")
        end
        state.screenRows, state.screenCols = nil, nil
    end)

    TestFramework.printSummary("ZRunner tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

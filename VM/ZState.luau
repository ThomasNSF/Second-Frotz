---------------------------------------------------------------------
-- Z-machine execution state for the Luau interpreter.
--
-- Owns the stack, frame pointer, program counter, and variable access.
-- Every function that touches memory (codeByte, codeWord, global
-- reads/writes) inherits ZMemory's coroutine-yielding contract: it must
-- be called from within a VM coroutine.
---------------------------------------------------------------------

local ZMemory = require("ZMemory.luau")

-- coromgr.luau is already required by zmemory.luau within this same
-- requiring script, so this resolves to the same cached CoroutineMgr
-- instance (require caches per module path within a script) -- yield_frame
-- must run against the same instance actually driving the VM coroutine,
-- or its internal await_event would assert against the wrong one.
local _CoroMgr, _await_event, yield_frame = table.unpack(require("coromgr.luau"))

local STACK_SIZE = 1024

-- Instructions between cooperative yields. Provisional pending in-world
-- measurement (see PHASE3_PLAN.md "Instruction budget"): each yield costs
-- roughly one FRAME_DELAY, so this caps throughput around N*10
-- instructions/sec. Biased high because ROM page faults already yield
-- naturally on any story larger than the page cache, and SLua preempts
-- on its own script budget regardless -- this is a safety net for
-- RAM-resident hot loops, not the primary scheduler.
local YIELD_INTERVAL = 10000

-- Frame word bit layout (see PHASE3_PLAN.md "Frame layout").
local FRAME_ARGC_FIELD = 0
local FRAME_ARGC_WIDTH = 8
local FRAME_COUNT_FIELD = 8
local FRAME_COUNT_WIDTH = 4
local FRAME_CT_FIELD = 12
local FRAME_CT_WIDTH = 4

local CT_STORE = 0
local CT_DISCARD = 1
local CT_DIRECT = 2

-- Fatal error codes (frotz.h). Raising any of these unwinds to the
-- interpreter's top-level pcall; see PHASE3_PLAN.md "Two error classes".
local ERR_STORE_RANGE = 2
local ERR_DIV_ZERO = 3
local ERR_ILL_OBJ = 4
local ERR_ILL_ATTR = 5
local ERR_NO_PROP = 6
local ERR_STK_OVF = 7
local ERR_ILL_CALL_ADDR = 8
local ERR_CALL_NON_RTN = 9
local ERR_STK_UNDF = 10
local ERR_ILL_OPCODE = 11
local ERR_BAD_FRAME = 12
local ERR_ILL_JUMP_ADDR = 13
local ERR_STR3_NESTING = 15
local ERR_ILL_WIN = 16
local ERR_ILL_PRINT_ADDR = 18
-- Port-specific (Frotz's numbering stops at 35): a valid opcode this port
-- does not provide.
local ERR_UNSUPPORTED = 100

-- Non-fatal codes (frotz.h 19-32): reported, then execution continues.
-- 33-35 (sound and picture warnings) arrive with the output phases.
local WARN_JIN_0 = 19
local WARN_GET_CHILD_0 = 20
local WARN_GET_PARENT_0 = 21
local WARN_GET_SIBLING_0 = 22
local WARN_GET_PROP_ADDR_0 = 23
local WARN_GET_PROP_0 = 24
local WARN_PUT_PROP_0 = 25
local WARN_CLEAR_ATTR_0 = 26
local WARN_SET_ATTR_0 = 27
local WARN_TEST_ATTR_0 = 28
local WARN_MOVE_OBJECT_0 = 29
local WARN_MOVE_OBJECT_TO_0 = 30
local WARN_REMOVE_OBJECT_0 = 31
local WARN_GET_NEXT_PROP_0 = 32

-- Header field addresses touched by writeHeaderFlags/restartHeader (frotz.h).
local H_CONFIG = 1
local H_FLAGS = 16
local H_INTERPRETER_NUMBER = 30
local H_INTERPRETER_VERSION = 31
local H_SCREEN_ROWS = 32
local H_SCREEN_COLS = 33
local H_SCREEN_WIDTH = 34
local H_SCREEN_HEIGHT = 36
local H_FONT_HEIGHT = 38
local H_FONT_WIDTH = 39
local H_DEFAULT_BACKGROUND = 44
local H_DEFAULT_FOREGROUND = 45
local H_STANDARD = 50

local SCRIPTING_FLAG = 0x0001
local FIXED_FONT_FLAG = 0x0002
local PRESERVED_FLAGS_MASK = bit32.bor(SCRIPTING_FLAG, FIXED_FONT_FLAG)

-- Placeholder capabilities until a host adapter supplies real values.
local INTERP_DEFAULT = 0
local DEFAULT_SCREEN_ROWS = 24
local DEFAULT_SCREEN_COLS = 80
local DEFAULT_COLOUR = 1
local STANDARD_REVISION = 0x0101  -- claims Z-machine Standard 1.1, matching Frotz

local ERROR_MESSAGES: {[number]: string} = {
    [ERR_STORE_RANGE] = "Store out of dynamic memory",
    [ERR_DIV_ZERO] = "Division by zero",
    [ERR_STK_OVF] = "Stack overflow",
    [ERR_ILL_CALL_ADDR] = "Call to illegal address",
    [ERR_CALL_NON_RTN] = "Call to non-routine",
    [ERR_STK_UNDF] = "Stack underflow",
    [ERR_ILL_OPCODE] = "Illegal opcode",
    [ERR_BAD_FRAME] = "Bad stack frame",
    [ERR_ILL_JUMP_ADDR] = "Jump to illegal address",
    [ERR_ILL_OBJ] = "Illegal object",
    [ERR_ILL_ATTR] = "Illegal attribute",
    [ERR_NO_PROP] = "No such property",
    [ERR_STR3_NESTING] = "Nesting stream #3 too deep",
    [ERR_ILL_WIN] = "Illegal window",
    [ERR_ILL_PRINT_ADDR] = "Print at illegal address",
    [ERR_UNSUPPORTED] = "Unsupported opcode",
    [WARN_JIN_0] = "@jin called with object 0",
    [WARN_GET_CHILD_0] = "@get_child called with object 0",
    [WARN_GET_PARENT_0] = "@get_parent called with object 0",
    [WARN_GET_SIBLING_0] = "@get_sibling called with object 0",
    [WARN_GET_PROP_ADDR_0] = "@get_prop_addr called with object 0",
    [WARN_GET_PROP_0] = "@get_prop called with object 0",
    [WARN_PUT_PROP_0] = "@put_prop called with object 0",
    [WARN_CLEAR_ATTR_0] = "@clear_attr called with object 0",
    [WARN_SET_ATTR_0] = "@set_attr called with object 0",
    [WARN_TEST_ATTR_0] = "@test_attr called with object 0",
    [WARN_MOVE_OBJECT_0] = "@move_object called moving object 0",
    [WARN_MOVE_OBJECT_TO_0] = "@move_object called moving into object 0",
    [WARN_REMOVE_OBJECT_0] = "@remove_object called with object 0",
    [WARN_GET_NEXT_PROP_0] = "@get_next_prop called with object 0",
}

export type ZState = {
    memory: ZMemory.ZMemory,
    header: ZMemory.StoryHeader,

    pc: number,
    stack: buffer,      -- STACK_SIZE words, grows downward
    sp: number,         -- word index of top element; STACK_SIZE when empty
    fp: number,         -- word index of current frame word
    frameCount: number,

    zargs: {number},    -- preallocated, length 8, reused every instruction
    zargc: number,

    finished: number,
    instructionCount: number,
    instructionStart: number,  -- pc where the instruction being run began (for error reports)
    hasRestarted: boolean,
    warningCounts: {[number]: number},  -- occurrences per non-fatal code, for report-once
    randomState: number,    -- LCG state, always within 0..2^32-1
    randomInterval: number, -- 0 = standard mode; >0 = special counting mode
    randomCounter: number,

    -- Set by whoever builds the VM (the driver, or a test). Typed `any` so
    -- ZState need not require them.
    --   textClient: the ZTextClient the print and input opcodes use
    --   directCall: calls a routine to completion (Frotz's direct_call)
    --               and returns its result
    --   onYield:    called just before the periodic yield, so pending
    --               output is sent while a long computation runs
    --   screenRows, screenCols: the screen size the host reports, written
    --               into the header at restart (defaults when unset)
    textClient: any,
    directCall: any,
    onYield: any,
    trace: any,  -- optional: called every 250 instructions (diagnostics)
    screenRows: number?,
    screenCols: number?,

    codeByte: (ZState) -> number,
    codeWord: (ZState) -> number,
    push: (ZState, number) -> (),
    pop: (ZState) -> number,
    peek: (ZState) -> number,
    readVariable: (ZState, number) -> number,
    peekVariable: (ZState, number) -> number,
    writeVariable: (ZState, number, number) -> (),
    storeResult: (ZState, number, number) -> (),
    readGlobal: (ZState, number) -> number,
    writeGlobal: (ZState, number, number) -> (),
    unpackRoutine: (ZState, number) -> number,
    unpackString: (ZState, number) -> number,
    call: (ZState, number, number, {number}, number) -> (),
    ret: (ZState, number) -> (),
    branch: (ZState, boolean) -> (),
    catchFrame: (ZState) -> number,
    throwFrame: (ZState, number, number) -> (),
    checkArgCount: (ZState, number) -> (),
    writeHeaderFlags: (ZState, number) -> (),
    restartHeader: (ZState) -> (),
    restart: (ZState) -> (),
    tick: (ZState) -> (),
    seedRandom: (ZState, number) -> (),
    nextRandom: (ZState) -> number,
    store: (ZState, number) -> (),
    runtimeError: (ZState, number) -> (),
    unsupportedOpcode: (ZState, string) -> (),
    runtimeWarning: (ZState, number) -> (),
}

local ZState = {}
ZState.__index = ZState

-- Public constants for consumers that need to match against a runtime
-- error's code (from the table thrown by runtimeError) or specify a call
-- type explicitly -- Phase 4 opcode handlers and tests, primarily.
ZState.Errors = {
    STORE_RANGE = ERR_STORE_RANGE,
    DIV_ZERO = ERR_DIV_ZERO,
    STK_OVF = ERR_STK_OVF,
    ILL_CALL_ADDR = ERR_ILL_CALL_ADDR,
    CALL_NON_RTN = ERR_CALL_NON_RTN,
    STK_UNDF = ERR_STK_UNDF,
    ILL_OPCODE = ERR_ILL_OPCODE,
    BAD_FRAME = ERR_BAD_FRAME,
    ILL_JUMP_ADDR = ERR_ILL_JUMP_ADDR,
    ILL_OBJ = ERR_ILL_OBJ,
    ILL_ATTR = ERR_ILL_ATTR,
    NO_PROP = ERR_NO_PROP,
    STR3_NESTING = ERR_STR3_NESTING,
    ILL_WIN = ERR_ILL_WIN,
    ILL_PRINT_ADDR = ERR_ILL_PRINT_ADDR,
    UNSUPPORTED = ERR_UNSUPPORTED,
}

-- Non-fatal codes, for use with runtimeWarning. Kept separate from Errors
-- so call sites make the "reports and returns, never raises" class visible.
ZState.Warnings = {
    JIN_0 = WARN_JIN_0,
    GET_CHILD_0 = WARN_GET_CHILD_0,
    GET_PARENT_0 = WARN_GET_PARENT_0,
    GET_SIBLING_0 = WARN_GET_SIBLING_0,
    GET_PROP_ADDR_0 = WARN_GET_PROP_ADDR_0,
    GET_PROP_0 = WARN_GET_PROP_0,
    PUT_PROP_0 = WARN_PUT_PROP_0,
    CLEAR_ATTR_0 = WARN_CLEAR_ATTR_0,
    SET_ATTR_0 = WARN_SET_ATTR_0,
    TEST_ATTR_0 = WARN_TEST_ATTR_0,
    MOVE_OBJECT_0 = WARN_MOVE_OBJECT_0,
    MOVE_OBJECT_TO_0 = WARN_MOVE_OBJECT_TO_0,
    REMOVE_OBJECT_0 = WARN_REMOVE_OBJECT_0,
    GET_NEXT_PROP_0 = WARN_GET_NEXT_PROP_0,
}

ZState.CallType = {
    STORE = CT_STORE,
    DISCARD = CT_DISCARD,
    DIRECT = CT_DIRECT,
}

-- Reinterprets an unsigned 16-bit value as signed, matching C's `(short)`
-- cast used throughout the opcode handlers (math.c, variable.c, etc.).
-- Not an instance method -- pure value transform, no state involved.
function ZState.toS16(value: number): number
    if value >= 0x8000 then
        return value - 0x10000
    end
    return value
end

-- Wraps a signed or out-of-range value into the unsigned 16-bit zword
-- range, matching C's implicit truncation when a `short` result is
-- stored back into a zword. Lua's `%` already floors toward -infinity,
-- so this is correct for negative inputs without a branch.
function ZState.toU16(value: number): number
    return value % 0x10000
end

-- Creates a runtime state bound to an initialized ZMemory instance and its
-- parsed header. The caller is responsible for having already run
-- ZMemory.initialize(...) on `memory`. Constructors stay dot-style with no
-- self, since there is no instance yet to call them on.
function ZState.new(memory: ZMemory.ZMemory, header: ZMemory.StoryHeader): ZState
    local state = {
        memory = memory,
        header = header,

        pc = 0,
        stack = buffer.create(STACK_SIZE * 2),
        sp = STACK_SIZE,
        fp = STACK_SIZE,
        frameCount = 0,

        zargs = table.create(8, 0),
        zargc = 0,

        finished = 0,
        instructionStart = 0,
        instructionCount = 0,
        hasRestarted = false,
        warningCounts = {},
        randomState = 1,  -- Frotz's static A = 1
        randomInterval = 0,
        randomCounter = 0,
    }

    return setmetatable(state, ZState) :: any
end

-- Raises a fatal Z-machine error. Mirrors os_fatal: does not return. The
-- caller should be running under the interpreter's top-level pcall.
function ZState:runtimeError(code: number): ()
    error({
        fatal = true,
        code = code,
        pc = self.pc,
        message = ERROR_MESSAGES[code] or ("Unknown runtime error " .. tostring(code)),
    })
end

-- Raises the fatal error for a valid opcode this port does not provide,
-- naming it so the host can say which one the story needed.
function ZState:unsupportedOpcode(name: string): ()
    error({
        fatal = true,
        code = ERR_UNSUPPORTED,
        pc = self.pc,
        message = ERROR_MESSAGES[ERR_UNSUPPORTED] .. ": " .. name,
        opcode = name,
    })
end

-- Reports a non-fatal Z-machine error and returns. Mirrors the "report
-- and continue" class (codes 19-35 in frotz.h) under Frotz's default
-- report-once mode (err.c): the first occurrence of each code prints,
-- later ones are counted silently. Must never raise.
function ZState:runtimeWarning(code: number): ()
    local count = (self.warningCounts[code] or 0) + 1
    self.warningCounts[code] = count
    if count == 1 then
        local message = ERROR_MESSAGES[code] or ("runtime error " .. tostring(code))
        print(string.format("Warning: %s (PC = %x) (will ignore further occurrences)", message, self.pc))
    end
end

----------------------------------------------------------------------
-- Stack primitives
----------------------------------------------------------------------

-- Pushes one word. Checks for one free slot; call() is responsible for its
-- own 4-word frame-header check before pushing a frame (see PHASE3_PLAN.md).
function ZState:push(value: number): ()
    if self.sp <= 0 then
        self:runtimeError(ERR_STK_OVF)
    end
    self.sp -= 1
    buffer.writeu16(self.stack, self.sp * 2, value)
end

function ZState:pop(): number
    if self.sp >= STACK_SIZE then
        self:runtimeError(ERR_STK_UNDF)
    end
    local value = buffer.readu16(self.stack, self.sp * 2)
    self.sp += 1
    return value
end

function ZState:peek(): number
    if self.sp >= STACK_SIZE then
        self:runtimeError(ERR_STK_UNDF)
    end
    return buffer.readu16(self.stack, self.sp * 2)
end

----------------------------------------------------------------------
-- PC stream
----------------------------------------------------------------------

function ZState:codeByte(): number
    local value = self.memory:readU8(self.pc)
    self.pc += 1
    return value
end

function ZState:codeWord(): number
    local value = self.memory:readU16(self.pc)
    self.pc += 2
    return value
end

----------------------------------------------------------------------
-- Variable access
--
-- Variable 0 means something different in each of these four paths; see
-- PHASE3_PLAN.md "The variable-0 subtlety" before changing any of them.
----------------------------------------------------------------------

function ZState:readGlobal(variable: number): number
    local addr = self.header.globals + 2 * (variable - 16)
    return self.memory:readU16(addr)
end

function ZState:writeGlobal(variable: number, value: number): ()
    local addr = self.header.globals + 2 * (variable - 16)
    if not self.memory:writeU16(addr, value) then
        self:runtimeError(ERR_STORE_RANGE)
    end
end

-- Reads an operand: variable 0 pops.
function ZState:readVariable(variable: number): number
    if variable == 0 then
        return self:pop()
    elseif variable < 16 then
        return buffer.readu16(self.stack, (self.fp - variable) * 2)
    else
        return self:readGlobal(variable)
    end
end

-- Reads without consuming: variable 0 peeks. Used by z_load.
function ZState:peekVariable(variable: number): number
    if variable == 0 then
        return self:peek()
    elseif variable < 16 then
        return buffer.readu16(self.stack, (self.fp - variable) * 2)
    else
        return self:readGlobal(variable)
    end
end

-- Writes in place: variable 0 replaces the current top without changing sp.
-- Used by z_store, z_inc, z_dec. Errors if the stack is empty.
function ZState:writeVariable(variable: number, value: number): ()
    if variable == 0 then
        if self.sp >= STACK_SIZE then
            self:runtimeError(ERR_STK_UNDF)
        end
        buffer.writeu16(self.stack, self.sp * 2, value)
    elseif variable < 16 then
        buffer.writeu16(self.stack, (self.fp - variable) * 2, value)
    else
        self:writeGlobal(variable, value)
    end
end

-- Stores an instruction's result: variable 0 pushes. Used by store() in the
-- C source, i.e. whatever a "store" opcode byte names.
function ZState:storeResult(variable: number, value: number): ()
    if variable == 0 then
        self:push(value)
    elseif variable < 16 then
        buffer.writeu16(self.stack, (self.fp - variable) * 2, value)
    else
        self:writeGlobal(variable, value)
    end
end

-- Reads a variable byte from the PC stream and stores a value there.
-- Mirrors C's store(), which every "store" opcode calls implicitly via
-- its trailing store byte. Equivalent to storeResult(codeByte(), value)
-- but named to match the C source, since Phase 4 handlers are ported
-- from it line by line.
function ZState:store(value: number): ()
    self:storeResult(self:codeByte(), value)
end

----------------------------------------------------------------------
-- Packed addresses
----------------------------------------------------------------------

function ZState:unpackRoutine(addr: number): number
    local version = self.header.version
    if version <= 3 then
        return addr * 2
    elseif version <= 5 then
        return addr * 4
    elseif version <= 7 then
        return addr * 4 + self.header.routinesOffset * 8
    else
        return addr * 8
    end
end

function ZState:unpackString(addr: number): number
    local version = self.header.version
    if version <= 3 then
        return addr * 2
    elseif version <= 5 then
        return addr * 4
    elseif version <= 7 then
        return addr * 4 + self.header.stringsOffset * 8
    else
        return addr * 8
    end
end

----------------------------------------------------------------------
-- Calls, returns, branches
----------------------------------------------------------------------

-- Calls a subroutine. Saves pc and fp, then loads the new pc and
-- initializes a new stack frame. `args` is 1-indexed (C's zargs is
-- 0-indexed); `ct` selects how the result is delivered on return:
-- CT_STORE writes it to a variable, CT_DISCARD throws it away, CT_DIRECT
-- is a direct call. Re-entering the interpreter loop for CT_DIRECT is
-- Phase 5's responsibility once that loop exists (see PHASE3_PLAN.md
-- "Nested interpretation and the finished counter") -- this method only
-- sets up the frame; it does not itself resume execution.
function ZState:call(routine: number, argc: number, args: {number}, ct: number): ()
    if self.sp < 4 then
        self:runtimeError(ERR_STK_OVF)
    end

    local returnPc = self.pc
    self:push(bit32.rshift(returnPc, 9))
    self:push(bit32.band(returnPc, 0x1ff))
    self:push(self.fp - 1)
    self:push(bit32.bor(argc, bit32.lshift(ct, FRAME_CT_FIELD)))

    self.fp = self.sp
    self.frameCount += 1

    local pc = self:unpackRoutine(routine)
    if pc >= self.header.storySize then
        self:runtimeError(ERR_ILL_CALL_ADDR)
    end
    self.pc = pc

    local count = self:codeByte()
    if count > 15 then
        self:runtimeError(ERR_CALL_NON_RTN)
    end
    if self.sp < count then
        self:runtimeError(ERR_STK_OVF)
    end

    local frameWord = buffer.readu16(self.stack, self.fp * 2)
    frameWord = bit32.replace(frameWord, count, FRAME_COUNT_FIELD, FRAME_COUNT_WIDTH)
    buffer.writeu16(self.stack, self.fp * 2, frameWord)

    for i = 1, count do
        local value = 0
        if self.header.version <= 4 then
            value = self:codeWord()  -- V1-V4: default table is always present in the file
        end
        if i <= argc then
            value = args[i]
        end
        self:push(value)
    end
end

-- Returns from the current subroutine, restoring the previous frame. See
-- ZState:call for what `ct` means on the way back.
function ZState:ret(value: number): ()
    if self.sp > self.fp then
        self:runtimeError(ERR_STK_UNDF)
    end
    self.sp = self.fp

    local frameWord = self:pop()
    local ct = bit32.extract(frameWord, FRAME_CT_FIELD, FRAME_CT_WIDTH)
    self.frameCount -= 1

    local prevFp = self:pop()
    self.fp = prevFp + 1

    local pcLow = self:pop()
    local pcHigh = self:pop()
    self.pc = bit32.bor(bit32.lshift(pcHigh, 9), pcLow)

    if ct == CT_STORE then
        self:store(value)
    elseif ct == CT_DIRECT then
        self:push(value)
        self.finished += 1
    end
end

-- Takes a branch after an instruction, per the encoding in the Z-machine
-- spec: one or two bytes, short or long form, taken on true or false.
-- Offset 0 or 1 is the special case: return false/true instead of jumping.
function ZState:branch(flag: boolean): ()
    local specifier = self:codeByte()
    local off1 = bit32.band(specifier, 0x3f)

    if not flag then
        specifier = bit32.bxor(specifier, 0x80)
    end

    local offset: number
    if bit32.band(specifier, 0x40) == 0 then
        -- Long branch: off1 holds the high 6 bits of a 14-bit signed
        -- offset. Propagate its sign bit (0x20) into bits 6-7 before
        -- combining, so the assembled 16-bit value sign-extends correctly.
        if bit32.band(off1, 0x20) ~= 0 then
            off1 = bit32.bor(off1, 0xc0)
        end
        local off2 = self:codeByte()
        offset = bit32.bor(bit32.lshift(off1, 8), off2)
    else
        -- Short branch: off1 is the unsigned 6-bit offset (0-63) directly.
        offset = off1
    end

    if bit32.band(specifier, 0x80) ~= 0 then
        if offset > 1 then
            local signedOffset = offset
            if signedOffset >= 0x8000 then
                signedOffset -= 0x10000
            end
            self.pc += signedOffset - 2
        else
            self:ret(offset)
        end
    end
end

----------------------------------------------------------------------
-- Catch, throw, argument count
----------------------------------------------------------------------

-- Returns a token identifying the current call depth, for later use with
-- throwFrame. Mirrors z_catch, which just stores frameCount.
function ZState:catchFrame(): number
    return self.frameCount
end

-- Unwinds the stack back to the frame identified by `frame` (as returned
-- by catchFrame) and returns from it with `value`. Mirrors z_throw.
--
-- The unwind loop only walks the fp chain; it does not touch sp or
-- restore each intermediate frame's pc/ct. That work is unnecessary,
-- because the final ret() call resets sp to the target frame's fp in one
-- step, discarding every intervening frame's stack data at once, and
-- restores pc/ct only for the frame actually being returned from.
function ZState:throwFrame(value: number, frame: number): ()
    if frame > self.frameCount then
        self:runtimeError(ERR_BAD_FRAME)
    end

    while self.frameCount > frame do
        local prevFp = buffer.readu16(self.stack, (self.fp + 1) * 2)
        self.fp = prevFp + 1
        self.frameCount -= 1
    end

    self:ret(value)
end

-- Branches if the current routine was called with at least `n` arguments.
-- At the outermost level (no routine called yet) there are no arguments.
-- Mirrors z_check_arg_count.
function ZState:checkArgCount(n: number): ()
    if self.fp == STACK_SIZE then
        self:branch(n == 0)
    else
        local frameWord = buffer.readu16(self.stack, self.fp * 2)
        local argc = bit32.extract(frameWord, FRAME_ARGC_FIELD, FRAME_ARGC_WIDTH)
        self:branch(n <= argc)
    end
end

----------------------------------------------------------------------
-- Header writes, restart
----------------------------------------------------------------------

-- Writes the flags-register word and keeps the header shadow's scripting
-- and fixed-font bits in sync with what actually landed in memory.
-- Mirrors storeb's H_FLAGS+1 special case (fastmem.c), generalized to a
-- full-word write since that's what Phase 3 owns; a byte-granularity
-- @storeb targeting address 17 is Phase 4's job to route here (read the
-- current word, patch the low byte, call this). Transcription side
-- effects (opening/closing the script stream) are not implemented; that
-- belongs to the host-adapter phase.
function ZState:writeHeaderFlags(value: number): ()
    if not self.memory:writeU16(H_FLAGS, value) then
        self:runtimeError(ERR_STORE_RANGE)
    end

    self.header.flags2 = bit32.bor(
        bit32.band(value, PRESERVED_FLAGS_MASK),
        bit32.band(self.header.flags2, bit32.bnot(PRESERVED_FLAGS_MASK))
    )
end

-- Writes interpreter-identity and placeholder screen-geometry fields back
-- into the header. Mirrors the version-gated subset of restart_header
-- (fastmem.c) that does not require a real screen; a host adapter is
-- expected to overwrite these with real values once one exists. Does not
-- reproduce Frotz's per-story interpreter-number compatibility quirks
-- (Journey, Shogun, Zork Zero, Arthur), which are legacy
-- platform-detection hacks for specific old releases, not core
-- Z-machine behavior.
function ZState:restartHeader(): ()
    self.memory:writeU8(H_CONFIG, self.header.flags1)
    local rows = self.screenRows or DEFAULT_SCREEN_ROWS
    local cols = self.screenCols or DEFAULT_SCREEN_COLS

    if self.header.version >= 4 then
        self.memory:writeU8(H_INTERPRETER_NUMBER, INTERP_DEFAULT)
        self.memory:writeU8(H_INTERPRETER_VERSION, string.byte("A"))
        self.memory:writeU8(H_SCREEN_ROWS, rows)
        self.memory:writeU8(H_SCREEN_COLS, cols)
    end

    if self.header.version >= 5 then
        self.memory:writeU16(H_SCREEN_WIDTH, cols)
        self.memory:writeU16(H_SCREEN_HEIGHT, rows)
        self.memory:writeU8(H_FONT_HEIGHT, 1)
        self.memory:writeU8(H_FONT_WIDTH, 1)
        self.memory:writeU8(H_DEFAULT_BACKGROUND, DEFAULT_COLOUR)
        self.memory:writeU8(H_DEFAULT_FOREGROUND, DEFAULT_COLOUR)
    end

    self.memory:writeU16(H_STANDARD, STANDARD_REVISION)
end

-- Re-initializes execution state for a fresh run or @restart. Reloads
-- dynamic memory from the pristine ROM image (skipped on the very first
-- call, since it was already loaded fresh by ZMemory.initialize), resets
-- the stack, and sets the initial PC -- a direct byte address for every
-- version except V6, where start_pc is a packed routine address instead
-- (see PHASE3_PLAN.md "Version coverage").
function ZState:restart(): ()
    self:seedRandom(0)  -- mirrors z_restart's seed_random(0)

    if self.hasRestarted then
        -- Rebuild dynamic memory from the story image. seedRam works on
        -- whole pages, which is far cheaper than a byte-by-byte copy when
        -- RAM is paged out to LinksetData.
        self.memory:seedRam()
    else
        self.hasRestarted = true
    end

    self:restartHeader()

    self.sp = STACK_SIZE
    self.fp = STACK_SIZE
    self.frameCount = 0

    if self.header.version ~= 6 then
        self.pc = self.header.initialPC
    else
        self:call(self.header.initialPC, 0, {}, CT_DISCARD)
    end
end

----------------------------------------------------------------------
-- Random numbers
----------------------------------------------------------------------

-- Frotz's linear congruential generator (random.c): A = 0x015A4E35 * A + 1.
-- Frotz keeps A in a C `long`, but only bits 16-30 of A reach the output
-- and those depend only on the low 32 bits, so wrapping at 2^32 gives the
-- identical stream on any platform.
local RANDOM_MULTIPLIER = 0x015A4E35

-- Seeds the generator. Mirrors seed_random (random.c): 0 asks the
-- environment for a seed, 1-999 selects "special" mode (a predictable
-- 0, 1, 2, ... cycle of that length, used for testing), anything else
-- is a standard seed.
function ZState:seedRandom(value: number): ()
    if value == 0 then
        -- Frotz asks the interface (os_random_seed). Mix wall-clock time
        -- with script uptime so two restarts in the same second differ.
        self.randomState = bit32.bxor(os.time(), math.floor(ll.GetTime() * 1000))
        self.randomInterval = 0
    elseif value < 1000 then
        self.randomCounter = 0
        self.randomInterval = value
    else
        self.randomState = value
        self.randomInterval = 0
    end
end

-- Returns the next raw value in 0..32767 (before range reduction).
function ZState:nextRandom(): number
    if self.randomInterval ~= 0 then
        local result = self.randomCounter
        self.randomCounter += 1
        if self.randomCounter == self.randomInterval then
            self.randomCounter = 0
        end
        return result
    end

    -- 0x015A4E35 * A reaches ~2^56, past float64's exact 2^53, so split
    -- A into 16-bit halves. Every intermediate stays exact (< 2^41).
    local a = self.randomState
    local lo = bit32.band(a, 0xFFFF)
    local hi = bit32.rshift(a, 16)
    local product = RANDOM_MULTIPLIER * lo + ((RANDOM_MULTIPLIER * hi) % 0x10000) * 0x10000
    a = (product + 1) % 0x100000000
    self.randomState = a
    return bit32.band(bit32.rshift(a, 16), 0x7FFF)
end

----------------------------------------------------------------------
-- Instruction budget
----------------------------------------------------------------------

-- Advances the instruction counter and cooperatively yields every
-- YIELD_INTERVAL instructions. Phase 5's interpret() loop calls this once
-- per instruction, mirroring Frotz's os_tick() call at the same point.
function ZState:tick(): ()
    self.instructionStart = self.pc
    self.instructionCount += 1
    if self.trace ~= nil and self.instructionCount % 250 == 0 then
        self.trace(self)
    end
    if self.instructionCount % YIELD_INTERVAL == 0 then
        if self.onYield ~= nil then
            self.onYield()
        end
        yield_frame()
    end
end

return ZState

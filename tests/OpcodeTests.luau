---------------------------------------------------------------------
-- Test harness for ZOpcodes: dispatch skeleton (Phase 4.1) and the
-- control-flow/call/frame/stack/variable opcode handlers (Phase 4.2).
-- Arithmetic/memory-table opcodes live in MathOpcodeTests.luau and the
-- object opcodes in ObjectOpcodeTests.luau; the shared bytecode helpers
-- are in OpcodeHarness.luau.
--
-- Phase 4.1 tests exercise step()'s form classification, operand
-- decoding, the extended-opcode escape, and illegal-opcode handling,
-- using synthetic bytecode and recording stubs installed into ZOpcodes'
-- real dispatch tables in place of `illegal`.
--
-- Phase 4.2 tests execute real opcode handlers through step() against
-- synthetic bytecode and, where a routine is needed (calls, throw,
-- check_arg_count), synthetic routines built with packRoutineAddress --
-- the same approach StateTests.luau uses.
--
-- Tests that install recording stubs temporarily replace handlers in
-- ZOpcodes' shared dispatch tables (module-level, not per-instance); the
-- real handlers are restored after every test. The tests also mutate the
-- loaded story's dynamic memory, so this script is not meant to be
-- followed by real interpretation using the same loaded modules --
-- reload everything first.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")
local Harness = require("OpcodeHarness.luau")

local NOTECARD_NAME = "ZMachine ROM"

local ERR_ILL_OPCODE = ZState.Errors.ILL_OPCODE

local assertEqual = TestFramework.assertEqual
local assertRuntimeError = TestFramework.assertRuntimeError
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt
local writeBytecode = Harness.writeBytecode
local packRoutineAddress = Harness.packRoutineAddress
local branches = Harness.branches

----------------------------------------------------------------------
-- Fixture
----------------------------------------------------------------------

local memory: ZMemory.ZMemory?

local function freshState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

----------------------------------------------------------------------
-- Recording stub
--
-- Installs a handler at dispatchTable[index] that snapshots zargs/zargc
-- instead of doing real work, and returns a getter for the most recent
-- call. Used to observe what step() actually decoded without needing
-- any real opcode handler to exist yet.
----------------------------------------------------------------------

type Record = { zargs: {number}, zargc: number }

type Saved = {
    dispatchTable: {[number]: ZOpcodes.Handler},
    index: number,
    original: ZOpcodes.Handler,
}

local savedHandlers: {Saved} = {}

-- Puts every real handler back after a test, in reverse order so a slot
-- stubbed twice in one test ends up with the true original.
local function restoreStubs()
    for i = #savedHandlers, 1, -1 do
        local saved = savedHandlers[i]
        saved.dispatchTable[saved.index] = saved.original
    end
    table.clear(savedHandlers)
end

-- Wraps TestFramework.run so stubs never leak into later tests, whether
-- the test passed or failed.
local function runTest(name: string, fn: () -> ())
    TestFramework.run(name, fn)
    restoreStubs()
end

-- Records a slot's current handler so runTest restores it afterward.
-- Used by installStub, and directly by tests that patch slots another way.
local function saveHandler(dispatchTable: {[number]: ZOpcodes.Handler}, index: number)
    table.insert(savedHandlers, {
        dispatchTable = dispatchTable,
        index = index,
        original = dispatchTable[index],
    })
end

local function installStub(dispatchTable: {[number]: ZOpcodes.Handler}, index: number): () -> Record?
    local record: Record? = nil
    saveHandler(dispatchTable, index)
    dispatchTable[index] = function(state: ZState.ZState)
        local snapshot = {}
        for i = 1, state.zargc do
            snapshot[i] = state.zargs[i]
        end
        record = { zargs = snapshot, zargc = state.zargc }
    end
    return function()
        return record
    end
end

local function assertZargs(record: Record?, expected: {number}, message: string?)
    local prefix = message or "assertZargs"
    if record == nil then
        error(prefix .. ": handler was never called")
    end
    assertEqual(record.zargc, #expected, prefix .. ": zargc")
    for i = 1, #expected do
        assertEqual(record.zargs[i], expected[i], prefix .. ": zargs[" .. i .. "]")
    end
end

----------------------------------------------------------------------
-- Test runner
----------------------------------------------------------------------

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    ------------------------------------------------------------------
    -- 2OP form (opcode < 0x80): bit 6 = operand 1 type, bit 5 = operand
    -- 2 type, each small-constant (0) or variable (1); bits 4-0 select
    -- the opcode within `var`.
    ------------------------------------------------------------------

    runTest("2OP: both operands small constants", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.var, 0x01)  -- je
        local base = writeBytecode(state, { 0x01, 42, 43 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 42, 43 })
        assertEqual(state.pc, base + 3, "pc should advance past opcode + 2 operand bytes")
    end)

    runTest("2OP: both operands variables", function()
        local state = freshState()
        state:writeGlobal(16, 777)
        local getRecord = installStub(ZOpcodes.var, 0x01)  -- je
        local base = writeBytecode(state, { 0x61, 16, 16 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 777, 777 })
        assertEqual(state.pc, base + 3)
    end)

    runTest("2OP: mixed operand types", function()
        local state = freshState()
        state:writeGlobal(16, 555)
        local getRecord = installStub(ZOpcodes.var, 0x01)  -- je
        local base = writeBytecode(state, { 0x41, 16, 99 })  -- operand1=variable, operand2=small constant
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 555, 99 })
        assertEqual(state.pc, base + 3)
    end)

    ------------------------------------------------------------------
    -- 1OP form (0x80-0xAF): bits 5-4 give the operand type directly.
    ------------------------------------------------------------------

    runTest("1OP: large constant operand", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.op1, 0x0)  -- jz
        local base = writeBytecode(state, { 0x80, 0x12, 0x34 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 0x1234 })
        assertEqual(state.pc, base + 3)
    end)

    runTest("1OP: small constant operand", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.op1, 0x0)  -- jz
        local base = writeBytecode(state, { 0x90, 99 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 99 })
        assertEqual(state.pc, base + 2)
    end)

    runTest("1OP: variable operand", function()
        local state = freshState()
        state:writeGlobal(16, 321)
        local getRecord = installStub(ZOpcodes.op1, 0x0)  -- jz
        local base = writeBytecode(state, { 0xA0, 16 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 321 })
        assertEqual(state.pc, base + 2)
    end)

    ------------------------------------------------------------------
    -- 0OP form (0xB0-0xBF): no operands.
    ------------------------------------------------------------------

    runTest("0OP: no operands loaded", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.op0, 0x0)  -- rtrue
        local base = writeBytecode(state, { 0xB0 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), {})
        assertEqual(state.pc, base + 1)
    end)

    ------------------------------------------------------------------
    -- VAR form (0xC0-0xFF): specifier-byte-driven operand loading.
    ------------------------------------------------------------------

    runTest("VAR: omitted-operand field terminates loading early", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.var, 0x01)  -- je
        -- specifier 0x3F = 00 11 11 11: operand1=large constant, then
        -- immediately omitted -- must stop after one operand even though
        -- three more 2-bit fields remain in the byte.
        local base = writeBytecode(state, { 0xC1, 0x3F, 0xAB, 0xCD })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 0xABCD })
        assertEqual(state.pc, base + 4)
    end)

    runTest("VAR: two-specifier call loads up to eight operands", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.var, 0x2C)  -- call_vs2 (opcode 0xEC)
        -- Both specifiers 0x55 = 01 01 01 01: four small constants each.
        local base = writeBytecode(state, {
            0xEC, 0x55, 0x55,
            11, 22, 33, 44, 55, 66, 77, 88,
        })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 11, 22, 33, 44, 55, 66, 77, 88 })
        assertEqual(state.pc, base + 11)
    end)

    ------------------------------------------------------------------
    -- Illegal opcodes
    ------------------------------------------------------------------

    runTest("illegal: unassigned VAR slot raises ERR_ILL_OPCODE", function()
        local state = freshState()
        -- var[0] (2OP number 0) is permanently illegal, untouched by any
        -- stub installation above.
        local base = writeBytecode(state, { 0xC0, 0xFF })  -- specifier: all omitted
        state.pc = base
        assertRuntimeError(function()
            ZOpcodes.step(state)
        end, ERR_ILL_OPCODE)
    end)

    ------------------------------------------------------------------
    -- Extended opcode escape (0xBE)
    ------------------------------------------------------------------

    runTest("extended: dispatches into the ext table", function()
        local state = freshState()
        local getRecord = installStub(ZOpcodes.ext, 0x02)  -- log_shift
        -- specifier 0x5F = 01 01 11 11: two small constants, then omitted.
        local base = writeBytecode(state, { 0xBE, 0x02, 0x5F, 10, 20 })
        state.pc = base
        ZOpcodes.step(state)
        assertZargs(getRecord(), { 10, 20 })
        assertEqual(state.pc, base + 5)
    end)

    runTest("extended: opcode number >= 0x1D is silently ignored", function()
        local state = freshState()
        local base = writeBytecode(state, { 0xBE, 0x1D, 0xFF })  -- reserved ext opcode; specifier: all omitted
        state.pc = base
        ZOpcodes.step(state)  -- must not raise
        assertEqual(state.pc, base + 3, "pc should still advance past the escape, ext opcode, and specifier bytes")
    end)

    ------------------------------------------------------------------
    -- Phase 4.2: control flow, calls, frame introspection, stack, variables
    ------------------------------------------------------------------

    runTest("call_s -> ret round trip through step()", function()
        local state = freshState()
        local routineAddr = scratchBase(state)
        writeBytesAt(state, routineAddr, { 0, 0xB0 })  -- 0 locals, then rtrue
        local packed = packRoutineAddress(state, routineAddr)

        local callAddr = routineAddr + 16
        -- call_vs: opcode 0xE0, one large-constant operand (routine), store to variable 0
        writeBytesAt(state, callAddr, {
            0xE0, 0x3F,
            bit32.rshift(packed, 8), bit32.band(packed, 0xFF),
            0,
        })

        local initialSp, initialFp, initialFrameCount = state.sp, state.fp, state.frameCount

        state.pc = callAddr
        ZOpcodes.step(state)
        assertEqual(state.frameCount, initialFrameCount + 1, "call should push a new frame")

        ZOpcodes.step(state)  -- rtrue, inside the called routine
        assertEqual(state.frameCount, initialFrameCount, "return should pop the frame")
        assertEqual(state.fp, initialFp, "fp should be restored")
        assertEqual(state.pc, callAddr + 5, "pc should have consumed the store byte after returning")
        assertEqual(state.sp, initialSp - 1, "result should have been pushed")
        assertEqual(state:pop(), 1, "rtrue should deliver the value 1")
    end)

    runTest("call_s with routine 0 stores 0 without calling", function()
        local state = freshState()
        -- call_vs, one small-constant operand (routine = 0)
        local base = writeBytecode(state, { 0xE0, 0x7F, 0x00, 0x00 })
        local initialFrameCount = state.frameCount
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.frameCount, initialFrameCount, "no frame should be pushed for routine 0")
        assertEqual(state:pop(), 0, "should have stored 0 directly")
    end)

    runTest("call_n with routine 0 does nothing", function()
        local state = freshState()
        -- call_vn (opcode 0xF9), one small-constant operand (routine = 0)
        local base = writeBytecode(state, { 0xF9, 0x7F, 0x00 })
        local initialFrameCount, initialSp = state.frameCount, state.sp
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.frameCount, initialFrameCount, "no frame should be pushed")
        assertEqual(state.sp, initialSp, "nothing should be pushed to the stack")
        assertEqual(state.pc, base + 3, "pc should just advance past the instruction")
    end)

    runTest("jump moves pc by a signed offset", function()
        local state = freshState()
        local offset = 10
        -- 1OP jump (op1[0xC]), small-constant operand
        local base = writeBytecode(state, { 0x9C, offset })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.pc, base + 2 + offset - 2)
    end)

    runTest("store then load a global round-trips through opcodes", function()
        local state = freshState()
        -- z_store (2OP, both small constants): variable=16, value=200
        local base = writeBytecode(state, { 0x0D, 16, 200 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:readGlobal(16), 200, "store should have written the global")

        -- z_load (1OP, small-constant operand): variable=16, store byte=0
        base = writeBytecode(state, { 0x9E, 16, 0 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:pop(), 200, "load should push the global's value")
    end)

    runTest("inc and dec modify a global in place", function()
        local state = freshState()
        state:writeGlobal(16, 10)

        local base = writeBytecode(state, { 0x95, 16 })  -- z_inc
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:readGlobal(16), 11)

        base = writeBytecode(state, { 0x96, 16 })  -- z_dec
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:readGlobal(16), 10)
    end)

    runTest("push and pull round-trip through the game stack", function()
        local state = freshState()
        local before = state.sp
        state:push(999)

        local base = writeBytecode(state, { 0xE8, 0x7F, 42 })  -- z_push
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.sp, before - 2)

        base = writeBytecode(state, { 0xE9, 0x7F, 16 })  -- z_pull into global 16
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.sp, before - 1, "pull should pop exactly one value")
        assertEqual(state:readGlobal(16), 42, "pulled value should land in the global")
        assertEqual(state:pop(), 999, "padding value should remain underneath")
    end)

    runTest("pull to variable 0 replaces the new stack top in place", function()
        local state = freshState()
        local before = state.sp
        state:push(999)
        state:push(42)

        local base = writeBytecode(state, { 0xE9, 0x7F, 0 })  -- z_pull to variable 0
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.sp, before - 1, "one value popped; the write replaced the next one")
        assertEqual(state:pop(), 42, "the old top (999) is overwritten with the pulled value")
        assertEqual(state.sp, before, "nothing else should remain")
    end)

    runTest("throw unwinds via a real throw instruction", function()
        local state = freshState()
        local routineAddr = scratchBase(state)
        writeBytesAt(state, routineAddr, { 0 })  -- 0 locals
        local packed = packRoutineAddress(state, routineAddr)

        -- z_catch isn't wired yet, so establish the frame directly via
        -- ZState:call and capture its token via ZState:catchFrame.
        local returnPc = routineAddr + 8
        assert(state.memory:writeU8(returnPc, 0))  -- store byte: variable 0
        state.pc = returnPc
        state:call(packed, 0, {}, ZState.CallType.STORE)
        local targetFrame = state:catchFrame()

        -- Real @throw instruction: 2OP, both small constants (value, frame).
        local throwAddr = routineAddr + 20
        writeBytesAt(state, throwAddr, { 0x1C, 77, targetFrame })
        state.pc = throwAddr
        ZOpcodes.step(state)

        assertEqual(state.frameCount, 0, "should have returned from the call entirely")
        assertEqual(state.pc, returnPc + 1, "the call's own store byte should have been consumed")
        assertEqual(state:pop(), 77, "the thrown value should have been delivered")
    end)

    runTest("check_arg_count branches based on real call argc", function()
        local state = freshState()
        local routineAddr = scratchBase(state)
        writeBytesAt(state, routineAddr, {
            0,              -- 0 locals
            0xFF, 0x7F, 2,  -- check_arg_count(2): VAR opcode, one small-constant operand
            0xCA,           -- branch: short form, branch-on-true, offset 10
        })
        local packed = packRoutineAddress(state, routineAddr)

        state:call(packed, 2, { 11, 22 }, ZState.CallType.DISCARD)
        ZOpcodes.step(state)
        assertEqual(state.pc, routineAddr + 5 + 10 - 2, "branch should be taken: 2 <= argc(2)")
    end)

    runTest("quit sets finished to 9999", function()
        local state = freshState()
        local base = writeBytecode(state, { 0xBA })  -- 0OP quit
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.finished, 9999)
    end)

    runTest("push_stack and pop_stack manage a user stack", function()
        local state = freshState()
        local stackAddr = scratchBase(state) + 40
        assert(state.memory:writeU16(stackAddr, 2))  -- capacity: 2 free slots

        -- push_stack(55, stackAddr): EXT 0x18, specifier: small const, large const
        local base = writeBytecode(state, {
            0xBE, 0x18, 0x4F, 55,
            bit32.rshift(stackAddr, 8), bit32.band(stackAddr, 0xFF),
            0xC5,  -- branch: short, branch-on-true, offset 5
        })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.memory:readU16(stackAddr), 1, "free-slot count should decrease to 1")
        assertEqual(state.memory:readU16(stackAddr + 4), 55, "value should land where the old size pointed")
        assertEqual(state.pc, base + 10, "branch should have been taken (size 1 ~= 0)")

        -- pop_stack(1, stackAddr): EXT 0x15, same specifier shape
        base = writeBytecode(state, {
            0xBE, 0x15, 0x4F, 1,
            bit32.rshift(stackAddr, 8), bit32.band(stackAddr, 0xFF),
        })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.memory:readU16(stackAddr), 2, "discarding 1 item should restore the free-slot count")
    end)

    ------------------------------------------------------------------
    -- Version patching
    ------------------------------------------------------------------

    runTest("V5 defaults: 0OP:9 is catch, 1OP:15 is call_1n", function()
        local state = freshState()
        saveHandler(ZOpcodes.op0, 0x9)
        saveHandler(ZOpcodes.op1, 0xF)
        ZOpcodes.applyVersionPatches(5)

        -- catch: stores the current frame count (0) to variable 0
        local base = writeBytecode(state, { 0xB9, 0 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:pop(), 0, "catch should push the frame count")

        -- call_1n with routine 0 (small constant): does nothing
        local sp = state.sp
        base = writeBytecode(state, { 0x9F, 0 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.sp, sp, "call_1n with routine 0 should be a no-op")
        assertEqual(state.pc, base + 2)
    end)

    runTest("V3 patch: 0OP:9 is pop, 1OP:15 is not", function()
        local state = freshState()
        local emptySp = state.sp
        saveHandler(ZOpcodes.op0, 0x9)
        saveHandler(ZOpcodes.op1, 0xF)
        ZOpcodes.applyVersionPatches(3)

        -- pop: discards the top of the stack
        state:push(5)
        local base = writeBytecode(state, { 0xB9 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.sp, emptySp, "pop should discard the pushed value")

        -- not (1OP, large constant 0x00FF), store to variable 0
        base = writeBytecode(state, { 0x8F, 0x00, 0xFF, 0 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:pop(), 0xFF00, "not should flip all 16 bits")
    end)

    ------------------------------------------------------------------

    TestFramework.printSummary("ZOpcodes dispatch/control tests")
end

ll.SetText("Opcode Tests", vector(1,1,1), 1)
print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

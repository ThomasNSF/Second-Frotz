---------------------------------------------------------------------
-- Test harness for ZState (Phase 3).
--
-- Exercises the test list from PHASE3_PLAN.md against a live ZMemory +
-- ZState pair loaded from the ZMachine ROM notecard. Must run inside a
-- VM coroutine, since ZMemory reads may yield on a ROM page fault.
--
-- Running these tests mutates the loaded story's dynamic memory (they
-- write synthetic routine data and controlled return-address bytes into
-- RAM to exercise call/ret/branch without a real interpreter loop, and
-- some tests write globals and header fields). Do not resume actual
-- gameplay against the same ZState afterward -- reload the ROM first.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))

local NOTECARD_NAME = "ZMachine ROM"

local CT_STORE = ZState.CallType.STORE
local CT_DISCARD = ZState.CallType.DISCARD
local CT_DIRECT = ZState.CallType.DIRECT

local ERR_STK_OVF = ZState.Errors.STK_OVF
local ERR_STK_UNDF = ZState.Errors.STK_UNDF
local ERR_BAD_FRAME = ZState.Errors.BAD_FRAME

----------------------------------------------------------------------
-- Test framework and fixture (shared across test files)
----------------------------------------------------------------------

local TestFramework = require("TestFramework.luau")
local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local assertRuntimeError = TestFramework.assertRuntimeError

local memory: ZMemory.ZMemory?

local function freshState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

----------------------------------------------------------------------
-- Scratch region for synthetic routines and controlled return addresses
--
-- Carved out of the last 64 bytes of dynamic memory, 8-byte aligned so
-- the routine's packed address divides evenly regardless of story
-- version. The routine header lives in the low half (up to 31 bytes: a
-- 15-local routine needs 1 count byte); return-address scratch bytes
-- live in the high half, so the two never collide.
----------------------------------------------------------------------

local SCRATCH_SIZE = 64
local SCRATCH_RETURN_OFFSET = 32

local function scratchBase(state: ZState.ZState): number
    local base = state.header.staticMemoryBase - SCRATCH_SIZE
    return base - (base % 8)
end

local function scratchReturnAddress(state: ZState.ZState, index: number): number
    return scratchBase(state) + SCRATCH_RETURN_OFFSET + index
end

-- Inverts ZState:unpackRoutine for a given byte address, so tests can
-- call state:call() against a scratch address they fully control.
local function packRoutineAddress(state: ZState.ZState, byteAddress: number): number
    local version = state.header.version
    if version <= 3 then
        assert(byteAddress % 2 == 0, "routine address must be even for V1-V3")
        return byteAddress / 2
    elseif version <= 5 then
        assert(byteAddress % 4 == 0, "routine address must be a multiple of 4 for V4-V5")
        return byteAddress / 4
    elseif version <= 7 then
        local offset = byteAddress - state.header.routinesOffset * 8
        assert(offset >= 0 and offset % 4 == 0, "routine address invalid for V6-V7 packing")
        return offset / 4
    else
        assert(byteAddress % 8 == 0, "routine address must be a multiple of 8 for V8")
        return byteAddress / 8
    end
end

-- Writes a synthetic routine header into the scratch region and returns
-- the packed address to pass to state:call(). V1-V4 routine formats store
-- a 16-bit default value per local right after the count byte; V5+ omits
-- them entirely (locals just default to zero), so defaults are only
-- written when the loaded story actually needs them.
local function writeSyntheticRoutine(state: ZState.ZState, localCount: number, localDefaults: {number}?): number
    local base = scratchBase(state)
    assert(state.memory:writeU8(base, localCount), "scratch address must be writable")

    if state.header.version <= 4 then
        for i = 1, localCount do
            local value = (localDefaults and localDefaults[i]) or 0
            assert(state.memory:writeU16(base + 1 + (i - 1) * 2, value))
        end
    end

    return packRoutineAddress(state, base)
end

-- Reads a frame word's three packed fields directly, for tests that want
-- to inspect a frame without going through checkArgCount's branch.
local function frameFields(state: ZState.ZState, fp: number): (number, number, number)
    local word = buffer.readu16(state.stack, fp * 2)
    local argc = bit32.extract(word, 0, 8)
    local count = bit32.extract(word, 8, 4)
    local ct = bit32.extract(word, 12, 4)
    return argc, count, ct
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
    -- Stack primitives
    ------------------------------------------------------------------

    runTest("push/pop returns sp to initial position", function()
        local state = freshState()
        local initialSp = state.sp
        state:push(1234)
        assertEqual(state.sp, initialSp - 1, "sp should decrease by one after push")
        assertEqual(state:pop(), 1234, "popped value should match pushed value")
        assertEqual(state.sp, initialSp, "sp should return to initial position after pop")
    end)

    runTest("push to capacity raises ERR_STK_OVF exactly at the boundary", function()
        local state = freshState()
        local capacity = state.sp
        for i = 1, capacity do
            state:push(i)
        end
        assertEqual(state.sp, 0, "stack should be completely full")
        assertRuntimeError(function()
            state:push(9999)
        end, ERR_STK_OVF, "push on a full stack")
    end)

    runTest("pop from an empty stack raises ERR_STK_UNDF", function()
        local state = freshState()
        assertRuntimeError(function()
            state:pop()
        end, ERR_STK_UNDF, "pop on an empty stack")
    end)

    ------------------------------------------------------------------
    -- Variables
    ------------------------------------------------------------------

    runTest("read/write every local slot 1-15", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 15)
        state:call(packed, 0, {}, CT_DISCARD)

        for n = 1, 15 do
            state:writeVariable(n, n * 100)
        end
        for n = 1, 15 do
            assertEqual(state:readVariable(n), n * 100, "local " .. n)
        end
    end)

    runTest("global write lands at globals + 2*(n-16) in RAM", function()
        local state = freshState()
        local globalNumber = 16
        state:writeGlobal(globalNumber, 0xBEEF)
        local expectedAddress = state.header.globals + 2 * (globalNumber - 16)
        assertEqual(state.memory:readU16(expectedAddress), 0xBEEF, "raw memory at computed global address")
        assertEqual(state:readGlobal(globalNumber), 0xBEEF, "readGlobal should match")
    end)

    runTest("storeResult with variable 0 pushes", function()
        local state = freshState()
        local before = state.sp
        state:storeResult(0, 4242)
        assertEqual(state.sp, before - 1, "sp should decrease by one")
        assertEqual(state:pop(), 4242)
    end)

    runTest("writeVariable with variable 0 replaces top in place", function()
        local state = freshState()
        state:push(111)
        local before = state.sp
        state:writeVariable(0, 222)
        assertEqual(state.sp, before, "sp should not change")
        assertEqual(state:pop(), 222, "top should have been replaced")
    end)

    runTest("readVariable pops, peekVariable does not", function()
        local state = freshState()
        local before = state.sp
        state:push(777)
        assertEqual(state:peekVariable(0), 777, "peek should see the pushed value")
        assertEqual(state.sp, before - 1, "peek should not change sp")
        assertEqual(state:readVariable(0), 777, "read should see the same value")
        assertEqual(state.sp, before, "read should pop, returning sp to original")
    end)

    ------------------------------------------------------------------
    -- Frames
    ------------------------------------------------------------------

    runTest("call with fewer args than locals defaults unsupplied locals to zero (V5+)", function()
        local state = freshState()
        assertTrue(state.header.version >= 5, "this test assumes a V5+ story; Adventureland is V5")
        local packed = writeSyntheticRoutine(state, 4)
        state:call(packed, 2, {10, 20}, CT_DISCARD)
        assertEqual(state:readVariable(1), 10)
        assertEqual(state:readVariable(2), 20)
        assertEqual(state:readVariable(3), 0, "unsupplied local should default to zero")
        assertEqual(state:readVariable(4), 0, "unsupplied local should default to zero")
    end)

    runTest("call with more args than locals discards the extras", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 2)
        state:call(packed, 5, {1, 2, 3, 4, 5}, CT_DISCARD)
        assertEqual(state:readVariable(1), 1)
        assertEqual(state:readVariable(2), 2)
        local argc = select(1, frameFields(state, state.fp))
        assertEqual(argc, 5, "frame should record the full supplied argc even though only 2 locals exist")
    end)

    runTest("frame word packs argc, count, and ct independently", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 7)
        state:call(packed, 3, {1, 2, 3}, CT_STORE)
        local argc, count, ct = frameFields(state, state.fp)
        assertEqual(argc, 3, "argc field")
        assertEqual(count, 7, "count field")
        assertEqual(ct, CT_STORE, "ct field")
    end)

    runTest("return PC above 65535 round-trips through the 9-bit split", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 0)
        local bigPc = 70000  -- exceeds a single zword; exercises the split.
        -- Safe to set pc to an address with no real content: call() only
        -- stores this value numerically to restore later, never reads
        -- through it.
        state.pc = bigPc
        state:call(packed, 0, {}, CT_DISCARD)
        assertTrue(state.pc ~= bigPc, "pc should have moved into the called routine")
        state:ret(0)
        assertEqual(state.pc, bigPc, "return should restore the original pc exactly")
    end)

    runTest("nested calls fully unwind sp, fp, and frameCount", function()
        local state = freshState()
        local initialSp, initialFp, initialFrameCount = state.sp, state.fp, state.frameCount
        local depth = 5
        local packed = writeSyntheticRoutine(state, 2)

        for _ = 1, depth do
            state:call(packed, 0, {}, CT_DISCARD)
        end
        assertEqual(state.frameCount, initialFrameCount + depth, "frameCount should reflect the nesting depth")

        for _ = 1, depth do
            state:ret(0)
        end

        assertEqual(state.sp, initialSp, "sp should return to its pre-call value")
        assertEqual(state.fp, initialFp, "fp should return to its pre-call value")
        assertEqual(state.frameCount, initialFrameCount, "frameCount should return to its pre-call value")
    end)

    runTest("ret stores, discards, or pushes its result per call type", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 0)

        -- CT_STORE: the byte at the return address names the destination
        -- variable, mirroring a real call_s instruction's trailing store byte.
        do
            local returnPc = scratchReturnAddress(state, 0)
            assert(state.memory:writeU8(returnPc, 0))  -- store to variable 0 (the stack)
            state.pc = returnPc
            local before = state.sp
            state:call(packed, 0, {}, CT_STORE)
            state:ret(555)
            assertEqual(state.pc, returnPc + 1, "ret should have consumed the store byte")
            assertEqual(state:pop(), 555, "result should have been pushed (store byte named variable 0)")
            assertEqual(state.sp, before, "no net stack growth once the pushed result is popped back off")
        end

        -- CT_DISCARD: result is thrown away; pc restores exactly, with no
        -- store byte consumed.
        do
            local returnPc = scratchReturnAddress(state, 1)
            state.pc = returnPc
            local before = state.sp
            state:call(packed, 0, {}, CT_DISCARD)
            state:ret(999)
            assertEqual(state.pc, returnPc, "ret should not advance pc for a discarded result")
            assertEqual(state.sp, before, "stack should be unchanged")
        end

        -- CT_DIRECT: result is pushed and `finished` is incremented, so a
        -- caller driving a direct call can detect completion.
        do
            local returnPc = scratchReturnAddress(state, 2)
            state.pc = returnPc
            local beforeFinished = state.finished
            state:call(packed, 0, {}, CT_DIRECT)
            state:ret(123)
            assertEqual(state.finished, beforeFinished + 1, "finished should be incremented")
            assertEqual(state:pop(), 123, "result should have been pushed")
        end
    end)

    ------------------------------------------------------------------
    -- Catch, throw
    ------------------------------------------------------------------

    runTest("catchFrame returns the current frame count", function()
        local state = freshState()
        assertEqual(state:catchFrame(), 0, "no frames yet")
        local packed = writeSyntheticRoutine(state, 0)
        state:call(packed, 0, {}, CT_DISCARD)
        assertEqual(state:catchFrame(), 1)
        state:call(packed, 0, {}, CT_DISCARD)
        assertEqual(state:catchFrame(), 2)
    end)

    runTest("throwFrame unwinds to the target frame and discards intervening stack", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 0)
        local rootFp = state.fp

        -- throwFrame's ret() delivers the target frame's OWN result, so
        -- give the outer call a controlled CT_STORE return address.
        local returnPc = scratchReturnAddress(state, 3)
        assert(state.memory:writeU8(returnPc, 0))  -- store to variable 0 (the stack)
        state.pc = returnPc
        state:call(packed, 0, {}, CT_STORE)  -- outer call: frameCount becomes 1
        local targetFrame = state:catchFrame()  -- identifies this outer call

        state:call(packed, 0, {}, CT_DISCARD)  -- inner call: frameCount becomes 2
        state:push(1)
        state:push(2)
        state:push(3)  -- intervening stack data that throwFrame must discard

        state:throwFrame(444, targetFrame)

        -- throwFrame returns FROM the target frame itself -- i.e. it
        -- causes the outer call to return, landing back at the root.
        assertEqual(state.fp, rootFp, "fp should be restored to the pre-call frame")
        assertEqual(state.frameCount, 0, "should have returned from the outer call entirely")
        assertEqual(state.pc, returnPc + 1, "the outer call's own CT_STORE should have consumed its store byte")
        assertEqual(state:pop(), 444, "the thrown value should be delivered like a normal return")
    end)

    runTest("throwFrame to a frame above frameCount raises ERR_BAD_FRAME", function()
        local state = freshState()
        assertRuntimeError(function()
            state:throwFrame(0, state.frameCount + 1)
        end, ERR_BAD_FRAME)
    end)

    ------------------------------------------------------------------
    -- Branch
    ------------------------------------------------------------------

    runTest("short branch forward, both polarities", function()
        local state = freshState()
        local addr = scratchReturnAddress(state, 10)
        local offset = 20

        -- specifier: bit7=1 (branch on true), bit6=1 (short form), offset in bits 0-5.
        assert(state.memory:writeU8(addr, 0xC0 + offset))
        state.pc = addr
        state:branch(true)
        assertEqual(state.pc, addr + 1 + offset - 2, "branch-on-true should jump when the flag matches")

        assert(state.memory:writeU8(addr, 0xC0 + offset))
        state.pc = addr
        state:branch(false)
        assertEqual(state.pc, addr + 1, "branch should not jump when the flag does not match bit 7")
    end)

    runTest("long branch sign-extends a negative 14-bit offset", function()
        local state = freshState()
        local addr = scratchReturnAddress(state, 12)
        -- Long branch (bit6=0), branch-on-true (bit7=1), off1=0x3F, off2=0xFB
        -- encodes -5 as a 14-bit two's complement offset.
        assert(state.memory:writeU8(addr, 0xBF))
        assert(state.memory:writeU8(addr + 1, 0xFB))
        state.pc = addr
        state:branch(true)
        assertEqual(state.pc, addr + 2 + (-5) - 2, "pc should move backward per the sign-extended offset")
    end)

    runTest("branch offset 0 or 1 returns instead of jumping", function()
        local state = freshState()
        local packed = writeSyntheticRoutine(state, 0)
        local returnPc = scratchReturnAddress(state, 20)
        assert(state.memory:writeU8(returnPc, 0))  -- store to variable 0 (the stack)

        state.pc = returnPc
        state:call(packed, 0, {}, CT_STORE)
        local branchAddr = scratchReturnAddress(state, 25)
        assert(state.memory:writeU8(branchAddr, 0xC1))  -- short, branch-on-true, offset 1
        state.pc = branchAddr
        state:branch(true)
        assertEqual(state.pc, returnPc + 1, "should have returned to the call site, past its store byte")
        assertEqual(state:pop(), 1, "offset 1 should return true (1)")

        state.pc = returnPc
        state:call(packed, 0, {}, CT_STORE)
        branchAddr = scratchReturnAddress(state, 26)
        assert(state.memory:writeU8(branchAddr, 0xC0))  -- short, branch-on-true, offset 0
        state.pc = branchAddr
        state:branch(true)
        assertEqual(state:pop(), 0, "offset 0 should return false (0)")
    end)

    ------------------------------------------------------------------
    -- Startup
    ------------------------------------------------------------------

    runTest("restart sets pc from start_pc and empties the stack (non-V6)", function()
        local state = freshState()
        assertTrue(state.header.version ~= 6, "Adventureland is V5, not V6")
        local initialSp, initialFp = state.sp, state.fp

        state:push(1)
        state:push(2)
        state:call(writeSyntheticRoutine(state, 0), 0, {}, CT_DISCARD)

        state:restart()

        assertEqual(state.pc, state.header.initialPC, "pc should be set from start_pc")
        assertEqual(state.sp, initialSp, "stack should be empty")
        assertEqual(state.fp, initialFp, "fp should be reset")
        assertEqual(state.frameCount, 0, "frameCount should be reset")
    end)

    runTest("restart twice in a row produces identical state", function()
        local state = freshState()
        state:restart()
        local pc1, sp1, fp1 = state.pc, state.sp, state.fp

        state:restart()
        assertEqual(state.pc, pc1, "pc should match across repeated restarts")
        assertEqual(state.sp, sp1, "sp should match across repeated restarts")
        assertEqual(state.fp, fp1, "fp should match across repeated restarts")
    end)

    ------------------------------------------------------------------
    -- Error reporting (Phase 4.4.1)
    ------------------------------------------------------------------

    runTest("runtimeWarning returns without raising and counts per code", function()
        local state = freshState()
        state:runtimeWarning(ZState.Warnings.JIN_0)
        state:runtimeWarning(ZState.Warnings.JIN_0)
        state:runtimeWarning(ZState.Warnings.GET_CHILD_0)
        assertEqual(state.warningCounts[ZState.Warnings.JIN_0], 2)
        assertEqual(state.warningCounts[ZState.Warnings.GET_CHILD_0], 1)
    end)

    runTest("object errors are fatal and carry Frotz's messages", function()
        local state = freshState()
        local ok, err = pcall(function()
            state:runtimeError(ZState.Errors.ILL_ATTR)
        end)
        assertEqual(ok, false)
        assertEqual(err.code, ZState.Errors.ILL_ATTR)
        assertEqual(err.message, "Illegal attribute")
    end)

    runTest("a V6 story is rejected by readHeader; other versions still parse", function()
        local state = freshState()
        local original = state.memory:readU8(0)
        assert(state.memory:writeU8(0, 6))
        local ok, err = pcall(function()
            state.memory:readHeader()
        end)
        assert(state.memory:writeU8(0, 7))
        local v7 = state.memory:readHeader()
        assert(state.memory:writeU8(0, original))
        assertEqual(ok, false, "V6 must be refused")
        assertTrue(string.find(tostring(err), "V6", 1, true) ~= nil, "the error should name V6")
        assertEqual(v7.version, 7, "V7 is still supported")
    end)

    ------------------------------------------------------------------

    TestFramework.printSummary("ZState tests")
end

CoroutineMgr:create_task(runAllTests)

---------------------------------------------------------------------
-- Test harness for the ZOpcodes arithmetic, bitwise, shift, comparison,
-- random, and memory-table handlers (Phase 4.3). Dispatch and
-- control-flow tests are in OpcodeTests.luau, object opcodes in
-- ObjectOpcodeTests.luau; shared bytecode helpers are in
-- OpcodeHarness.luau.
--
-- Mutates the loaded story's dynamic memory (including the header flags
-- word, which the flags tests restore); do not follow with real
-- interpretation on the same loaded modules.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")
local Harness = require("OpcodeHarness.luau")

local NOTECARD_NAME = "ZMachine ROM"

local ERR_DIV_ZERO = ZState.Errors.DIV_ZERO
local ERR_STORE_RANGE = ZState.Errors.STORE_RANGE
local u16 = ZState.toU16

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertRuntimeError = TestFramework.assertRuntimeError
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt
local writeBytecode = Harness.writeBytecode
local execInstruction = Harness.execInstruction
local evalVar = Harness.evalVar
local evalExt = Harness.evalExt
local branches = Harness.branches
local assertBytes = Harness.assertBytes
local scan = Harness.scan

local memory: ZMemory.ZMemory?

local function freshState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    ------------------------------------------------------------------
    -- Random numbers
    ------------------------------------------------------------------

    runTest("random: seeded LCG matches the C reference sequence", function()
        local state = freshState()
        state:seedRandom(1000)
        local expected = { 18625, 14062, 5795, 15161, 15600, 27360 }
        for i, value in ipairs(expected) do
            assertEqual(state:nextRandom(), value, "seed 1000, draw " .. i)
        end

        state:seedRandom(12345)
        expected = { 15301, 24996, 10921, 23577, 19316, 10386 }
        for i, value in ipairs(expected) do
            assertEqual(state:nextRandom(), value, "seed 12345, draw " .. i)
        end
    end)

    runTest("random: unseeded state starts at A=1 like Frotz", function()
        local state = freshState()
        assertEqual(state:nextRandom(), 346)
        assertEqual(state:nextRandom(), 130)
        assertEqual(state:nextRandom(), 10982)
    end)

    runTest("random opcode: negative operand seeds, positive operand draws", function()
        local state = freshState()
        -- random(-1000): VAR 0xE7, one large-constant operand 0xFC18, store to variable 0
        local base = writeBytecode(state, { 0xE7, 0x3F, 0xFC, 0x18, 0 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:pop(), 0, "seeding should store 0")

        -- random(100): draws 18625 then 14062 -> 18625 % 100 + 1, 14062 % 100 + 1
        base = writeBytecode(state, { 0xE7, 0x7F, 100, 0 })
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:pop(), 26)
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state:pop(), 63)
    end)

    runTest("random opcode: seeds below 1000 give a predictable cycle", function()
        local state = freshState()
        local base = writeBytecode(state, { 0xE7, 0x3F, 0xFF, 0xFD, 0 })  -- random(-3)
        state.pc = base
        ZOpcodes.step(state)
        state:pop()

        base = writeBytecode(state, { 0xE7, 0x7F, 10, 0 })  -- random(10)
        local drawn = {}
        for i = 1, 4 do
            state.pc = base
            ZOpcodes.step(state)
            drawn[i] = state:pop()
        end
        assertEqual(drawn[1], 1)
        assertEqual(drawn[2], 2)
        assertEqual(drawn[3], 3)
        assertEqual(drawn[4], 1, "counter should wrap after reaching the interval")
    end)

    ------------------------------------------------------------------
    -- Arithmetic, bitwise, shifts, comparison (Phase 4.3.1-4.3.3)
    ------------------------------------------------------------------

    runTest("add: signed operands, wraps at 16 bits", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x14, { 5, 7 }), 12)
        assertEqual(evalVar(state, 0x14, { 32767, 1 }), 0x8000, "overflow wraps")
        assertEqual(evalVar(state, 0x14, { u16(-1), u16(-1) }), u16(-2))
    end)

    runTest("sub: signed operands", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x15, { 3, 5 }), u16(-2))
        assertEqual(evalVar(state, 0x15, { 0, 1 }), 0xFFFF)
    end)

    runTest("mul: signed operands, wraps at 16 bits", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x16, { u16(-3), 4 }), u16(-12))
        assertEqual(evalVar(state, 0x16, { 256, 256 }), 0, "65536 wraps to 0")
    end)

    runTest("div: truncates toward zero like C, raises on zero", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x17, { 7, 2 }), 3)
        assertEqual(evalVar(state, 0x17, { u16(-7), 2 }), u16(-3), "-7/2 is -3, not -4")
        assertEqual(evalVar(state, 0x17, { 7, u16(-2) }), u16(-3))
        assertEqual(evalVar(state, 0x17, { u16(-7), u16(-2) }), 3)
        assertEqual(evalVar(state, 0x17, { 0x8000, u16(-1) }), 0x8000, "-32768/-1 wraps")
        assertRuntimeError(function()
            evalVar(state, 0x17, { 5, 0 })
        end, ERR_DIV_ZERO)
    end)

    runTest("mod: sign follows the dividend like C, raises on zero", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x18, { 7, 2 }), 1)
        assertEqual(evalVar(state, 0x18, { u16(-7), 2 }), u16(-1), "-7%2 is -1, not 1")
        assertEqual(evalVar(state, 0x18, { 7, u16(-2) }), 1, "7%-2 is 1, not -1")
        assertEqual(evalVar(state, 0x18, { u16(-7), u16(-2) }), u16(-1))
        assertRuntimeError(function()
            evalVar(state, 0x18, { 5, 0 })
        end, ERR_DIV_ZERO)
    end)

    runTest("and, or, not", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x09, { 0xF0F0, 0x0FF0 }), 0x00F0, "and")
        assertEqual(evalVar(state, 0x08, { 0xF0F0, 0x0FF0 }), 0xFFF0, "or")
        assertEqual(evalVar(state, 0x38, { 0 }), 0xFFFF, "not 0")
        assertEqual(evalVar(state, 0x38, { 0xFFFF }), 0, "not 0xFFFF")
        assertEqual(evalVar(state, 0x38, { 0x00FF }), 0xFF00)
    end)

    runTest("log_shift: zero-fills, wraps left shifts", function()
        local state = freshState()
        assertEqual(evalExt(state, 0x02, { 0x8000, u16(-1) }), 0x4000)
        assertEqual(evalExt(state, 0x02, { 1, 15 }), 0x8000)
        assertEqual(evalExt(state, 0x02, { 0xFFFF, 4 }), 0xFFF0, "bits shifted out are lost")
        assertEqual(evalExt(state, 0x02, { 0x8000, u16(-15) }), 1)
        assertEqual(evalExt(state, 0x02, { 0xFFF8, u16(-1) }), 0x7FFC, "no sign extension")
        assertEqual(evalExt(state, 0x02, { 0x1234, 0 }), 0x1234)
    end)

    runTest("art_shift: sign-extends right shifts", function()
        local state = freshState()
        assertEqual(evalExt(state, 0x03, { 0xFFF8, u16(-1) }), 0xFFFC, "-8 >> 1 is -4")
        assertEqual(evalExt(state, 0x03, { 0x8000, u16(-15) }), 0xFFFF)
        assertEqual(evalExt(state, 0x03, { 1, 15 }), 0x8000)
        assertEqual(evalExt(state, 0x03, { 0xFFFF, 4 }), 0xFFF0, "-1 << 4 is -16")
        assertEqual(evalExt(state, 0x03, { 0x0010, u16(-2) }), 4)
        assertEqual(evalExt(state, 0x03, { 0x1234, 0 }), 0x1234)
    end)

    runTest("je: equality against up to three others, unsigned", function()
        local state = freshState()
        assertEqual(branches(state, 0x01, { 5, 5 }), true)
        assertEqual(branches(state, 0x01, { 5, 6 }), false)
        assertEqual(branches(state, 0x01, { 5 }), false, "a single operand never matches")
        assertEqual(branches(state, 0x01, { 5, 1, 2, 5 }), true, "fourth operand is compared")
        assertEqual(branches(state, 0x01, { 5, 1, 2, 3 }), false)
        assertEqual(branches(state, 0x01, { 0xFFFF, 0xFFFF }), true)
    end)

    runTest("jl: signed comparison", function()
        local state = freshState()
        assertEqual(branches(state, 0x02, { u16(-1), 1 }), true, "-1 < 1 (unsigned would say no)")
        assertEqual(branches(state, 0x02, { 1, u16(-1) }), false)
        assertEqual(branches(state, 0x02, { 5, 5 }), false)
        assertEqual(branches(state, 0x02, { 0x8000, 0x7FFF }), true, "-32768 < 32767")
    end)

    runTest("jg: signed comparison", function()
        local state = freshState()
        assertEqual(branches(state, 0x03, { 1, u16(-1) }), true)
        assertEqual(branches(state, 0x03, { 0x8000, 0 }), false, "-32768 > 0 is false")
        assertEqual(branches(state, 0x03, { 5, 5 }), false)
        assertEqual(branches(state, 0x03, { 0x7FFF, 0x8000 }), true)
    end)

    runTest("test: all mask bits must be set", function()
        local state = freshState()
        assertEqual(branches(state, 0x07, { 0xFF, 0x0F }), true)
        assertEqual(branches(state, 0x07, { 0x0F, 0xFF }), false)
        assertEqual(branches(state, 0x07, { 0x1234, 0 }), true, "an empty mask always matches")
    end)

    runTest("jz: branches only on zero (1OP)", function()
        local state = freshState()
        -- 1OP jz, large-constant operand, on-true short branch offset 10
        local function jz(value: number): boolean
            local base = writeBytecode(state, { 0x80, bit32.rshift(value, 8), bit32.band(value, 0xFF), 0xCA })
            state.pc = base
            ZOpcodes.step(state)
            return state.pc == base + 4 + 8
        end
        assertEqual(jz(0), true)
        assertEqual(jz(1), false)
        assertEqual(jz(0x8000), false, "-32768 is not zero")
    end)

    runTest("branch polarity: an on-false branch fires when the condition is false", function()
        local state = freshState()
        -- 0x4A: bit 7 clear (branch on false), short form, offset 10
        local base, length = execInstruction(state, { 0xC1 }, { 5, 6 }, { 0x4A })  -- je 5, 6 is false
        assertEqual(state.pc, base + length + 8, "condition false + on-false branch should be taken")
        base, length = execInstruction(state, { 0xC1 }, { 5, 5 }, { 0x4A })  -- je 5, 5 is true
        assertEqual(state.pc, base + length, "condition true + on-false branch should not be taken")
    end)

    ------------------------------------------------------------------
    -- Memory tables (Phase 4.3.5)
    ------------------------------------------------------------------

    runTest("loadb and loadw read bytes and words from dynamic memory", function()
        local state = freshState()
        local tableAddr = scratchBase(state) + 40
        assert(state.memory:writeU16(tableAddr, 0x1234))
        assert(state.memory:writeU16(tableAddr + 2, 0xBEEF))
        assertEqual(evalVar(state, 0x0F, { tableAddr, 1 }), 0xBEEF, "loadw index 1")
        assertEqual(evalVar(state, 0x10, { tableAddr, 3 }), 0xEF, "loadb index 3")
        assertEqual(evalVar(state, 0x10, { 0, 0 }), state.header.version, "header byte 0")
        assertEqual(evalVar(state, 0x0F, { 0, 1 }), state.header.release, "header word at 2")
    end)

    runTest("loadb and loadw addresses wrap at 16 bits", function()
        local state = freshState()
        assertEqual(evalVar(state, 0x10, { 0xFFFF, 1 }), state.header.version, "0xFFFF + 1 wraps to 0")
        assertEqual(evalVar(state, 0x0F, { 0xFFFE, 0x8001 }), state.memory:readU16(0), "0xFFFE + 2 * 0x8001 wraps to 0")
    end)

    runTest("loadb reads static memory through the ROM path", function()
        local state = freshState()
        local staticBase = state.header.staticMemoryBase
        assertEqual(evalVar(state, 0x10, { staticBase, 0 }), state.memory:readOriginalU8(staticBase))
    end)

    runTest("storeb truncates to a byte, storew writes big-endian", function()
        local state = freshState()
        local addr = scratchBase(state) + 40
        execInstruction(state, { 0xC0 + 0x22 }, { addr, 2, 0x1FF }, {})  -- storeb addr[2] = 0x1FF
        assertEqual(state.memory:readU8(addr + 2), 0xFF, "only the low byte is stored")
        execInstruction(state, { 0xC0 + 0x21 }, { addr, 1, 0xCAFE }, {})  -- storew addr[1] = 0xCAFE
        assertEqual(state.memory:readU8(addr + 2), 0xCA)
        assertEqual(state.memory:readU8(addr + 3), 0xFE)
    end)

    runTest("stores outside dynamic memory raise ERR_STORE_RANGE", function()
        local state = freshState()
        assertRuntimeError(function()
            execInstruction(state, { 0xC0 + 0x22 }, { state.header.staticMemoryBase, 0, 1 }, {})
        end, ERR_STORE_RANGE, "storeb into static memory")
        assertRuntimeError(function()
            execInstruction(state, { 0xC0 + 0x22 }, { 0xFFFF, 0, 1 }, {})
        end, ERR_STORE_RANGE, "storeb past the end of the story")
    end)

    runTest("storeb to the flags register updates the header shadow", function()
        local state = freshState()
        local original = state.memory:readU16(16)
        local highByte = bit32.band(original, 0xFF00)

        execInstruction(state, { 0xC0 + 0x22 }, { 17, 0, 0x03 }, {})  -- set scripting + fixed-font bits
        assertEqual(bit32.band(state.header.flags2, 0x03), 0x03, "shadow should track the new bits")
        assertEqual(state.memory:readU8(17), 0x03)
        assertEqual(bit32.band(state.memory:readU16(16), 0xFF00), highByte, "high byte should be untouched")

        execInstruction(state, { 0xC0 + 0x22 }, { 17, 0, 0x00 }, {})  -- clear them again
        assertEqual(bit32.band(state.header.flags2, 0x03), 0, "shadow should clear the bits")
        assertEqual(state.memory:readU8(17), 0)

        assert(state.memory:writeU16(16, original))
    end)

    runTest("storew across the flags register routes its low byte too", function()
        local state = freshState()
        local original = state.memory:readU16(16)
        execInstruction(state, { 0xC0 + 0x21 }, { 16, 0, 0x0103 }, {})  -- storew word 0 at address 16
        assertEqual(state.memory:readU16(16), 0x0103)
        assertEqual(bit32.band(state.header.flags2, 0x03), 0x03, "low byte went through writeHeaderFlags")
        assert(state.memory:writeU16(16, original))
    end)

    ------------------------------------------------------------------
    -- copy_table and scan_table (Phase 4.3.6)
    ------------------------------------------------------------------

    runTest("copy_table copies a table and zero-fills with destination 0", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        writeBytesAt(state, data, { 1, 2, 3, 4, 5, 6, 7, 8 })
        execInstruction(state, { 0xC0 + 0x3D }, { data, data + 16, 8 }, {})
        assertBytes(state, data + 16, { 1, 2, 3, 4, 5, 6, 7, 8 }, "copied")

        execInstruction(state, { 0xC0 + 0x3D }, { data, 0, 4 }, {})
        assertBytes(state, data, { 0, 0, 0, 0, 5, 6, 7, 8 }, "zero-filled")
    end)

    runTest("copy_table with dest above an overlapping source copies backward", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        writeBytesAt(state, data, { 1, 2, 3, 4, 5, 6, 0, 0 })
        execInstruction(state, { 0xC0 + 0x3D }, { data, data + 2, 6 }, {})
        assertBytes(state, data, { 1, 2, 1, 2, 3, 4, 5, 6 }, "memmove-safe result")
    end)

    runTest("copy_table with source above an overlapping dest copies forward", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        writeBytesAt(state, data, { 1, 2, 3, 4, 5, 6, 7, 8 })
        execInstruction(state, { 0xC0 + 0x3D }, { data + 2, data, 6 }, {})
        assertBytes(state, data, { 3, 4, 5, 6, 7, 8, 7, 8 })
    end)

    runTest("copy_table with a negative size forces a forward copy", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        -- Positive size: backward, so the overlap copies cleanly.
        writeBytesAt(state, data, { 1, 2, 3, 4, 5 })
        execInstruction(state, { 0xC0 + 0x3D }, { data, data + 1, 4 }, {})
        assertBytes(state, data, { 1, 1, 2, 3, 4 }, "positive size")

        -- Negative size: forward, smearing byte 0 across the overlap.
        writeBytesAt(state, data, { 1, 2, 3, 4, 5 })
        execInstruction(state, { 0xC0 + 0x3D }, { data, data + 1, u16(-4) }, {})
        assertBytes(state, data, { 1, 1, 1, 1, 1 }, "negative size")
    end)

    runTest("copy_table into static memory raises ERR_STORE_RANGE", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        assertRuntimeError(function()
            execInstruction(state, { 0xC0 + 0x3D }, { data, state.header.staticMemoryBase, 1 }, {})
        end, ERR_STORE_RANGE)
    end)

    runTest("scan_table finds words with the default form and reports misses", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        assert(state.memory:writeU16(data, 0x1111))
        assert(state.memory:writeU16(data + 2, 0x2222))
        assert(state.memory:writeU16(data + 4, 0x3333))

        local found, taken = scan(state, { 0x2222, data, 3 })
        assertEqual(found, data + 2, "address of the match")
        assertEqual(taken, true, "a hit branches")

        found, taken = scan(state, { 0x9999, data, 3 })
        assertEqual(found, 0, "a miss stores 0")
        assertEqual(taken, false, "a miss does not branch")

        found, taken = scan(state, { 0x2222, data, 1 })
        assertEqual(found, 0, "only the first entry is examined when count is 1")
    end)

    runTest("scan_table handles byte tables and custom entry steps", function()
        local state = freshState()
        local data = scratchBase(state) + 16
        writeBytesAt(state, data, { 5, 6, 7, 8 })
        local found = scan(state, { 7, data, 4, 0x01 })  -- byte entries, step 1
        assertEqual(found, data + 2)
        found = scan(state, { 0x107, data, 4, 0x01 })
        assertEqual(found, 0, "a byte table can never match a value above 255")

        assert(state.memory:writeU16(data, 0xAAAA))      -- word entries, step 4
        assert(state.memory:writeU16(data + 4, 0xBBBB))
        assert(state.memory:writeU16(data + 8, 0xCCCC))
        found = scan(state, { 0xCCCC, data, 3, 0x84 })
        assertEqual(found, data + 8, "third entry at a stride of 4")
    end)

    ------------------------------------------------------------------

    TestFramework.printSummary("ZOpcodes math/table tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

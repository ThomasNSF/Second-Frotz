---------------------------------------------------------------------
-- Tests for the print opcodes: print, print_ret, new_line, print_addr,
-- print_paddr, print_obj, print_char and print_num. The output-stream,
-- Unicode and shared-RAM tests are in TextStreamTests, split off because
-- one script with all of them outgrew the memory limit.
--
-- The core no longer prints. These opcodes hand output entries to the
-- text client, and the tests check the entries (and requests) that reach
-- a recording transport. What the Text Service does with them is covered
-- by TextServiceTests.
--
-- Mutates dynamic memory; do not follow with real interpretation on the
-- same loaded modules. Requires the "ZMachine ROM" cards and the Memory
-- Manager.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
local ZObject = require("../VM/ZObject.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")
local Harness = require("OpcodeHarness.luau")
local Support = require("TextTestSupport.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local assertRuntimeError = TestFramework.assertRuntimeError
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt
local writeBytecode = Harness.writeBytecode
local packRoutineAddress = Harness.packRoutineAddress
local execInstruction = Harness.execInstruction
local exec1op = Harness.exec1op

local memory: ZMemory.ZMemory?

local function newVm()
    assert(memory, "ZMemory not initialized")
    local state, transport, client = Support.newVm(memory)
    assertTrue(state.header.version == 5, "these tests assume V5 packing; Adventureland is V5")
    return state, transport, client
end

local function wordBytes(words: { number }): { number }
    local bytes = {}
    for _, word in words do
        table.insert(bytes, bit32.rshift(word, 8))
        table.insert(bytes, bit32.band(word, 0xFF))
    end
    return bytes
end

local function joined(words: { number }): string
    return table.concat(words, ",")
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME, { ramFlatLimit = 0 })
    if not memory then
        return
    end

    -- This script is close to the memory limit: smaller caches leave room.
    memory.ramMaxResident = 4
    memory.romCacheMaxSize = 2

    runTest("print queues the embedded string and leaves the PC past it", function()
        local state, transport, client = newVm()
        local words = Support.words({ 13, 10, 17, 17, 20 })  -- "hello"
        local bytes = { 0xB2 }
        for _, b in wordBytes(words) do
            table.insert(bytes, b)
        end
        local base = writeBytecode(state, bytes)
        state.pc = base
        ZOpcodes.step(state)
        assertEqual(state.pc, base + #bytes, "pc is just past the string")
        local entries = Support.entries(client, transport)
        assertEqual(#entries, 1)
        assertEqual(entries[1][1], "z", "code in dynamic memory is copied")
        assertEqual(joined(entries[1][2]), joined(words))
    end)

    runTest("print_ret queues the string and a newline, then returns true from a real routine", function()
        local state, transport, client = newVm()
        local routineAddr = scratchBase(state)
        local words = Support.words({ 20, 16 })  -- "ok"
        local body = { 0, 0xB3 }
        for _, b in wordBytes(words) do
            table.insert(body, b)
        end
        writeBytesAt(state, routineAddr, body)
        local packed = packRoutineAddress(state, routineAddr)
        local callAddr = routineAddr + 16
        writeBytesAt(state, callAddr, { 0xE0, 0x3F, bit32.rshift(packed, 8), bit32.band(packed, 0xFF), 0 })

        local initialFrames = state.frameCount
        state.pc = callAddr
        ZOpcodes.step(state)  -- call_vs
        ZOpcodes.step(state)  -- print_ret
        local entries = Support.entries(client, transport)
        assertEqual(#entries, 2)
        assertEqual(joined(entries[1][2]), joined(words))
        assertEqual(entries[2][1], "nl")
        assertEqual(state:pop(), 1, "print_ret returns true")
        assertEqual(state.frameCount, initialFrames, "the frame was popped")
    end)

    runTest("new_line queues a newline", function()
        local state, transport, client = newVm()
        state.pc = writeBytecode(state, { 0xBB })
        ZOpcodes.step(state)
        local entries = Support.entries(client, transport)
        assertEqual(#entries, 1)
        assertEqual(entries[1][1], "nl")
    end)

    runTest("print_addr: a string in dynamic memory is copied; one in ROM goes by address", function()
        local state, transport, client = newVm()
        local words = Support.words({ 13, 14 })  -- "hi"
        local addr = writeBytesAt(state, scratchBase(state) + 32, wordBytes(words))
        exec1op(state, 0x7, addr, {})
        exec1op(state, 0x7, 0x3261 * 4, {})
        local entries = Support.entries(client, transport)
        assertEqual(entries[1][1], "z")
        assertEqual(joined(entries[1][2]), joined(words))
        assertEqual(entries[2][1], "s")
        assertEqual(entries[2][2], 0x3261 * 4)
    end)

    runTest("print_paddr unpacks the address; RAM strings are copied, ROM strings go by address", function()
        local state, transport, client = newVm()
        local words = Support.words({ 13, 14 })
        local addr = writeBytesAt(state, scratchBase(state) + 32, wordBytes(words))
        exec1op(state, 0xD, packRoutineAddress(state, addr), {})
        exec1op(state, 0xD, 0x3261, {})
        local entries = Support.entries(client, transport)
        assertEqual(entries[1][1], "z")
        assertEqual(joined(entries[1][2]), joined(words))
        assertEqual(entries[2][1], "s")
        assertEqual(entries[2][2], 0x3261 * 4, "the packed address was unpacked")
    end)

    runTest("print_addr and print_paddr past the end of the story raise ERR_ILL_PRINT_ADDR", function()
        local state = newVm()
        assertRuntimeError(function()
            exec1op(state, 0xD, 0xFFFF, {})
        end, ZState.Errors.ILL_PRINT_ADDR)
        assertRuntimeError(function()
            exec1op(state, 0x7, 0xFFFF, {})
        end, ZState.Errors.ILL_PRINT_ADDR)
    end)

    runTest("print_obj copies the object's name words; empty prints nothing; the placeholder is text", function()
        local state, transport, client = newVm()
        exec1op(state, 0xA, 29, {})
        local entries = Support.entries(client, transport)
        assertEqual(#entries, 1)
        assertEqual(entries[1][1], "z")
        local nameAddr = ZObject.nameAddress(state, 29)
        local expected = {}
        for i = 0, state.memory:readU8(nameAddr) - 1 do
            expected[i + 1] = state.memory:readU16(nameAddr + 1 + 2 * i)
        end
        assertEqual(joined(entries[1][2]), joined(expected), "the name's words")

        TestFramework.withPropertyTable(state, 5, {}, function()
            local before = #entries
            exec1op(state, 0xA, 5, {})
            assertEqual(#Support.entries(client, transport), before, "an empty name queues nothing")
        end)
        TestFramework.withPropertyTable(state, 5, { 0x94, 0xA5 }, function(first)
            assert(state.memory:writeU8(first - 1, 1))  -- one name word: 0x94A5, the empty encoded string
            exec1op(state, 0xA, 5, {})
            local all = Support.entries(client, transport)
            assertEqual(all[#all][1], "t")
            assertEqual(all[#all][2], "object#5")
        end)
    end)

    runTest("print_char queues the low byte of the ZSCII code", function()
        local state, transport, client = newVm()
        execInstruction(state, { 0xE5 }, { 155 }, {})
        execInstruction(state, { 0xE5 }, { 0x141 }, {})
        execInstruction(state, { 0xE5 }, { 13 }, {})
        local entries = Support.entries(client, transport)
        assertEqual(#entries, 1, "a run of characters is one entry")
        assertEqual(entries[1][1], "c")
        assertEqual(entries[1][2], 155)
        assertEqual(entries[1][3], 0x41, "only the low byte counts")
        assertEqual(entries[1][4], 13)
    end)

    runTest("print_num queues signed numbers", function()
        local state, transport, client = newVm()
        local cases = {
            { 0, 0 }, { 7, 7 }, { 0xFFFF, -1 }, { 32767, 32767 },
            { 0x8000, -32768 }, { 12345, 12345 },
        }
        for _, case in cases do
            execInstruction(state, { 0xE6 }, { case[1] }, {})
        end
        local entries = Support.entries(client, transport)
        for i, case in cases do
            assertEqual(entries[i][1], "n")
            assertEqual(entries[i][2], case[2], "print_num " .. case[1])
        end
    end)

    TestFramework.printSummary("Text opcode tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

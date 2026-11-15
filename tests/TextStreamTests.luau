---------------------------------------------------------------------
-- Tests for output_stream, print_unicode, check_unicode, the shared-RAM
-- rules the core keeps around them (acknowledged errors, R6, R7) and the
-- yield hook. The print opcodes are in TextOpcodeTests.
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

    runTest("output_stream 1 and -1 queue stream entries; 2 and 4 are ignored", function()
        local state, transport, client = newVm()
        execInstruction(state, { 0xF3 }, { 0xFFFF }, {})  -- -1
        execInstruction(state, { 0xF3 }, { 1 }, {})
        execInstruction(state, { 0xF3 }, { 2 }, {})
        execInstruction(state, { 0xF3 }, { 0xFFFE }, {})  -- -2
        execInstruction(state, { 0xF3 }, { 4 }, {})
        local entries = Support.entries(client, transport)
        assertEqual(#entries, 2)
        assertEqual(entries[1][1], "o")
        assertEqual(entries[1][2], -1)
        assertEqual(entries[2][2], 1)
        assertEqual(#transport.requests, 0)
    end)

    runTest("output_stream 3 and -3 are requests, and output is synchronous while one is open (R7)", function()
        local state, transport, client = newVm()
        local tableAddr = scratchBase(state) + 40
        execInstruction(state, { 0xF3 }, { 3, tableAddr }, {})
        assertEqual(transport.requests[1].op, "stream")
        assertEqual(transport.requests[1].args.n, 3)
        assertEqual(transport.requests[1].args.table, tableAddr)
        assertEqual(client.redirect, 1)

        execInstruction(state, { 0xE6 }, { 42 }, {})  -- print_num while redirected
        assertEqual(transport.requests[2].op, "flush", "sent and waited for at once")
        assertEqual(transport.requests[2].pre[1][2], 42)

        execInstruction(state, { 0xF3 }, { 0xFFFD }, {})  -- -3
        assertEqual(transport.requests[3].op, "stream")
        assertEqual(transport.requests[3].args.n, -3)
        assertEqual(client.redirect, 0)

        execInstruction(state, { 0xE6 }, { 43 }, {})
        assertEqual(#transport.requests, 3, "asynchronous again")
    end)

    runTest("output_stream 3: nesting is reported by the service, and a table outside dynamic memory is refused", function()
        local state, transport, client = newVm()
        transport.replies.stream = { error = ZState.Errors.STR3_NESTING, message = "Nesting stream #3 too deep" }
        assertRuntimeError(function()
            execInstruction(state, { 0xF3 }, { 3, scratchBase(state) + 40 }, {})
        end, ZState.Errors.STR3_NESTING)
        assertEqual(client.redirect, 0, "the redirect was not counted")

        transport.replies.stream = nil
        assertRuntimeError(function()
            execInstruction(state, { 0xF3 }, { 3, state.header.staticMemoryBase }, {})
        end, ZState.Errors.STORE_RANGE)
    end)

    runTest("print_unicode queues the code point; check_unicode asks the service and stores its answer", function()
        local state, transport, client = newVm()
        execInstruction(state, { 0xBE, 0x0B }, { 0x263A }, {})
        local entries = Support.entries(client, transport)
        assertEqual(entries[1][1], "u")
        assertEqual(entries[1][2], 0x263A)

        transport.replies.check_unicode = function(args)
            return { value = if args.c == 0x61 then 3 else 0 }
        end
        assertEqual(Harness.evalExt(state, 0x0C, { 0x61 }), 3)
        assertEqual(Harness.evalExt(state, 0x0C, { 0x0A }), 0)
        assertEqual(transport.requests[1].op, "check_unicode")
        assertEqual(transport.requests[1].args.c, 0x61)
    end)

    runTest("a service error reported in an acknowledgement becomes the story's fatal error", function()
        local state, transport, client = newVm()
        function transport:wait(_handle)
            return { code = ZState.Errors.ILL_PRINT_ADDR, message = "Print at illegal address" }, false
        end
        exec1op(state, 0x7, 0x3261 * 4, {})
        assertRuntimeError(function()
            client:flush()
            client:settle()
        end, ZState.Errors.ILL_PRINT_ADDR)
    end)

    runTest("a story write into a string table waits for earlier output first (R6)", function()
        local state, transport, client = newVm()
        local addr = scratchBase(state) + 40
        client:setWatch({ { addr, addr + 3 } })
        state.memory:writeU8(addr, 0x11)

        local seenAtBarrier = nil
        transport.replies.barrier = function()
            seenAtBarrier = state.memory:readU8(addr)
            return {}
        end

        execInstruction(state, { 0xE5 }, { 65 }, {})            -- print_char A, still queued
        execInstruction(state, { 0xE2 }, { addr, 0, 0x99 }, {})  -- storeb into the table
        assertEqual(transport.requests[1].op, "barrier")
        assertEqual(transport.requests[1].pre[1][2], 65, "the earlier print travels with the barrier")
        assertEqual(seenAtBarrier, 0x11, "the barrier came before the write")
        assertEqual(state.memory:readU8(addr), 0x99, "then the write happened")

        execInstruction(state, { 0xE2 }, { addr + 8, 0, 0x77 }, {})  -- outside the table
        assertEqual(#transport.requests, 1, "no barrier for other writes")
    end)

    runTest("attachText sends pending output when the state yields", function()
        local state, transport, client = newVm()
        execInstruction(state, { 0xE5 }, { 66 }, {})
        assertEqual(#transport.batches, 0)
        state.onYield()
        assertEqual(#transport.batches, 1)
        assertEqual(transport.batches[1][1][2], 66)
    end)

    TestFramework.printSummary("Text stream tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

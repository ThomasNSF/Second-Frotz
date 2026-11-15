---------------------------------------------------------------------
-- Tests for the input opcodes: read and read_char, including timeouts. The
-- screen and table opcodes are in ScreenOpcodeTests, split off because
-- one script with all of them outgrew the memory limit.
--
-- The core only sends: these opcodes make requests of the Text Service or
-- queue output entries. The tests check what reaches a recording
-- transport, give it scripted replies, and check what the opcode does
-- with them (what it stores, whether it calls the story's timeout
-- routine, what it raises). Reading and tokenising themselves are tested
-- against the Text Service in TextServiceTests and ZInputTests.
--
-- Mutates dynamic memory; do not follow with real interpretation on the
-- same loaded modules. Requires the "ZMachine ROM" cards and the Memory
-- Manager.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
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
local execInstruction = Harness.execInstruction
local evalExt = Harness.evalExt

local memory: ZMemory.ZMemory?

local function newVm(routineResults: { number }?)
    assert(memory, "ZMemory not initialized")
    local state, transport, client, asked = Support.newVm(memory, routineResults)
    assertTrue(state.header.version == 5, "these tests assume V5; Adventureland is V5")
    return state, transport, client, asked
end

-- Gives a request a list of replies, one per call.
local function scripted(replies: { { [string]: any } }): (any) -> { [string]: any }
    local index = 0
    return function()
        index += 1
        return assert(replies[index], "the request was made more often than the test scripted")
    end
end

-- Where the data goes (the opcode harness uses the first half).
local function dataAddr(state: ZState.ZState): number
    return scratchBase(state) + 32
end

local function opsOf(transport: any): string
    local ops = {}
    for _, request in transport.requests do
        table.insert(ops, request.op)
    end
    return table.concat(ops, ",")
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME, { ramFlatLimit = 0 })
    if not memory then
        return
    end

    -- This script is close to the memory limit: smaller caches leave room.
    memory.ramMaxResident = 4
    memory.romCacheMaxSize = 2

    ------------------------------------------------------------------
    -- read
    ------------------------------------------------------------------

    runTest("read (V5) asks the service to read into the buffers, and stores the terminating key", function()
        local state, transport = newVm()
        transport.replies.read = { status = "line", key = 13 }
        local text, parse = dataAddr(state), dataAddr(state) + 16
        execInstruction(state, { 0xE4 }, { text, parse }, { 0 })
        local request = transport.requests[1]
        assertEqual(request.op, "read")
        assertEqual(request.args.text, text)
        assertEqual(request.args.parse, parse)
        assertEqual(request.args.timeout, 0, "no timeout")
        assertEqual(request.args.status, nil, "no status line in V5")
        assertEqual(state:pop(), 13)
    end)

    runTest("read (V3) stores nothing and sends the status line information", function()
        local state, transport = newVm()
        state.header.version = 3
        state.header.flags1 = 2
        local globals = state.header.globals
        state.memory:writeU16(globals, 0)        -- no location object
        state.memory:writeU16(globals + 2, 7)
        state.memory:writeU16(globals + 4, 3)
        transport.replies.read = { status = "line", key = 13 }
        local spBefore = state.sp
        execInstruction(state, { 0xE4 }, { dataAddr(state), 0 }, {})
        assertEqual(state.sp, spBefore, "V3 read stores nothing")
        local status = transport.requests[1].args.status
        assertEqual(#status.words, 0)
        assertEqual(status.first, 7)
        assertEqual(status.second, 3)
        assertEqual(status.isTime, true, "flags1 bit 1 says time game")
    end)

    runTest("read: a timeout runs the routine, and 0 waits again", function()
        local state, transport, _, asked = newVm({ 0, 0 })
        transport.replies.read = scripted({
            { status = "timeout" }, { status = "timeout" }, { status = "line", key = 13 },
        })
        execInstruction(state, { 0xE4 }, { dataAddr(state), 0, 50, 0x1234 }, { 0 })
        assertEqual(opsOf(transport), "read,read,read")
        assertEqual(#asked, 2, "the routine ran at each timeout")
        assertEqual(asked[1], 0x1234)
        assertEqual(transport.requests[1].args.timeout, 50)
        assertEqual(state:pop(), 13)
    end)

    runTest("read: a routine that returns non-zero ends the input; key 0 is stored", function()
        local state, transport, _, asked = newVm({ 1 })
        transport.replies.read = { status = "timeout" }
        transport.replies.read_end = { key = 0 }
        local text = dataAddr(state)
        execInstruction(state, { 0xE4 }, { text, 0, 20, 0x2222 }, { 0 })
        assertEqual(#asked, 1)
        assertEqual(opsOf(transport), "read,read_end")
        assertEqual(transport.requests[2].args.text, text)
        assertEqual(state:pop(), 0)
    end)

    runTest("read: a timeout with no routine keeps waiting without calling anything", function()
        local state, transport, _, asked = newVm()
        transport.replies.read = scripted({ { status = "timeout" }, { status = "line", key = 13 } })
        execInstruction(state, { 0xE4 }, { dataAddr(state), 0, 30 }, { 0 })
        assertEqual(#asked, 0)
        assertEqual(opsOf(transport), "read,read")
        assertEqual(state:pop(), 13)
    end)

    ------------------------------------------------------------------
    -- read_char, tokenise, encode_text, print_table
    ------------------------------------------------------------------

    runTest("read_char stores the key the service reports", function()
        local state, transport = newVm()
        transport.replies.read_char = { status = "key", value = 120 }
        execInstruction(state, { 0xF6 }, { 1 }, { 0 })
        assertEqual(state:pop(), 120)
        assertEqual(transport.requests[1].args.timeout, 0)
    end)

    runTest("read_char times out through the routine and stores 0", function()
        local state, transport, _, asked = newVm({ 0, 1 })
        transport.replies.read_char = scripted({ { status = "timeout" }, { status = "timeout" } })
        execInstruction(state, { 0xF6 }, { 1, 15, 0x4321 }, { 0 })
        assertEqual(#asked, 2)
        assertEqual(asked[2], 0x4321)
        assertEqual(transport.requests[1].args.timeout, 15)
        assertEqual(state:pop(), 0)
    end)

    TestFramework.printSummary("Input opcode tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

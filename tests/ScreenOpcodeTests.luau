---------------------------------------------------------------------
-- Tests for tokenise, encode_text, print_table, show_status, restart, the
-- window and cursor opcodes, fonts and colours. read and read_char are in
-- IoOpcodeTests.
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

    runTest("tokenise passes its operands, with the dictionary and skip flag defaulted", function()
        local state, transport = newVm()
        execInstruction(state, { 0xFB }, { 100, 200 }, {})
        local first = transport.requests[1].args
        assertEqual(first.text, 100)
        assertEqual(first.parse, 200)
        assertEqual(first.dict, 0)
        assertEqual(first.skip, false)
        execInstruction(state, { 0xFB }, { 100, 200, 300, 1 }, {})
        local second = transport.requests[2].args
        assertEqual(second.dict, 300)
        assertEqual(second.skip, true)
    end)

    runTest("encode_text passes its four operands", function()
        local state, transport = newVm()
        execInstruction(state, { 0xFC }, { 100, 4, 2, 300 }, {})
        local args = transport.requests[1].args
        assertEqual(transport.requests[1].op, "encode_text")
        assertEqual(args.text, 100)
        assertEqual(args.length, 4)
        assertEqual(args.offset, 2)
        assertEqual(args.dest, 300)
    end)

    runTest("print_table passes its operands with height 1 and skip 0 by default", function()
        local state, transport = newVm()
        execInstruction(state, { 0xFE }, { 100, 3 }, {})
        local first = transport.requests[1].args
        assertEqual(first.addr, 100)
        assertEqual(first.width, 3)
        assertEqual(first.height, 1)
        assertEqual(first.skip, 0)
        execInstruction(state, { 0xFE }, { 100, 3, 2, 5 }, {})
        local second = transport.requests[2].args
        assertEqual(second.height, 2)
        assertEqual(second.skip, 5)
    end)

    ------------------------------------------------------------------
    -- Windows, cursor, fonts, colours
    ------------------------------------------------------------------

    runTest("window, cursor, style and colour opcodes queue window entries", function()
        local state, transport, client = newVm()
        execInstruction(state, { 0xEA }, { 4 }, {})          -- split_window
        execInstruction(state, { 0xEB }, { 1 }, {})          -- set_window
        execInstruction(state, { 0xED }, { 0xFFFF }, {})     -- erase_window -1
        execInstruction(state, { 0xED }, { 0 }, {})          -- erase_window 0
        execInstruction(state, { 0xEE }, { 1 }, {})          -- erase_line
        execInstruction(state, { 0xEF }, { 3, 5 }, {})       -- set_cursor
        execInstruction(state, { 0xEF }, { 0xFFFF, 0 }, {})  -- set_cursor -1 (cursor off)
        execInstruction(state, { 0xF1 }, { 2 }, {})          -- set_text_style
        execInstruction(state, { 0xDB }, { 3, 4 }, {})       -- set_colour
        execInstruction(state, { 0xF2 }, { 0 }, {})          -- buffer_mode
        local entries = Support.entries(client, transport)
        local texts = {}
        for _, entry in entries do
            table.insert(texts, table.concat(entry, " "))
        end
        assertEqual(table.concat(texts, "; "),
            "w split 4; w set 1; w erase -1; w erase 0; w eraseline 1; w cursor 3 5; "
            .. "w cursor -1 0; w style 2; w colour 3 4; w buffer 0")
    end)

    runTest("an illegal window raises ERR_ILL_WIN for set_window and erase_window", function()
        local state = newVm()
        assertRuntimeError(function()
            execInstruction(state, { 0xEB }, { 2 }, {})
        end, ZState.Errors.ILL_WIN)
        assertRuntimeError(function()
            execInstruction(state, { 0xED }, { 2 }, {})
        end, ZState.Errors.ILL_WIN)
        assertRuntimeError(function()
            execInstruction(state, { 0xEB }, { 0xFFFD }, {})  -- -3 is only for V6
        end, ZState.Errors.ILL_WIN)
    end)

    runTest("get_cursor writes the reply's row and column into the table", function()
        local state, transport = newVm()
        transport.replies.get_cursor = { row = 3, column = 5 }
        local tableAddr = dataAddr(state)
        execInstruction(state, { 0xF0 }, { tableAddr }, {})
        assertEqual(state.memory:readU16(tableAddr), 3, "row")
        assertEqual(state.memory:readU16(tableAddr + 2), 5, "column")
    end)

    runTest("set_font stores the previous font the service reports", function()
        local state, transport = newVm()
        transport.replies.set_font = function(args)
            return { value = if args.font == 1 or args.font == 0 then 1 else 0 }
        end
        assertEqual(evalExt(state, 0x04, { 0 }), 1)
        assertEqual(evalExt(state, 0x04, { 1 }), 1)
        assertEqual(evalExt(state, 0x04, { 3 }), 0)
        assertEqual(transport.requests[3].args.font, 3)
    end)

    runTest("opcodes with no effect on a text host still consume their operands and send nothing", function()
        local state, transport, client = newVm()
        local cases = {
            { { 0xF5 }, { 1 } },           -- sound_effect
            { { 0xF4 }, { 0 } },           -- input_stream
            { { 0xBE, 0x0D }, { 1, 2 } },  -- set_true_colour
        }
        for _, case in cases do
            local base, length = execInstruction(state, case[1], case[2], {})
            assertEqual(state.pc, base + length, "pc just past the instruction")
        end
        assertEqual(#Support.entries(client, transport), 0)
        assertEqual(#transport.requests, 0)
    end)

    ------------------------------------------------------------------
    -- Status line and restart
    ------------------------------------------------------------------

    runTest("show_status queues the status line in V3 only", function()
        local state, transport, client = newVm()
        local globals = state.header.globals
        state.memory:writeU16(globals, 0)
        state.memory:writeU16(globals + 2, 9)
        state.memory:writeU16(globals + 4, 4)

        state.pc = Harness.writeBytecode(state, { 0xBC })
        ZOpcodes.step(state)
        assertEqual(#Support.entries(client, transport), 0, "V5 has no status line")

        state.header.version = 3
        state.header.flags1 = 0
        state.pc = Harness.writeBytecode(state, { 0xBC })
        ZOpcodes.step(state)
        local entries = Support.entries(client, transport)
        assertEqual(entries[1][1], "st")
        assertEqual(entries[1][2].first, 9)
        assertEqual(entries[1][2].second, 4)
        assertEqual(entries[1][2].isTime, false)
    end)

    runTest("restart sends pending output, reloads memory, resets the PC and the service", function()
        local state, transport, client = newVm()
        state:restart()  -- the first restart keeps the freshly loaded RAM
        local addr = scratchBase(state) + 40
        local original = state.memory:readOriginalU8(addr)
        state.memory:writeU8(addr, bit32.bxor(original, 0xFF))
        state:push(1234)
        execInstruction(state, { 0xE5 }, { 70 }, {})  -- print_char F, pending

        state.pc = Harness.writeBytecode(state, { 0xB7 })
        ZOpcodes.step(state)
        assertEqual(state.pc, state.header.initialPC)
        assertEqual(state.memory:readU8(addr), original, "RAM was reloaded")
        assertEqual(state.fp, state.sp, "the stack was reset")
        assertEqual(table.concat(transport.log, ","), "out,reset", "the text went out before the reset")
        assertEqual(transport.batches[1][1][2], 70)
    end)

    TestFramework.printSummary("Screen opcode tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

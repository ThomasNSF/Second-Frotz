---------------------------------------------------------------------
-- Audit of the opcode dispatch tables (Phase 4.6): every slot is a real
-- handler, a genuinely illegal slot, or an `unsupported` stub, and each
-- stub is one we expect. As features land, remove names from the
-- expected lists below; a stub that disappears or appears unexpectedly
-- fails the audit.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")
local Harness = require("OpcodeHarness.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local execInstruction = Harness.execInstruction

local memory: ZMemory.ZMemory?

-- Slots that no Z-machine version defines.
local EXPECTED_ILLEGAL = {
    op0 = {},
    op1 = {},
    var = { 0x00, 0x1D, 0x1E, 0x1F },
    ext = { 0x0E, 0x0F },
}

-- Valid opcodes this port does not provide, by table and slot.
local EXPECTED_UNSUPPORTED = {
    op0 = { [0x5] = "save", [0x6] = "restore" },
    op1 = {},
    var = {},
    ext = {
        [0x00] = "save", [0x01] = "restore", [0x05] = "draw_picture",
        [0x06] = "picture_data", [0x07] = "erase_picture", [0x08] = "set_margins",
        [0x10] = "move_window", [0x11] = "window_size",
        [0x12] = "window_style", [0x13] = "get_wind_prop", [0x14] = "scroll_window",
        [0x16] = "read_mouse", [0x17] = "mouse_window", [0x19] = "put_wind_prop",
        [0x1A] = "print_form", [0x1B] = "make_menu", [0x1C] = "picture_table",
    },
}

local TABLE_SIZES = { op0 = 16, op1 = 16, var = 64, ext = 29 }

local function newState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

-- Runs fn and returns the error table it raised, or nil.
local function raised(fn: () -> ()): any
    local ok, err = pcall(fn)
    if ok then
        return nil
    end
    return err
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    for _, version in { 3, 5 } do
        ZOpcodes.applyVersionPatches(version)
        for tableName, handlers in { op0 = ZOpcodes.op0, op1 = ZOpcodes.op1, var = ZOpcodes.var, ext = ZOpcodes.ext } do
            runTest(`table audit (V{version}): {tableName} is complete and every stub is expected`, function()
                local count, stubs, illegalSlots = 0, 0, 0
                local illegalSet = {}
                for _, slot in EXPECTED_ILLEGAL[tableName] do
                    illegalSet[slot] = true
                end
                for slot, handler in handlers do
                    count += 1
                    local name = ZOpcodes.unsupportedNames[handler]
                    local label = string.format("%s[0x%02X]", tableName, slot)
                    if name then
                        stubs += 1
                        assertEqual(name, EXPECTED_UNSUPPORTED[tableName][slot], label .. " is an unexpected stub")
                    elseif handler == ZOpcodes.illegal then
                        illegalSlots += 1
                        assertTrue(illegalSet[slot] == true, label .. " is illegal but should have a handler")
                    else
                        assertTrue(EXPECTED_UNSUPPORTED[tableName][slot] == nil, label .. " lost its stub without being removed from the expected list")
                    end
                end
                assertEqual(count, TABLE_SIZES[tableName], "slots in " .. tableName)
                assertEqual(illegalSlots, #EXPECTED_ILLEGAL[tableName], "illegal slots")
                local expectedStubs = 0
                for _ in EXPECTED_UNSUPPORTED[tableName] do
                    expectedStubs += 1
                end
                assertEqual(stubs, expectedStubs, "unsupported slots")
            end)
        end
    end
    ZOpcodes.applyVersionPatches(5)

    runTest("an unsupported opcode raises ERR_UNSUPPORTED naming the opcode", function()
        local state = newState()
        local err = raised(function()
            execInstruction(state, { 0xBE, 0x05 }, { 1, 2, 3, 4 }, {})  -- draw_picture
        end)
        assertTrue(err ~= nil and err.fatal == true, "fatal error table")
        assertEqual(err.code, ZState.Errors.UNSUPPORTED)
        assertEqual(err.opcode, "draw_picture")
        assertEqual(err.message, "Unsupported opcode: draw_picture")

        err = raised(function()
            execInstruction(state, { 0xC0 + 0x2A }, { 1 }, {})  -- split_window
        end)
        assertEqual(err.opcode, "split_window")
    end)

    runTest("a genuinely illegal slot still raises ERR_ILL_OPCODE", function()
        local state = newState()
        local err = raised(function()
            execInstruction(state, { 0xBE, 0x0E }, {}, {})
        end)
        assertEqual(err.code, ZState.Errors.ILL_OPCODE)
    end)

    runTest("save_undo reports undo unavailable and restore_undo reports failure", function()
        local state = newState()
        assertEqual(Harness.evalExt(state, 0x09, {}), 0xFFFF, "save_undo stores -1")
        assertEqual(Harness.evalExt(state, 0x0A, {}), 0, "restore_undo stores 0")
    end)

    TestFramework.printSummary("Opcode table audit")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

---------------------------------------------------------------------
-- Test harness for the ZOpcodes object handlers (Phase 4.4): tree reads
-- and mutation, attributes, and properties. Dispatch and control-flow
-- tests are in OpcodeTests.luau, arithmetic/memory-table tests in
-- MathOpcodeTests.luau; shared bytecode helpers are in
-- OpcodeHarness.luau.
--
-- Tests run against Adventureland's real object table (V5, so raw
-- offsets assume the V4+ layout) and rewire objects via TestFramework's
-- withTestTree/withPropertyTable, restoring them afterwards. Mutates
-- dynamic memory; do not follow with real interpretation on the same
-- loaded modules.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZObject = require("../VM/ZObject.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")
local Harness = require("OpcodeHarness.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local assertRuntimeError = TestFramework.assertRuntimeError
local execInstruction = Harness.execInstruction
local evalVar = Harness.evalVar
local branches = Harness.branches
local exec1op = Harness.exec1op
local assertBytes = Harness.assertBytes

local memory: ZMemory.ZMemory?

local function freshState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

-- Raw V4+ link read, deliberately independent of ZObject's layout table.
local function rawLink(state: ZState.ZState, obj: number, offset: number): number
    return state.memory:readU16(state.header.objects + 126 + (obj - 1) * 14 + offset)
end

-- Raw V4+ attribute byte i (0-5) of an object, independent of ZObject's
-- layout table.
local function rawAttrByte(state: ZState.ZState, obj: number, i: number): number
    return state.memory:readU8(state.header.objects + 126 + (obj - 1) * 14 + i)
end

-- Runs fn, then restores the object's six attribute bytes even if fn fails.
local function withAttributesRestored(state: ZState.ZState, obj: number, fn: () -> ())
    local saved = {}
    for i = 0, 5 do
        saved[i] = rawAttrByte(state, obj, i)
    end
    local ok, err = pcall(fn)
    for i = 0, 5 do
        assert(state.memory:writeU8(state.header.objects + 126 + (obj - 1) * 14 + i, saved[i]))
    end
    if not ok then
        error(err, 0)
    end
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    ------------------------------------------------------------------
    -- Object tree reads (Phase 4.4.3)
    ------------------------------------------------------------------

    runTest("get_parent, get_child, get_sibling match the object table for every object", function()
        local state = freshState()
        assertTrue(state.header.version >= 4, "raw offsets assume the V4+ layout; Adventureland is V5")
        for obj = 1, TestFramework.objectCount(state) do
            exec1op(state, 0x3, obj, { 0 })
            assertEqual(state:pop(), rawLink(state, obj, 6), "parent of " .. obj)

            local base, length = exec1op(state, 0x2, obj, { 0, 0xCA })
            local child = rawLink(state, obj, 10)
            assertEqual(state:pop(), child, "child of " .. obj)
            assertEqual(state.pc == base + length + 8, child ~= 0, "get_child branches iff there is a child: " .. obj)

            base, length = exec1op(state, 0x1, obj, { 0, 0xCA })
            local sibling = rawLink(state, obj, 8)
            assertEqual(state:pop(), sibling, "sibling of " .. obj)
            assertEqual(state.pc == base + length + 8, sibling ~= 0, "get_sibling branches iff there is a sibling: " .. obj)
        end
    end)

    runTest("jin tests the parent link for every object", function()
        local state = freshState()
        for obj = 1, TestFramework.objectCount(state) do
            local parent = rawLink(state, obj, 6)
            assertEqual(branches(state, 0x06, { obj, parent }), true, "jin " .. obj .. " in its parent")
            assertEqual(branches(state, 0x06, { obj, obj }), false, "no object is inside itself: " .. obj)
            assertEqual(branches(state, 0x06, { obj, parent + 1 }), false, "wrong parent: " .. obj)
        end
    end)

    runTest("object 0 reports a warning and uses each opcode's fallback", function()
        local state = freshState()
        exec1op(state, 0x3, 0, { 0 })
        assertEqual(state:pop(), 0, "get_parent 0 stores 0")

        local base, length = exec1op(state, 0x2, 0, { 0, 0xCA })
        assertEqual(state:pop(), 0, "get_child 0 stores 0")
        assertEqual(state.pc, base + length, "get_child 0 does not branch")

        base, length = exec1op(state, 0x1, 0, { 0, 0xCA })
        assertEqual(state:pop(), 0, "get_sibling 0 stores 0")
        assertEqual(state.pc, base + length, "get_sibling 0 does not branch")

        assertEqual(branches(state, 0x06, { 0, 0 }), true, "jin 0, 0 branches")
        assertEqual(branches(state, 0x06, { 0, 5 }), false, "jin 0, 5 does not")

        for _, code in { ZState.Warnings.GET_PARENT_0, ZState.Warnings.GET_CHILD_0,
                         ZState.Warnings.GET_SIBLING_0 } do
            assertEqual(state.warningCounts[code], 1, "warning " .. code)
        end
        assertEqual(state.warningCounts[ZState.Warnings.JIN_0], 2, "both jin calls warn")
    end)

    runTest("a nonexistent object raises ERR_ILL_OBJ through the opcode", function()
        local state = freshState()
        assertRuntimeError(function()
            exec1op(state, 0x3, 0xFFFF, { 0 })
        end, ZState.Errors.ILL_OBJ)
    end)

    ------------------------------------------------------------------
    -- Object tree mutation (Phase 4.4.4)
    ------------------------------------------------------------------

    runTest("remove_obj unlinks through the opcode", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            exec1op(state, 0x9, 3, {})  -- remove_obj 3
            assertEqual(rawLink(state, 2, 8), 4, "sibling chain closes over 3")
            assertEqual(rawLink(state, 3, 6), 0, "3 has no parent")
        end)
    end)

    runTest("insert_obj moves an object through the opcode", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            execInstruction(state, { 0xC0 + 0x0E }, { 5, 1 }, {})  -- insert_obj 5, 1
            assertEqual(rawLink(state, 1, 10), 5, "5 is now 1's first child")
            assertEqual(rawLink(state, 5, 8), 2, "and points at the old first child")
            assertEqual(rawLink(state, 5, 6), 1, "with 1 as its parent")
        end)
    end)

    runTest("remove_obj and insert_obj with object 0 warn and change nothing", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            exec1op(state, 0x9, 0, {})
            execInstruction(state, { 0xC0 + 0x0E }, { 0, 1 }, {})
            execInstruction(state, { 0xC0 + 0x0E }, { 1, 0 }, {})
            assertEqual(state.warningCounts[ZState.Warnings.REMOVE_OBJECT_0], 1)
            assertEqual(state.warningCounts[ZState.Warnings.MOVE_OBJECT_0], 1)
            assertEqual(state.warningCounts[ZState.Warnings.MOVE_OBJECT_TO_0], 1)
            assertEqual(rawLink(state, 1, 10), 2, "the tree is untouched")
        end)
    end)

    ------------------------------------------------------------------
    -- Object attributes (Phase 4.4.5)
    ------------------------------------------------------------------

    local TEST_ATTR, SET_ATTR, CLEAR_ATTR = 0x0A, 0x0B, 0x0C

    runTest("test_attr matches the raw attribute bits for every object", function()
        local state = freshState()
        assertTrue(state.header.version >= 4, "raw offsets assume the V4+ layout; Adventureland is V5")
        for obj = 1, TestFramework.objectCount(state) do
            for _, attr in { 0, 7, 8, 31, 32, 47 } do
                local expected = bit32.band(rawAttrByte(state, obj, bit32.rshift(attr, 3)),
                    bit32.rshift(0x80, bit32.band(attr, 7))) ~= 0
                assertEqual(branches(state, TEST_ATTR, { obj, attr }), expected,
                    "object " .. obj .. " attribute " .. attr)
            end
        end
    end)

    runTest("set_attr and clear_attr change only their own bit", function()
        local state = freshState()
        assertTrue(state.header.version >= 4, "raw offsets assume the V4+ layout; Adventureland is V5")
        local obj = 5
        withAttributesRestored(state, obj, function()
            for _, attr in { 0, 7, 8, 47 } do
                local byteIndex = bit32.rshift(attr, 3)
                local mask = bit32.rshift(0x80, bit32.band(attr, 7))

                execInstruction(state, { 0xC0 + CLEAR_ATTR }, { obj, attr }, {})
                local others = bit32.band(rawAttrByte(state, obj, byteIndex), bit32.bnot(mask))
                assertEqual(branches(state, TEST_ATTR, { obj, attr }), false, "cleared " .. attr)

                execInstruction(state, { 0xC0 + SET_ATTR }, { obj, attr }, {})
                assertEqual(rawAttrByte(state, obj, byteIndex), bit32.bor(others, mask), "set " .. attr)
                assertEqual(branches(state, TEST_ATTR, { obj, attr }), true, "set reads back " .. attr)

                execInstruction(state, { 0xC0 + SET_ATTR }, { obj, attr }, {})
                assertEqual(rawAttrByte(state, obj, byteIndex), bit32.bor(others, mask), "setting twice changes nothing")

                execInstruction(state, { 0xC0 + CLEAR_ATTR }, { obj, attr }, {})
                assertEqual(rawAttrByte(state, obj, byteIndex), others, "clear " .. attr)
                execInstruction(state, { 0xC0 + CLEAR_ATTR }, { obj, attr }, {})
                assertEqual(rawAttrByte(state, obj, byteIndex), others, "clearing twice changes nothing")
            end
        end)
    end)

    runTest("attribute numbers above 47 raise ERR_ILL_ATTR, even for object 0", function()
        local state = freshState()
        assertEqual(branches(state, TEST_ATTR, { 1, 47 }) ~= nil, true, "attribute 47 is legal")
        for _, obj in { 1, 0 } do
            assertRuntimeError(function()
                branches(state, TEST_ATTR, { obj, 48 })
            end, ZState.Errors.ILL_ATTR, "test_attr " .. obj)
            assertRuntimeError(function()
                execInstruction(state, { 0xC0 + SET_ATTR }, { obj, 48 }, {})
            end, ZState.Errors.ILL_ATTR, "set_attr " .. obj)
            assertRuntimeError(function()
                execInstruction(state, { 0xC0 + CLEAR_ATTR }, { obj, 48 }, {})
            end, ZState.Errors.ILL_ATTR, "clear_attr " .. obj)
        end
    end)

    runTest("attribute opcodes with object 0 warn and change nothing", function()
        local state = freshState()
        assertEqual(branches(state, TEST_ATTR, { 0, 3 }), false, "test_attr 0 does not branch")
        local before = rawAttrByte(state, 1, 0)
        execInstruction(state, { 0xC0 + SET_ATTR }, { 0, 0 }, {})
        execInstruction(state, { 0xC0 + CLEAR_ATTR }, { 0, 0 }, {})
        assertEqual(rawAttrByte(state, 1, 0), before, "no object was touched")
        assertEqual(state.warningCounts[ZState.Warnings.TEST_ATTR_0], 1)
        assertEqual(state.warningCounts[ZState.Warnings.SET_ATTR_0], 1)
        assertEqual(state.warningCounts[ZState.Warnings.CLEAR_ATTR_0], 1)
    end)

    runTest("a nonexistent object raises ERR_ILL_OBJ through set_attr", function()
        local state = freshState()
        assertRuntimeError(function()
            execInstruction(state, { 0xC0 + SET_ATTR }, { 0xFFFF, 0 }, {})
        end, ZState.Errors.ILL_OBJ)
    end)

    ------------------------------------------------------------------
    -- Object properties (Phase 4.4.6b). The synthetic tests run against
    -- TestFramework.sampleProperties on object 5; data addresses are
    -- first + 1 (id 20), + 4 (id 15), + 7 (id 10), + 12 (id 3).
    ------------------------------------------------------------------

    local GET_PROP, GET_PROP_ADDR, GET_NEXT_PROP, PUT_PROP = 0x11, 0x12, 0x13, 0x23
    local sample = TestFramework.sampleProperties

    local function propLen(state: ZState.ZState, addr: number): number
        exec1op(state, 0x4, addr, { 0 })  -- get_prop_len
        return state:pop()
    end

    runTest("get_prop reads byte and word properties and falls back to the defaults table", function()
        local state = freshState()
        assertTrue(state.header.version >= 4, "sample properties use the V4+ encoding; Adventureland is V5")
        local default7Addr = state.header.objects + 2 * (7 - 1)
        local default25Addr = state.header.objects + 2 * (25 - 1)
        local saved7, saved25 = state.memory:readU16(default7Addr), state.memory:readU16(default25Addr)
        assert(state.memory:writeU16(default7Addr, 0x1111))
        assert(state.memory:writeU16(default25Addr, 0x2222))
        TestFramework.withPropertyTable(state, 5, sample, function()
            assertEqual(evalVar(state, GET_PROP, { 5, 20 }), 0x1234, "word property")
            assertEqual(evalVar(state, GET_PROP, { 5, 15 }), 0x77, "byte property reads one byte")
            assertEqual(evalVar(state, GET_PROP, { 5, 3 }), 0xABCD, "last property")
            assertEqual(evalVar(state, GET_PROP, { 5, 7 }), 0x1111, "absent between properties: default")
            assertEqual(evalVar(state, GET_PROP, { 5, 25 }), 0x2222, "absent above the first: default")
        end)
        assert(state.memory:writeU16(default7Addr, saved7))
        assert(state.memory:writeU16(default25Addr, saved25))
    end)

    runTest("get_prop_addr returns data addresses, skipping the two-byte size field", function()
        local state = freshState()
        TestFramework.withPropertyTable(state, 5, sample, function(first)
            assertEqual(evalVar(state, GET_PROP_ADDR, { 5, 20 }), first + 1, "id 20")
            assertEqual(evalVar(state, GET_PROP_ADDR, { 5, 15 }), first + 4, "id 15")
            assertEqual(evalVar(state, GET_PROP_ADDR, { 5, 10 }), first + 7, "id 10 has a two-byte size field")
            assertEqual(evalVar(state, GET_PROP_ADDR, { 5, 3 }), first + 12, "id 3")
            assertEqual(evalVar(state, GET_PROP_ADDR, { 5, 7 }), 0, "absent between properties")
            assertEqual(evalVar(state, GET_PROP_ADDR, { 5, 25 }), 0, "absent above the first")
        end)
    end)

    runTest("get_prop_len decodes the size at each data address; address 0 gives 0", function()
        local state = freshState()
        TestFramework.withPropertyTable(state, 5, sample, function(first)
            assertEqual(propLen(state, first + 1), 2, "id 20")
            assertEqual(propLen(state, first + 4), 1, "id 15")
            assertEqual(propLen(state, first + 7), 4, "id 10, two-byte form")
            assertEqual(propLen(state, first + 12), 2, "id 3")
        end)
        assertEqual(propLen(state, 0), 0, "Spec 1.1: address 0 has length 0")
    end)

    runTest("get_next_prop walks the list in descending order; a missing property raises ERR_NO_PROP", function()
        local state = freshState()
        TestFramework.withPropertyTable(state, 5, sample, function()
            assertEqual(evalVar(state, GET_NEXT_PROP, { 5, 0 }), 20, "first")
            assertEqual(evalVar(state, GET_NEXT_PROP, { 5, 20 }), 15)
            assertEqual(evalVar(state, GET_NEXT_PROP, { 5, 15 }), 10)
            assertEqual(evalVar(state, GET_NEXT_PROP, { 5, 10 }), 3, "steps over the two-byte size field")
            assertEqual(evalVar(state, GET_NEXT_PROP, { 5, 3 }), 0, "end of list")
            assertRuntimeError(function()
                evalVar(state, GET_NEXT_PROP, { 5, 7 })
            end, ZState.Errors.NO_PROP)
        end)
    end)

    runTest("put_prop writes words and bytes by property size; a missing property raises ERR_NO_PROP", function()
        local state = freshState()
        TestFramework.withPropertyTable(state, 5, sample, function(first)
            execInstruction(state, { 0xC0 + PUT_PROP }, { 5, 20, 0xBEEF }, {})
            assertBytes(state, first + 1, { 0xBE, 0xEF }, "word property")
            assertEqual(evalVar(state, GET_PROP, { 5, 20 }), 0xBEEF, "reads back")

            execInstruction(state, { 0xC0 + PUT_PROP }, { 5, 15, 0x1234 }, {})
            assertEqual(state.memory:readU8(first + 4), 0x34, "byte property takes the low byte")
            assertEqual(state.memory:readU8(first + 5), 0x8A, "the next property's size byte is untouched")

            assertRuntimeError(function()
                execInstruction(state, { 0xC0 + PUT_PROP }, { 5, 7, 1 }, {})
            end, ZState.Errors.NO_PROP)
        end)
    end)

    runTest("property opcodes with object 0 warn and use their fallbacks; a nonexistent object raises ERR_ILL_OBJ", function()
        local state = freshState()
        assertEqual(evalVar(state, GET_PROP, { 0, 5 }), 0, "get_prop 0")
        assertEqual(evalVar(state, GET_PROP_ADDR, { 0, 5 }), 0, "get_prop_addr 0")
        assertEqual(evalVar(state, GET_NEXT_PROP, { 0, 0 }), 0, "get_next_prop 0")
        execInstruction(state, { 0xC0 + PUT_PROP }, { 0, 5, 1 }, {})
        for _, code in { ZState.Warnings.GET_PROP_0, ZState.Warnings.GET_PROP_ADDR_0,
                         ZState.Warnings.GET_NEXT_PROP_0, ZState.Warnings.PUT_PROP_0 } do
            assertEqual(state.warningCounts[code], 1, "warning " .. code)
        end
        assertRuntimeError(function()
            evalVar(state, GET_PROP, { 0xFFFF, 5 })
        end, ZState.Errors.ILL_OBJ)
    end)

    runTest("real objects: property walks, addresses, lengths and values agree; put_prop round-trips", function()
        local state = freshState()
        local roundTripped = false
        for obj = 1, math.min(30, TestFramework.objectCount(state)) do
            local id = evalVar(state, GET_NEXT_PROP, { obj, 0 })
            local previous = math.huge
            while id ~= 0 do
                assertTrue(id < previous, "object " .. obj .. ": ids descend")
                previous = id

                local addr = evalVar(state, GET_PROP_ADDR, { obj, id })
                assertTrue(addr ~= 0, "object " .. obj .. " property " .. id .. " has an address")
                local length = propLen(state, addr)
                assertEqual(length, ZObject.dataLength(state, addr), "length of " .. obj .. "/" .. id)

                if length <= 2 then
                    local raw = if length == 1 then state.memory:readU8(addr) else state.memory:readU16(addr)
                    local value = evalVar(state, GET_PROP, { obj, id })
                    assertEqual(value, raw, "get_prop matches the raw data of " .. obj .. "/" .. id)

                    if not roundTripped then
                        roundTripped = true
                        local changed = bit32.band(raw + 1, if length == 1 then 0xFF else 0xFFFF)
                        execInstruction(state, { 0xC0 + PUT_PROP }, { obj, id, changed }, {})
                        assertEqual(evalVar(state, GET_PROP, { obj, id }), changed, "put_prop then get_prop")
                        execInstruction(state, { 0xC0 + PUT_PROP }, { obj, id, raw }, {})
                        assertEqual(evalVar(state, GET_PROP, { obj, id }), raw, "original value restored")
                    end
                end
                id = evalVar(state, GET_NEXT_PROP, { obj, id })
            end
        end
        assertTrue(roundTripped, "at least one small property was found to round-trip")
    end)

    ------------------------------------------------------------------

    TestFramework.printSummary("ZOpcodes object tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

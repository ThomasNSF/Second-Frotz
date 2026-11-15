---------------------------------------------------------------------
-- Test harness for ZObject (Phase 4.4).
--
-- Structural tests run against the loaded story's real object table;
-- property size decoding is checked with synthetic bytes in scratch RAM.
-- Mutates dynamic memory; do not follow with real interpretation on the
-- same loaded modules.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZObject = require("../VM/ZObject.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local ERR_ILL_OBJ = ZState.Errors.ILL_OBJ

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local assertRuntimeError = TestFramework.assertRuntimeError
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt

local memory: ZMemory.ZMemory?

local function freshState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

-- The children of `parent` in chain order, as "2,3,4".
local function children(state: ZState.ZState, parent: number): string
    local list = {}
    local child = ZObject.child(state, parent)
    while child ~= 0 and #list < 10 do
        table.insert(list, child)
        child = ZObject.sibling(state, child)
    end
    return table.concat(list, ",")
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    runTest("object entries sit at fixed strides after the defaults table", function()
        local state = freshState()
        local v3 = state.header.version <= 3
        local first = state.header.objects + (if v3 then 62 else 126)
        local stride = if v3 then 9 else 14
        assertEqual(ZObject.address(state, 1), first, "object 1")
        assertEqual(ZObject.address(state, 2), first + stride, "object 2")
        assertEqual(ZObject.address(state, 10), first + 9 * stride, "object 10")
    end)

    runTest("object numbers beyond the table raise ERR_ILL_OBJ", function()
        local state = freshState()
        -- 256 exceeds the V1-V3 maximum; 65535 in V4+ lands far outside dynamic memory.
        local bad = if state.header.version <= 3 then 256 else 65535
        assertRuntimeError(function()
            ZObject.address(state, bad)
        end, ERR_ILL_OBJ)
    end)

    runTest("every real object has a terminating, descending property list", function()
        local state = freshState()
        local count = TestFramework.objectCount(state)
        assertTrue(count >= 1 and count <= 255, "derived object count should be plausible, got " .. count)

        local mask = if state.header.version <= 3 then 0x1F else 0x3F
        local tableEnd = ZObject.address(state, 1) + count * (ZObject.address(state, 2) - ZObject.address(state, 1))
        local staticBase = state.header.staticMemoryBase

        for obj = 1, count do
            local nameAddr = ZObject.nameAddress(state, obj)
            assertTrue(nameAddr >= tableEnd and nameAddr < staticBase, "object " .. obj .. " property table address")

            local prop = ZObject.firstProperty(state, obj)
            local previous = math.huge
            local steps = 0
            while state.memory:readU8(prop) ~= 0 do
                local id = bit32.band(state.memory:readU8(prop), mask)
                assertTrue(id < previous, "object " .. obj .. ": property numbers must descend")
                previous = id
                prop = ZObject.nextProperty(state, prop)
                steps += 1
                assertTrue(steps <= mask, "object " .. obj .. ": property list did not terminate")
            end
            assertTrue(prop < staticBase, "object " .. obj .. ": property list stays in dynamic memory")
        end
    end)

    runTest("nextProperty decodes the V4+ size encodings", function()
        local state = freshState()
        assertTrue(state.header.version >= 4, "assumes V4+ property encoding; Adventureland is V5")
        local base = scratchBase(state)
        writeBytesAt(state, base, {
            0x4A, 0xAA, 0xBB,    -- id 10, one-byte form, top bits 01 = size 2
            0x85, 0x83, 1, 2, 3, -- id 5, two-byte form, second byte size 3
            0x89, 0x80,          -- id 9, two-byte form, size field 0 means 64
        })
        assertEqual(ZObject.nextProperty(state, base), base + 3, "one-byte form, size 2")
        assertEqual(ZObject.nextProperty(state, base + 3), base + 8, "two-byte form, size 3")
        assertEqual(ZObject.nextProperty(state, base + 8), base + 8 + 2 + 64, "size 0 means 64")
    end)

    runTest("the object tree is consistent: each object sits in exactly one parent chain", function()
        local state = freshState()
        local count = TestFramework.objectCount(state)
        local withParent = 0
        for obj = 1, count do
            if ZObject.parent(state, obj) ~= 0 then
                withParent += 1
            end
        end

        local visited = {}
        local chained = 0
        for parent = 1, count do
            local child = ZObject.child(state, parent)
            local steps = 0
            while child ~= 0 do
                assertTrue(child <= count, "child number in range")
                assertEqual(ZObject.parent(state, child), parent, "child's parent link")
                assertTrue(visited[child] == nil, "object appears in only one chain")
                visited[child] = true
                chained += 1
                steps += 1
                assertTrue(steps <= count, "sibling chain must terminate")
                child = ZObject.sibling(state, child)
            end
        end
        assertEqual(chained, withParent, "every parented object is reachable through its parent's chain")
    end)

    ------------------------------------------------------------------
    -- Tree mutation (Phase 4.4.4). Tree: 1 has children 2, 3, 4; 5, 6 detached.
    ------------------------------------------------------------------

    runTest("unlink removes the first child", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.unlink(state, 2)
            assertEqual(children(state, 1), "3,4")
            assertEqual(ZObject.parent(state, 2), 0)
            assertEqual(ZObject.sibling(state, 2), 0)
        end)
    end)

    runTest("unlink removes a middle child, closing the sibling chain over it", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.unlink(state, 3)
            assertEqual(children(state, 1), "2,4")
            assertEqual(ZObject.parent(state, 3), 0)
        end)
    end)

    runTest("unlink removes the last child", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.unlink(state, 4)
            assertEqual(children(state, 1), "2,3")
        end)
    end)

    runTest("unlink of an object with no parent changes nothing", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.unlink(state, 5)
            assertEqual(children(state, 1), "2,3,4")
            assertEqual(ZObject.parent(state, 5), 0)
        end)
    end)

    runTest("unlink carries the object's own subtree with it", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.setChild(state, 3, 5)
            ZObject.setParent(state, 5, 3)
            ZObject.unlink(state, 3)
            assertEqual(children(state, 1), "2,4")
            assertEqual(children(state, 3), "5", "3 keeps its child")
            assertEqual(ZObject.parent(state, 5), 3)
        end)
    end)

    runTest("unlink raises ERR_ILL_OBJ when the object is missing from its parent's chain", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.setParent(state, 5, 1)  -- claims parent 1, but is not in its chain
            assertRuntimeError(function()
                ZObject.unlink(state, 5)
            end, ERR_ILL_OBJ)
        end)
    end)

    runTest("insert makes the object the first child, keeping the old chain behind it", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.insert(state, 5, 1)
            assertEqual(children(state, 1), "5,2,3,4")
            assertEqual(ZObject.parent(state, 5), 1)
        end)
    end)

    runTest("insert moves an object out of its old parent", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.insert(state, 3, 6)
            assertEqual(children(state, 1), "2,4")
            assertEqual(children(state, 6), "3")
            assertEqual(ZObject.parent(state, 3), 6)
        end)
    end)

    runTest("insert into the same parent reorders correctly (dest's child is read after unlinking)", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            ZObject.insert(state, 2, 1)  -- already the first child
            assertEqual(children(state, 1), "2,3,4", "first child stays first")
            ZObject.insert(state, 3, 1)
            assertEqual(children(state, 1), "3,2,4", "a later child moves to the front")
        end)
    end)

    runTest("insert validates both objects before changing anything", function()
        local state = freshState()
        TestFramework.withTestTree(state, function()
            assertRuntimeError(function()
                ZObject.insert(state, 2, 0xFFFF)
            end, ERR_ILL_OBJ)
            assertEqual(children(state, 1), "2,3,4", "object 2 must not have been unlinked")
            assertEqual(ZObject.parent(state, 2), 1)
        end)
    end)

    ------------------------------------------------------------------
    -- Property lookup (Phase 4.4.6a)
    ------------------------------------------------------------------

    runTest("propertyMask is six bits from V4 on", function()
        local state = freshState()
        assertTrue(state.header.version >= 4, "assumes V4+ property encoding; Adventureland is V5")
        assertEqual(ZObject.propertyMask(state), 0x3F)
    end)

    runTest("findProperty returns the property itself, or the next lower one", function()
        local state = freshState()
        TestFramework.withPropertyTable(state, 5, TestFramework.sampleProperties, function(first)
            local function find(id: number): (number, number)
                return ZObject.findProperty(state, 5, id)
            end
            local addr, sizeByte = find(20)
            assertEqual(addr, first, "id 20")
            assertEqual(sizeByte, 0x54, "id 20 size byte")
            addr, sizeByte = find(15)
            assertEqual(addr, first + 3, "id 15")
            addr, sizeByte = find(10)
            assertEqual(addr, first + 5, "id 10")
            assertEqual(sizeByte, 0x8A, "id 10 size byte")
            addr = find(3)
            assertEqual(addr, first + 11, "id 3")

            addr = find(12)
            assertEqual(addr, first + 5, "id 12 is absent: the next lower is 10")
            addr = find(7)
            assertEqual(addr, first + 11, "id 7 is absent: the next lower is 3")
            addr = find(25)
            assertEqual(addr, first, "id 25 is above the first property")

            addr, sizeByte = find(2)
            assertEqual(addr, first + 14, "below every property lands on the terminator")
            assertEqual(sizeByte, 0, "terminator size byte")
            addr = find(0)
            assertEqual(addr, first + 14, "id 0 matches the terminator")
        end)
    end)

    runTest("dataLength decodes one-byte and two-byte size fields", function()
        local state = freshState()
        TestFramework.withPropertyTable(state, 5, TestFramework.sampleProperties, function(first)
            assertEqual(ZObject.dataLength(state, first + 1), 2, "id 20")
            assertEqual(ZObject.dataLength(state, first + 4), 1, "id 15")
            assertEqual(ZObject.dataLength(state, first + 7), 4, "id 10, two-byte form")
            assertEqual(ZObject.dataLength(state, first + 12), 2, "id 3")
        end)
        TestFramework.withPropertyTable(state, 5, { 0x89, 0x80 }, function(first)
            assertEqual(ZObject.dataLength(state, first + 2), 64, "two-byte form with size field 0 means 64")
        end)
    end)

    runTest("every real property's decoded length agrees with nextProperty", function()
        local state = freshState()
        local mask = ZObject.propertyMask(state)
        for obj = 1, TestFramework.objectCount(state) do
            local prop = ZObject.firstProperty(state, obj)
            local steps = 0
            while state.memory:readU8(prop) ~= 0 do
                local sizeByte = state.memory:readU8(prop)
                local id = bit32.band(sizeByte, mask)

                local found, foundByte = ZObject.findProperty(state, obj, id)
                assertEqual(found, prop, "object " .. obj .. " property " .. id .. " is found at its own address")
                assertEqual(foundByte, sizeByte, "object " .. obj .. " property " .. id .. " size byte")

                local headerLength = if state.header.version >= 4 and bit32.band(sizeByte, 0x80) ~= 0 then 2 else 1
                local data = prop + headerLength
                assertEqual(ZObject.nextProperty(state, prop), data + ZObject.dataLength(state, data),
                    "object " .. obj .. " property " .. id .. " stride")

                prop = ZObject.nextProperty(state, prop)
                steps += 1
                assertTrue(steps <= mask, "object " .. obj .. ": property list did not terminate")
            end
        end
    end)

    TestFramework.printSummary("ZObject tests")
end

CoroutineMgr:create_task(runAllTests)

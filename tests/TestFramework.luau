---------------------------------------------------------------------
-- Shared test framework for the Lua-Frotz test scripts.
--
-- A small pcall-based runner with pass/fail tracking, assertion helpers
-- matching the ZState runtime-error contract (a table thrown via
-- error() with a `code` field, not a plain string), and the ZMemory/
-- ZState fixture setup every test file needs. Bundled together rather
-- than split into a generic-assertions module plus a VM-specific
-- fixture module, since every consumer is a Lua-Frotz test and needs
-- both -- splitting would just be two requires instead of one for no
-- real separation of concerns.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZObject = require("../VM/ZObject.luau")

local TestFramework = {}

local results = { pass = 0, fail = 0, failures = {} }

-- Runs fn under pcall, recording pass/fail. On failure, extracts a
-- readable message whether the error was a plain string or a ZState
-- runtime-error table ({code, pc, message}).
function TestFramework.run(name: string, fn: () -> ())
    print(`Free Memory: {ll.GetFreeMemory()} bytes`)
    local ok, err = pcall(fn)
    if ok then
        print("PASS " .. name)
        results.pass += 1
    else
        results.fail += 1
        local detail = typeof(err) == "table" and (err.message or lljson.encode(err)) or tostring(err)
        table.insert(results.failures, name .. ": " .. detail)
        print("FAIL " .. name .. ": " .. detail)
    end
end

function TestFramework.assertEqual(actual: any, expected: any, message: string?)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message or "assertEqual", tostring(expected), tostring(actual)))
    end
end

function TestFramework.assertTrue(condition: boolean, message: string?)
    if not condition then
        error(message or "expected condition to be true")
    end
end

-- Calls fn and asserts it raises a ZState runtime error with the given code.
function TestFramework.assertRuntimeError(fn: () -> (), expectedCode: number, message: string?)
    local ok, err = pcall(fn)
    local prefix = message or "assertRuntimeError"
    if ok then
        error(prefix .. ": expected error code " .. tostring(expectedCode) .. ", but no error was raised")
    end
    if typeof(err) ~= "table" or err.code == nil then
        error(prefix .. ": expected a ZState runtime error table, got " .. tostring(err))
    end
    if err.code ~= expectedCode then
        error(prefix .. ": expected error code " .. tostring(expectedCode) .. ", got " .. tostring(err.code))
    end
end

-- Prints the accumulated pass/fail summary. Call once, at the end of a
-- test script's run.
function TestFramework.printSummary(label: string)
    print(string.format("%s: %d passed, %d failed", label, results.pass, results.fail))
    if results.fail > 0 then
        print("Failures:")
        for _, failure in ipairs(results.failures) do
            print("  " .. failure)
        end
    end
end

-- Loads a ZMemory instance from the given notecard, wrapped in pcall so
-- a load failure prints once and the caller can bail out early rather
-- than crashing every test on the same root cause. Returns nil on
-- failure.
--
-- `options.ramFlatLimit` overrides the size up to which dynamic memory
-- stays in one flat buffer; 0 pages it out to LinksetData, which frees
-- script memory for the test scripts that are tight on it.
function TestFramework.loadMemory(notecardName: string, options: { ramFlatLimit: number? }?): ZMemory.ZMemory?
    local ok, result = pcall(function()
        local memory = ZMemory.new()
        if options and options.ramFlatLimit then
            memory.ramFlatLimit = options.ramFlatLimit
        end
        memory:initialize(notecardName)
        return memory
    end)
    if not ok then
        print("FATAL: failed to initialize ZMemory: " .. tostring(result))
        return nil
    end
    return result
end

-- Builds a fresh ZState sharing the given (already-loaded) ZMemory
-- instance, with a fresh header table so per-instance header mutations
-- (writeHeaderFlags, restartHeader) in one test can't leak into another.
function TestFramework.freshState(memory: ZMemory.ZMemory): ZState.ZState
    local header = memory:readHeader()
    return ZState.new(memory, header)
end

-- Frotz stores no object count, but the object entries end where the
-- first property table begins, which gives one by convention.
function TestFramework.objectCount(state: ZState.ZState): number
    local entrySize = ZObject.address(state, 2) - ZObject.address(state, 1)
    return math.floor((ZObject.nameAddress(state, 1) - ZObject.address(state, 1)) / entrySize)
end

-- Runs fn with objects 1-6 rewired into a known shape, then restores
-- their original links even if fn fails:
--   1 has children 2, 3, 4 in that order; 5 and 6 are detached.
function TestFramework.withTestTree(state: ZState.ZState, fn: () -> ())
    local saved = {}
    for obj = 1, 6 do
        saved[obj] = { ZObject.parent(state, obj), ZObject.sibling(state, obj), ZObject.child(state, obj) }
    end

    local function link(obj: number, parent: number, sibling: number, child: number)
        ZObject.setParent(state, obj, parent)
        ZObject.setSibling(state, obj, sibling)
        ZObject.setChild(state, obj, child)
    end
    link(1, 0, 0, 2)
    link(2, 1, 3, 0)
    link(3, 1, 4, 0)
    link(4, 1, 0, 0)
    link(5, 0, 0, 0)
    link(6, 0, 0, 0)

    local ok, err = pcall(fn)
    for obj = 1, 6 do
        link(obj, saved[obj][1], saved[obj][2], saved[obj][3])
    end
    if not ok then
        error(err, 0)
    end
end

local SCRATCH_SIZE = 64

-- Base of a small scratch region carved from the top of dynamic memory,
-- 8-byte aligned so packed addresses divide evenly in any version.
function TestFramework.scratchBase(state: ZState.ZState): number
    local base = state.header.staticMemoryBase - SCRATCH_SIZE
    return base - (base % 8)
end

-- Writes bytes at an explicit address, asserting each write succeeds.
function TestFramework.writeBytesAt(state: ZState.ZState, address: number, bytes: {number}): number
    for i, value in ipairs(bytes) do
        assert(state.memory:writeU8(address + i - 1, value))
    end
    return address
end

-- A property list in the V4+ encoding, for withPropertyTable. Offsets are
-- from the first property's size byte; data addresses are noted.
TestFramework.sampleProperties = {
    0x54, 0x12, 0x34,          -- +0:  id 20, size 2            (data at +1)
    0x0F, 0x77,                -- +3:  id 15, size 1            (data at +4)
    0x8A, 0x84, 1, 2, 3, 4,    -- +5:  id 10, two-byte form, size 4 (data at +7)
    0x43, 0xAB, 0xCD,          -- +11: id 3,  size 2            (data at +12)
}

-- Points an object's property table at scratch RAM holding an empty short
-- name, then `props`, then a 0 terminator, and calls fn with the address
-- of the first property. The original pointer is restored even if fn
-- fails. Like withTestTree, it mutates dynamic memory.
function TestFramework.withPropertyTable(state: ZState.ZState, obj: number, props: {number}, fn: (number) -> ())
    -- The upper half of scratch, clear of the opcode harness's bytecode,
    -- which is written at scratchBase.
    local base = TestFramework.scratchBase(state) + SCRATCH_SIZE / 2
    assert(#props + 2 <= SCRATCH_SIZE / 2, "property table does not fit in scratch RAM")

    local pointerAddr = ZObject.address(state, obj) + (if state.header.version <= 3 then 7 else 12)
    local saved = state.memory:readU16(pointerAddr)

    TestFramework.writeBytesAt(state, base, { 0 })
    TestFramework.writeBytesAt(state, base + 1, props)
    TestFramework.writeBytesAt(state, base + 1 + #props, { 0 })
    assert(state.memory:writeU16(pointerAddr, base))

    local ok, err = pcall(fn, base + 1)
    assert(state.memory:writeU16(pointerAddr, saved))
    if not ok then
        error(err, 0)
    end
end

return TestFramework

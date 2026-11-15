---------------------------------------------------------------------
-- Tests for paged dynamic memory (RAM backed by LinksetData).
--
-- Adventureland's dynamic memory is small, so the paged instances are
-- forced by setting ramFlatLimit to 0 and shrinking the resident set to 3
-- pages. A default (flat) instance acts as the reference: every write is
-- mirrored to both and the two must always read back identically.
--
-- Requires the "ZMachine ROM" cards in the same object as the Memory
-- Manager. Uses LinksetData keys prefixed "zramtest"; they are deleted at
-- the end.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

--local NOTECARD_NAME = "ZMachine ROM"
local NOTECARD_NAME = "zdungeon"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

local flat: ZMemory.ZMemory
local paged: ZMemory.ZMemory
local other: ZMemory.ZMemory

local function loadPaged(prefix: string, resident: number): ZMemory.ZMemory
    local memory = ZMemory.new()
    memory.ramFlatLimit = 0
    memory.ramMaxResident = resident
    memory.ramKeyPrefix = prefix
    memory:initialize(NOTECARD_NAME)
    return memory
end

local function firstMismatch(a: ZMemory.ZMemory, b: ZMemory.ZMemory): number?
    for address = 0, a.staticMemoryBase - 1 do
        if a:readU8(address) ~= b:readU8(address) then
            return address
        end
    end
    return nil
end

local function runAllTests()
    local ok, err = pcall(function()
        flat = ZMemory.new()
        flat.ramFlatLimit = 65536  -- the reference must stay flat for any story
        flat:initialize(NOTECARD_NAME)
        paged = loadPaged("zramtest", 3)
        other = loadPaged("zramtestB", 2)
    end)
    if not ok then
        print("FATAL: setup failed: " .. tostring(err))
        return
    end

    runTest("small dynamic memory stays flat and never touches LinksetData", function()
        assertEqual(flat.ramPaged, false, "default instance is flat")
        assertEqual(flat.ramFaults, 0, "no faults")
        assertEqual(paged.ramPaged, true, "forced instance is paged")
        assertEqual(paged.ramPageCount, math.ceil(flat.staticMemoryBase / 256), "page count")
    end)

    runTest("freshly seeded paged RAM matches the flat reference byte for byte", function()
        assertEqual(firstMismatch(flat, paged), nil, "first mismatching address")
        assertTrue(paged.ramFaults > 0, "reading everything with 3 resident pages must fault")
    end)

    runTest("random writes mirrored to both stay identical (eviction + write-back)", function()
        local seed = 12345
        local size = flat.staticMemoryBase
        paged.ramWritebacks = 0
        for _ = 1, 2000 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            local address = seed % size
            local value = bit32.rshift(seed, 8) % 256
            assertTrue(flat:writeU8(address, value), "flat write")
            assertTrue(paged:writeU8(address, value), "paged write")
        end
        assertEqual(firstMismatch(flat, paged), nil, "first mismatching address")
        assertTrue(paged.ramWritebacks > 0, "dirty pages must have been written back")
    end)

    runTest("16-bit writes straddling a page boundary", function()
        for _, address in { 255, 511, 1023 } do
            assertTrue(flat:writeU16(address, 0xBEEF), "flat write")
            assertTrue(paged:writeU16(address, 0xBEEF), "paged write")
            assertEqual(paged:readU16(address), 0xBEEF, "paged read at " .. address)
            assertEqual(paged:readU8(address), 0xBE, "high byte at " .. address)
            assertEqual(paged:readU8(address + 1), 0xEF, "low byte at " .. address)
        end
        assertEqual(firstMismatch(flat, paged), nil, "first mismatching address")
    end)

    runTest("static memory is still read-only and out-of-range still errors", function()
        local base = paged.staticMemoryBase
        assertEqual(paged:writeU8(base, 1), false, "write at the static boundary")
        assertEqual(paged:writeU16(base - 1, 1), false, "word straddling the boundary")
        assertEqual(pcall(paged.readU8, paged, paged.storySize), false, "read past the story")
    end)

    runTest("flush writes dirty pages to LinksetData", function()
        paged:writeU8(300, 0x5A)
        paged:flush()
        assertEqual(next(paged.ramDirty), nil, "no dirty pages after flush")
        local encoded = ll.LinksetDataRead("zramtest_1")
        local page = llbase64.decode(encoded, true)
        assertEqual(buffer.readu8(page, 300 - 256), 0x5A, "stored byte")
    end)

    runTest("a second paged instance with another prefix is isolated", function()
        local before = other:readU8(10)
        paged:writeU8(10, bit32.bxor(before, 0xFF))
        paged:flush()
        assertEqual(other:readU8(10), before, "other instance unchanged")
        paged:writeU8(10, before)
    end)

    runTest("seedRam restores the pristine story image (restart)", function()
        local size = paged.staticMemoryBase
        for address = 0, size - 1, 7 do
            paged:writeU8(address, 0xAA)
        end
        paged:seedRam()
        for address = 0, size - 1 do
            if paged:readU8(address) ~= paged:readOriginalU8(address) then
                assertTrue(false, "RAM differs from the story image at " .. address)
            end
        end
        assertEqual(next(paged.ramDirty), nil, "no dirty pages after reseed")
    end)

    runTest("invalidateRam discards cached pages without writing them back; flat RAM ignores it", function()
        local address = 100
        local stored = paged:readU8(address)
        paged:flush()
        local writebacks = paged.ramWritebacks
        paged:writeU8(address, bit32.bxor(stored, 0xFF))
        paged:invalidateRam()
        assertEqual(paged.ramWritebacks, writebacks, "nothing was written back")
        assertEqual(next(paged.ramDirty), nil, "no dirty pages remain")
        local faults = paged.ramFaults
        assertEqual(paged:readU8(address), stored, "the stored value is read back")
        assertEqual(paged.ramFaults, faults + 1, "the page was reloaded")

        flat:invalidateRam()
        assertEqual(flat.ramPaged, false, "still flat")
    end)

    runTest("attach reads another instance's RAM through LinksetData, in both directions", function()
        local address = 300
        paged:writeU8(address, 0x5C)
        paged:flush()

        local second = ZMemory.new()
        second:attach({
            pageSize = paged.pageSize,
            storySize = paged.storySize,
            staticBase = paged.staticMemoryBase,
            ramPrefix = paged.ramKeyPrefix,
        })
        assertEqual(second.ramPaged, true)
        assertEqual(second.ramPageCount, paged.ramPageCount)
        assertEqual(second:readU8(address), 0x5C, "the first instance's write is visible")

        second:writeU8(address, 0xA3)
        second:flush()
        paged:invalidateRam()
        assertEqual(paged:readU8(address), 0xA3, "the second instance's write is visible after invalidate")

        local boundary = paged.staticMemoryBase
        assertEqual(second:readU8(boundary), paged:readU8(boundary), "ROM pages come from the Memory Manager")
        assertEqual(second:readHeader().version, paged:readHeader().version, "the header reads through RAM")
        assertTrue(ll.LinksetDataRead(paged.ramKeyPrefix .. "_0") ~= "", "attach leaves the first instance's pages alone")
    end)

    runTest("releaseRam deletes the instance's LinksetData keys", function()
        local pages = paged.ramPageCount
        paged:releaseRam()
        assertEqual(paged.ramPaged, false, "no longer paged")
        for i = 0, pages - 1 do
            assertEqual(ll.LinksetDataRead("zramtest_" .. i), "", "key for page " .. i)
        end
    end)

    other:releaseRam()
    TestFramework.printSummary("RAM paging tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

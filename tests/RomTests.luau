---------------------------------------------------------------------
-- Test harness for ROM paging across split notecards.
--
-- Adventureland is 77 pages, stored on two cards ("ZMachine ROM.1" holds
-- pages 1-64, "ZMachine ROM.2" pages 65-77). These tests read the whole
-- story back through the Memory Manager and ZMemory and check it against
-- the checksum in the story's own header, plus a few bytes taken from the
-- original file on either side of the card boundary.
--
-- Requires the numbered cards to be in the same object as the Memory
-- Manager. Reads only; the story's memory is left unchanged.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local CoroutineMgr, _, yield_frame = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

local PAGE_SIZE = 762
local PAGES_PER_CARD = 64

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

    runTest("the story checksum matches when every page, on both cards, is read back", function()
        local state = freshState()
        local header = state.header
        assertEqual(memory.pageSize, PAGE_SIZE, "page size from the card header")

        local pages = math.ceil(header.storySize / PAGE_SIZE)
        assertTrue(pages > PAGES_PER_CARD, "the story should span more than one card (" .. pages .. " pages)")

        local missesBefore = memory.romCacheMisses
        local sum = 0
        for address = 0x40, header.storySize - 1 do
            sum += memory:readOriginalU8(address)
            if address % 8192 == 0 then
                yield_frame()
            end
        end
        assertEqual(bit32.band(sum, 0xFFFF), header.checksum, "sum of bytes 0x40 to the end of the story")

        -- A sequential scan faults each page in exactly once.
        assertEqual(memory.romCacheMisses - missesBefore, pages, "page faults for one sequential scan")
    end)

    runTest("bytes either side of the card boundary and near the end match the story file", function()
        local state = freshState()
        local boundary = PAGES_PER_CARD * PAGE_SIZE  -- first byte on card 2
        local expected = {
            [boundary - 1] = 0,        -- last byte of page 64, card 1
            [boundary] = 0,            -- first byte of page 65, card 2
            [67 * PAGE_SIZE + 100] = 20,  -- inside page 68, the page that first failed
            [76 * PAGE_SIZE] = 18,        -- first byte of page 77
            [state.header.storySize - 1] = 37,  -- last byte of the story
        }
        for address, value in expected do
            assertEqual(memory:readOriginalU8(address), value, "byte at " .. address)
        end
    end)

    TestFramework.printSummary("ROM paging tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

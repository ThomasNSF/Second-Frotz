---------------------------------------------------------------------
-- Memory manager for the Z-Machine VM.
--
-- Loads ROM metadata and pages from the ZMachine ROM notecard(s),
-- maintains a bounded page cache, and serves VM requests through the
-- shared link-message protocol. Notecard reads are asynchronous and
-- coordinated through CoroutineMgr.
--
-- A story may be split across numbered cards "<name>.1", "<name>.2", ...
-- because a notecard holds at most 65,536 bytes. A single unnumbered
-- card "<name>" is still accepted. See docs/MEMORY_MANAGER.md.
---------------------------------------------------------------------

local NOTECARD_NAME = "ZMachine ROM"
local ROM_MAGIC = "ZROM1"
local ROM_VERSION = 1
-- Pages kept in memory, 762 bytes each. A hit costs one link-message round
-- trip; a miss also costs a notecard read, which is far slower. This
-- script has the room (about 99 KB free with 10 pages), so the cache is
-- large; the VM script cannot afford one.
local CACHE_SIZE = 60

-- Prints the free memory at start-up and on every page cache miss, to see
-- whether this script's memory creeps or spikes. Turn off for normal use.
local DEBUG = true

local MemAPI = require("MemoryAPI.luau")

local CoroutineMgr, await_event = table.unpack(require("coromgr.luau"))

type RomHeader = {
    magic: string,
    version: number,
    pageSize: number,
    pageCount: number,
    checksum: string?,
    part: number,          -- which card this header came from (1 for a single card)
    parts: number,         -- how many cards the story is split across
    pagesPerCard: number,  -- pages on every card but possibly the last
}

type PageCacheEntry = {
    index: number,
    buffer: buffer
}

local ROM_HEADER: RomHeader? = nil
local SPLIT_CARDS = false  -- true when the story lives on "<name>.1", "<name>.2", ...
local pageCache: { PageCacheEntry } = {}

-- Parses the pipe-delimited ROM metadata stored on a notecard's first line:
--   ZROM1|version|pageSize|pageCount|checksum[|part|parts|pagesPerCard]
-- The last three fields are optional; without them the card is a complete
-- single-card story.
local function parseRomHeader(rawHeader: string): RomHeader?
    local parts = string.split(rawHeader, "|")
    if #parts < 4 then
        return nil
    end

    if parts[1] ~= ROM_MAGIC then
        return nil
    end

    local pageSize = tonumber(parts[3])
    local pageCount = tonumber(parts[4])
    if pageSize == nil or pageCount == nil or pageSize <= 0 or pageCount <= 0 then
        return nil
    end

    local part, partCount, pagesPerCard = 1, 1, pageCount
    if parts[6] ~= nil then
        part = tonumber(parts[6]) :: any
        partCount = tonumber(parts[7]) :: any
        pagesPerCard = tonumber(parts[8]) :: any
        if part == nil or partCount == nil or pagesPerCard == nil
            or part < 1 or partCount < 1 or part > partCount or pagesPerCard < 1
        then
            return nil
        end
    end

    return {
        magic = parts[1],
        version = tonumber(parts[2]) or ROM_VERSION,
        pageSize = pageSize,
        pageCount = pageCount,
        checksum = parts[5],
        part = part,
        parts = partCount,
        pagesPerCard = pagesPerCard,
    }
end

-- The notecard that holds a part of the story.
local function cardName(part: number): string
    return if SPLIT_CARDS then `{NOTECARD_NAME}.{part}` else NOTECARD_NAME
end

-- Sends a page response to the VM, carrying the request correlation value as the link-message id.
local function sendPageResponse(pageNumber: number, messageId: string | uuid, pageData: (string | buffer)?): ()
    local payload = {
        type = MemAPI.PAGE_RES,
        pageNumber = pageNumber,
        pageSize = ROM_HEADER and ROM_HEADER.pageSize or 0,
        pageB64 = (pageData and llbase64.encode(pageData)) or nil,
    }

    ll.MessageLinked(LINK_SET, MemAPI.MEMORY_CHANNEL, lljson.encode(payload), messageId)
end

-- Forwards a dataserver response to coroutines waiting for its request event.
local function onDataserver(request_id: uuid, data: string)
    -- print("Dataserver response for request " .. tostring(request_id) ..
    --     ": " .. tostring(data))
    CoroutineMgr:handle_event(`ds{request_id}`, "dataserver", data)
end

-- Registered once for the life of the script, not around each read: reads
-- from two scripts can overlap, and a handler added and removed per read
-- could be removed while another read still waits for it.
LLEvents:on("dataserver", onDataserver)

-- Reads one card's line count and parsed header line through the
-- asynchronous notecard API. Prints the reason and returns nil on failure.
local function readCardHeader(name: string): (RomHeader?, number)
    local event_id: uuid = ll.GetNumberOfNotecardLines(name)
    local event: any, response: string = await_event(`ds{event_id}`, 30)
    if event ~= "dataserver" then
        print(`Timeout waiting for the line count of notecard "{name}"`)
        return nil, 0
    end

    local lineCount = tonumber(response)
    if lineCount == nil or lineCount <= 0 then
        print(`Invalid line count for notecard "{name}": {response}`)
        return nil, 0
    end

    -- The line-count request has just loaded the card, so a synchronous
    -- read of its first line succeeds.
    local headerLine = ll.GetNotecardLineSync(name, 1)
    if headerLine == NAK or headerLine == EOF then
        print(`Failed to read the header line of notecard "{name}"`)
        return nil, 0
    end

    local header = parseRomHeader(headerLine)
    if header == nil then
        print(`Notecard "{name}" has an invalid ROM header`)
        return nil, 0
    end
    return header, lineCount
end

-- How many page lines a given card should hold.
local function pagesInPart(header: RomHeader, part: number): number
    return math.min(header.pagesPerCard, header.pageCount - (part - 1) * header.pagesPerCard)
end

-- Locates the story's card(s), reads and parses the ROM header, and checks
-- that every card is present, belongs to the same story, and is long
-- enough. The last check catches a card cut short by the 64 KB notecard
-- limit at load time rather than on the first read of a high page.
local function readNotecardHeader(notecardName: string): RomHeader?
    NOTECARD_NAME = notecardName
    SPLIT_CARDS = ll.GetInventoryType(`{notecardName}.1`) == INVENTORY_NOTECARD

    local header, lineCount = readCardHeader(cardName(1))
    if header == nil then
        return nil
    end
    if not SPLIT_CARDS and header.parts ~= 1 then
        print(`Notecard "{notecardName}" is part of a split story, but "{notecardName}.1" was not found`)
        return nil
    end

    for part = 1, header.parts do
        local partHeader, partLines = header, lineCount
        if part > 1 then
            local other, otherLines = readCardHeader(cardName(part))
            if other == nil then
                return nil
            end
            if other.part ~= part or other.parts ~= header.parts
                or other.pageSize ~= header.pageSize or other.pageCount ~= header.pageCount
                or other.pagesPerCard ~= header.pagesPerCard or other.checksum ~= header.checksum
            then
                print(`Notecard "{cardName(part)}" does not belong to the same story as "{cardName(1)}"`)
                return nil
            end
            partHeader, partLines = other, otherLines
        end

        local expected = 1 + pagesInPart(partHeader, part)
        if partLines < expected then
            print(`Notecard "{cardName(part)}" has {partLines} lines but needs {expected}; it may be over the 64 KB notecard limit`)
            return nil
        end
    end

    return header
end

-- Reads one Base64-encoded ROM page and decodes it into a buffer. Page N
-- of a story split into cards of `pagesPerCard` pages is line
-- ((N - 1) mod pagesPerCard) + 2 of card ((N - 1) // pagesPerCard) + 1;
-- line 1 of every card is its header.
local function readNotecardPage(pageNumber: number): buffer?
    local header = ROM_HEADER
    if header == nil or typeof(pageNumber) ~= "number" or pageNumber < 1 or pageNumber > header.pageCount then
        print("Page request out of range: " .. tostring(pageNumber))
        return nil
    end

    local part = (pageNumber - 1) // header.pagesPerCard + 1
    local line = (pageNumber - 1) % header.pagesPerCard + 2

    local event_id: uuid = ll.GetNotecardLine(cardName(part), line)
    local event: string, response: string = await_event(`ds{event_id}`, 30)
    if event ~= "dataserver" then
        print("Timeout waiting for dataserver response for notecard page " .. tostring(pageNumber))
        return nil
    end

    if response == EOF then
        print("Failed to read notecard page " .. tostring(pageNumber) .. ": " .. tostring(response))
        return nil
    end

    return llbase64.decode(response, true)
end

-- Finds a page in the cache and promotes a hit to the most-recently-used position.
local function findCachedPage(pageNumber: number): buffer?
    for i = 1, #pageCache do
        local entry: PageCacheEntry = pageCache[i]
        if entry.index == pageNumber then
            local cachedEntry = table.remove(pageCache, i)
            table.insert(pageCache, 1, cachedEntry)
            return cachedEntry.buffer
        end
    end
    return nil
end

-- Adds or replaces a cached page and evicts the least-recently-used entry when full.
local function addCachedPage(pageNumber: number, pageData: buffer): ()
    for i = 1, #pageCache do
        local entry: PageCacheEntry = pageCache[i]
        if entry.index == pageNumber then
            entry.buffer = pageData
            return
        end
    end

    if #pageCache >= CACHE_SIZE then
        table.remove(pageCache, #pageCache)
    end

    table.insert(pageCache, 1, { index = pageNumber, buffer = pageData })
end

-- Serves a page from the cache or reads it from the ROM notecard on a cache miss.
local function requestPage(pageNumber: number, messageId: string | uuid): ()
    if not ROM_HEADER then
        print("ROM header not loaded, cannot request page " .. tostring(pageNumber))
        return
    end

    local cachedPage: buffer? = findCachedPage(pageNumber)
    if cachedPage ~= nil then
        sendPageResponse(pageNumber, messageId, cachedPage)
        return
    end

    if DEBUG then
        print(`Memory Manager: page {pageNumber} miss, free {ll.GetFreeMemory()}`)
    end
    local pageData: buffer? = readNotecardPage(pageNumber)
    if pageData == nil then
        print("Failed to read notecard page " .. tostring(pageNumber))
        sendPageResponse(pageNumber, messageId, nil)
    else
        addCachedPage(pageNumber, pageData)
        sendPageResponse(pageNumber, messageId, pageData)
    end

end

-- Sends ROM header metadata in response to a load or header request.
local function sendHeaderResponse(header: RomHeader?, fromLoadCard: boolean, messageId: string | uuid): ()
    local payload = {
        type = fromLoadCard and MemAPI.LOAD_CARD_RES or MemAPI.HEADER_RES,
        loaded = header ~= nil,
        name = header and NOTECARD_NAME or nil,
        magic = header and header.magic or nil,
        version = header and header.version or nil,
        pageSize = header and header.pageSize or nil,
        pageCount = header and header.pageCount or nil,
        checksum = header and header.checksum or nil,
    }

    ll.MessageLinked(LINK_SET, MemAPI.MEMORY_CHANNEL, lljson.encode(payload), messageId)
end

-- Resets the loaded ROM state and clears all cached pages.
local function init(): ()
    ll.LinksetDataReset()
    pageCache = {}
    ROM_HEADER = nil
    SPLIT_CARDS = false
end

-----------------------------------------------------------

-- Dispatches memory-manager requests received from other linked scripts.
local function onLinkMessage(sender: number, channel: number, message: string, id: string | uuid): ()
    if channel ~= MemAPI.MEMORY_CHANNEL then
        return
    end

    local ok, payload = pcall( lljson.decode, message )

    if not ok or typeof(payload) ~= "table" then
        return
    end

    if payload.type == MemAPI.PAGE_REQ then
        CoroutineMgr:create_task(function()
            requestPage(payload.pageNumber, id)
        end)
    elseif payload.type == MemAPI.LOAD_CARD then
        init()
        local name = payload.name
        NOTECARD_NAME = name
        CoroutineMgr:create_task(function()
            local header = readNotecardHeader(name)
            if not header then
                -- print("Failed to read notecard header")
            end

            ROM_HEADER = header
            sendHeaderResponse(header, true, id)
            -- print("ROM loaded: " .. tostring(header.pageCount) .. " pages, page size " .. tostring(header.pageSize))
        end)
    elseif payload.type == MemAPI.HEADER_REQ then
        sendHeaderResponse(ROM_HEADER, false, id)
    end
end

LLEvents:on("link_message", onLinkMessage)

init()

if DEBUG then
    print(`Memory Manager ready. Free memory: {ll.GetFreeMemory()}`)
end

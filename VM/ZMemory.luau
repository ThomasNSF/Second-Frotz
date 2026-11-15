---------------------------------------------------------------------
-- Z-machine virtual memory for the Luau interpreter.
--
-- This module owns VM-side RAM, ROM page residency, and address
-- classification. Memory reads are coroutine-compatible: a future ROM
-- cache miss may suspend the caller while a page is requested.
---------------------------------------------------------------------

local CoroMgr, await_event = table.unpack(require("coromgr.luau"))
local MemAPI = require("MemoryAPI.luau")
-- Pages are ~762 bytes each, so every slot is a real cost against the
-- script's memory budget. Tune against romCacheMisses during play.
local ROM_CACHE_SIZE = 4

-- Dynamic memory (RAM). Stories whose dynamic memory is at most
-- RAM_FLAT_LIMIT bytes keep it in one flat buffer. Larger ones are paged:
-- the authoritative copy lives in LinksetData (Base64, one key per
-- RAM_PAGE_SIZE-byte page) and only RAM_RESIDENT_PAGES pages are held in
-- script memory. LinksetData calls are synchronous, so RAM access never
-- yields, unlike ROM page faults.
local RAM_PAGE_SIZE = 256
local RAM_PAGE_SHIFT = 8
local RAM_PAGE_MASK = 255
local RAM_RESIDENT_PAGES = 16
local RAM_FLAT_LIMIT = 16384
-- LinksetDataWrite statuses that mean the value is stored: LINKSETDATA_OK,
-- and LINKSETDATA_NOUPDATE (the stored value was already identical).
local LSD_OK = 0
local LSD_NOUPDATE = 5

-- Message types that represent a reply to a request this script sent.
-- Only these should ever wake a coroutine waiting on `mapi<id>`; request
-- types (LOAD_CARD, PAGE_REQ, HEADER_REQ) must be ignored here even if a
-- link_message broadcast loops back to this same script.
local RESPONSE_MESSAGE_TYPES: {[string]: boolean} = {
    [MemAPI.LOAD_CARD_RES] = true,
    [MemAPI.PAGE_RES] = true,
    [MemAPI.HEADER_RES] = true,
}

export type ZMemoryConfig = {
    pageSize: number,
    staticMemoryBase: number,
    storySize: number,
    ram: buffer?,
    romCache: {[number]: buffer}?,
}

export type PageLocation = {
    pageNumber: number,
    -- Zero-based offset for Luau buffer access.
    byteOffset: number,
}

export type StoryHeader = {
    version: number,
    flags1: number,
    release: number,
    highMemoryBase: number,
    initialPC: number,
    dictionary: number,
    objects: number,
    globals: number,
    staticMemoryBase: number,
    flags2: number,
    serial: string,
    abbreviations: number,
    storySize: number,
    checksum: number,
    interpreterNumber: number,
    interpreterVersion: number,
    screenHeightLines: number,
    screenWidthCharacters: number,
    screenWidthUnits: number,
    screenHeightUnits: number,
    fontWidthUnits: number,
    fontHeightUnits: number,
    routinesOffset: number,
    stringsOffset: number,
    defaultBackground: number,
    defaultForeground: number,
    terminatingCharacters: number,
    standardRevision: number,
    alphabetTable: number,
    headerExtensionTable: number,
}

-- What a second script needs to read the same story as the first: the
-- layout from the loaded story, and the key prefix its RAM pages are
-- stored under in LinksetData.
export type AttachConfig = {
    pageSize: number,
    storySize: number,
    staticBase: number,
    ramPrefix: string,
}

export type ZMemory = {
    pageSize: number,
    staticMemoryBase: number,
    storySize: number,
    ram: buffer,
    romCacheMaxSize: number,
    romCache: {[number]: buffer},
    romCacheOrder: { number },
    romCacheMisses: number,
    -- Dynamic memory. `ram` is the flat buffer when not paged.
    ramPaged: boolean,
    ramFlatLimit: number,
    ramMaxResident: number,
    ramKeyPrefix: string,
    ramPageCount: number,
    ramPages: {[number]: buffer},
    ramOrder: { number },
    ramDirty: {[number]: boolean},
    ramLastPage: number,
    ramLastBuf: buffer?,
    ramFaults: number,
    ramWritebacks: number,
    initialize: (ZMemory, string) -> (),
    seedRam: (ZMemory) -> (),
    invalidateRam: (ZMemory) -> (),
    attach: (ZMemory, AttachConfig) -> (),
    releaseRam: (ZMemory) -> (),
    flush: (ZMemory) -> (),
    getRomPageLocation: (ZMemory, number) -> PageLocation,
    readU8: (ZMemory, number) -> number,
    readOriginalU8: (ZMemory, number) -> number,
    readU16: (ZMemory, number) -> number,
    readS16: (ZMemory, number) -> number,
    readHeader: (ZMemory) -> StoryHeader,
    writeU8: (ZMemory, number, number) -> boolean,
    writeU16: (ZMemory, number, number) -> boolean,
}

-- Validates a Z-machine story address.
local function assertAddress(memory: ZMemory, address: number): ()
    assert(address >= 0 and address < memory.storySize, "Z-machine address out of range")
end

-- Determines whether a story address belongs to mutable dynamic memory.
local function isRamAddress(memory: ZMemory, address: number): boolean
    return address < memory.staticMemoryBase
end

--------------------------------
local function zmRomCacheRemoveOrderEntry(memory: ZMemory, pageNumber: number): ()
    local index = table.find(memory.romCacheOrder, pageNumber)
    if index then
        table.remove(memory.romCacheOrder, index)
    end
end

local function zmRomCacheSetMRU(memory: ZMemory, pageNumber: number): ()
    if memory.romCache[pageNumber] == nil then
        return
    end

    if memory.romCacheOrder[1] == pageNumber then
        return
    end

    zmRomCacheRemoveOrderEntry(memory, pageNumber)
    table.insert(memory.romCacheOrder, 1, pageNumber)
end

local function zmRomCacheAdd(memory: ZMemory, pageNumber: number, pageData: buffer): ()
    assert(buffer.len(pageData) == memory.pageSize, "ROM page has an invalid size")

    if memory.romCache[pageNumber] ~= nil then
        memory.romCache[pageNumber] = pageData
        zmRomCacheSetMRU(memory, pageNumber)
        return
    end

    if #memory.romCacheOrder >= memory.romCacheMaxSize then
        local lruPageNumber = table.remove(memory.romCacheOrder)
        if lruPageNumber then
            memory.romCache[lruPageNumber] = nil
        end
    end

    memory.romCache[pageNumber] = pageData
    zmRomCacheRemoveOrderEntry(memory, pageNumber)
    table.insert(memory.romCacheOrder, 1, pageNumber)
end

-- Fetches one byte via the ROM path (cache or PAGE_REQ), regardless of
-- whether the address currently falls in dynamic memory. Factored out of
-- readU8 so readOriginalU8 can reuse it without the RAM/ROM check.
local function fetchRomByte(memory: ZMemory, address: number): number
    local pageNumber = math.floor(address / memory.pageSize) + 1
    local byteOffset = address % memory.pageSize

    if memory.romCache[pageNumber] then
        zmRomCacheSetMRU(memory, pageNumber)
        return buffer.readu8(memory.romCache[pageNumber], byteOffset)
    end

    memory.romCacheMisses += 1
    local event: uuid = ll.GenerateKey()
    ll.MessageLinked(LINK_SET, MemAPI.MEMORY_CHANNEL, lljson.encode({
        type = MemAPI.PAGE_REQ,
        pageNumber = pageNumber,
    }), event)

    local ok: boolean, result = await_event(`mapi{event}`, 30)
    if (not ok) or (typeof(result) ~= "string") then
        error(`Failed to load ROM page {pageNumber}: `
            .. (if ok then "reply was not text" else `no reply ({tostring(result)})`))
    end
    ok, result = pcall(lljson.decode, result)
    if not ok or typeof(result) ~= "table" then
        error(`Failed to load ROM page {pageNumber}: reply did not decode ({tostring(result)})`)
    end
    if result.type ~= MemAPI.PAGE_RES then
        error("Unexpected ROM page response for page " .. tostring(pageNumber))
    end
    if result.pageNumber ~= pageNumber then
        error("ROM page number mismatch: expected " .. tostring(pageNumber))
    end
    if result.pageSize ~= memory.pageSize then
        error("ROM page size mismatch: expected " .. tostring(memory.pageSize))
    end
    if typeof(result.pageB64) == "string" then
        local pageData = llbase64.decode(result.pageB64, true)
        assert(typeof(pageData) == "buffer", "Base64 decoder did not return a buffer")
        if buffer.len(pageData) ~= memory.pageSize then
            error("ROM page payload has an invalid size")
        end
        zmRomCacheAdd(memory, pageNumber, pageData)
        return buffer.readu8(pageData, byteOffset)
    end

    error("ROM page loading failed for page " .. tostring(pageNumber))
end

---------------------------------------------------------------------
-- Paged dynamic memory
---------------------------------------------------------------------

local function ramKey(memory: ZMemory, pageIndex: number): string
    return `{memory.ramKeyPrefix}_{pageIndex}`
end

-- Stores one page image (Base64) in LinksetData.
local function lsdStore(memory: ZMemory, pageIndex: number, page: buffer): ()
    local status = ll.LinksetDataWrite(ramKey(memory, pageIndex), llbase64.encode(page))
    if status ~= LSD_OK and status ~= LSD_NOUPDATE then
        error(`LinksetData write failed for RAM page {pageIndex} of "{memory.ramKeyPrefix}" `
            .. `(status {status}, {ll.LinksetDataAvailable()} bytes available, `
            .. `{ll.LinksetDataCountKeys()} keys)`)
    end
end

local function ramWriteBack(memory: ZMemory, pageIndex: number): ()
    lsdStore(memory, pageIndex, memory.ramPages[pageIndex])
    memory.ramDirty[pageIndex] = nil
    memory.ramWritebacks += 1
end

local function ramEvictOne(memory: ZMemory): ()
    local victim = table.remove(memory.ramOrder) :: number
    if memory.ramDirty[victim] then
        ramWriteBack(memory, victim)
    end
    memory.ramPages[victim] = nil
    if memory.ramLastPage == victim then
        memory.ramLastPage = -1
        memory.ramLastBuf = nil
    end
end

-- Returns the resident buffer for a zero-based RAM page, loading it from
-- LinksetData (and evicting the least recently used page) if needed.
local function ramPage(memory: ZMemory, pageIndex: number): buffer
    if pageIndex == memory.ramLastPage then
        return memory.ramLastBuf :: buffer
    end

    local page = memory.ramPages[pageIndex]
    if page then
        local order = memory.ramOrder
        if order[1] ~= pageIndex then
            table.remove(order, table.find(order, pageIndex))
            table.insert(order, 1, pageIndex)
        end
    else
        memory.ramFaults += 1
        if #memory.ramOrder >= memory.ramMaxResident then
            ramEvictOne(memory)
        end
        local encoded = ll.LinksetDataRead(ramKey(memory, pageIndex))
        if encoded == "" then
            error(`RAM page {pageIndex} is missing from LinksetData`)
        end
        page = llbase64.decode(encoded, true)
        if typeof(page) ~= "buffer" or buffer.len(page) ~= RAM_PAGE_SIZE then
            error(`RAM page {pageIndex} is corrupt`)
        end
        memory.ramPages[pageIndex] = page
        table.insert(memory.ramOrder, 1, pageIndex)
    end

    memory.ramLastPage = pageIndex
    memory.ramLastBuf = page
    return page :: buffer
end

local function ramReadByte(memory: ZMemory, address: number): number
    if not memory.ramPaged then
        return buffer.readu8(memory.ram, address)
    end
    return buffer.readu8(
        ramPage(memory, bit32.rshift(address, RAM_PAGE_SHIFT)),
        bit32.band(address, RAM_PAGE_MASK))
end

local function ramWriteByte(memory: ZMemory, address: number, value: number): ()
    if not memory.ramPaged then
        buffer.writeu8(memory.ram, address, value)
        return
    end
    local pageIndex = bit32.rshift(address, RAM_PAGE_SHIFT)
    buffer.writeu8(ramPage(memory, pageIndex), bit32.band(address, RAM_PAGE_MASK), value)
    memory.ramDirty[pageIndex] = true
end

local ZMemory = {}
ZMemory.__index = ZMemory


-- Creates an empty VM memory instance.
-- The runtime configuration is assigned later when a story is loaded.
function ZMemory.new(): ZMemory
    local memory = {
        pageSize = 0,
        staticMemoryBase = 0,
        storySize = 0,
        ram = buffer.create(0),
        romCache = {},
        romCacheOrder = {},
        romCacheMaxSize = ROM_CACHE_SIZE,
        romCacheMisses = 0,
        ramPaged = false,
        -- Tunable before initialize (tests shrink them to force paging).
        ramFlatLimit = RAM_FLAT_LIMIT,
        ramMaxResident = RAM_RESIDENT_PAGES,
        ramKeyPrefix = "",
        ramPageCount = 0,
        ramPages = {},
        ramOrder = {},
        ramDirty = {},
        ramLastPage = -1,
        ramLastBuf = nil,
        ramFaults = 0,
        ramWritebacks = 0,
    }

    return setmetatable(memory, ZMemory) :: any
end

-- Drops paged RAM: deletes this instance's LinksetData keys and resident
-- pages. The keys are found by prefix rather than from our own page count,
-- so pages left behind by an earlier story, a larger story, or a previous
-- run of the script (the default prefix is stable across resets) are
-- removed too.
function ZMemory:releaseRam(): ()
    if self.ramKeyPrefix == "" then
        self.ramKeyPrefix = "zr" .. string.sub(tostring(ll.GetKey()), 1, 8)
    end
    local stale = ll.LinksetDataFindKeys(`^{self.ramKeyPrefix}_[0-9]+$`, 1, 0)
    for _, key in stale do
        ll.LinksetDataDelete(key)
    end
    self.ramPaged = false
    self.ramPageCount = 0
    self.ramPages = {}
    self.ramOrder = {}
    self.ramDirty = {}
    self.ramLastPage = -1
    self.ramLastBuf = nil
    self.ram = buffer.create(0)
end

-- (Re)builds dynamic memory from the pristine story image. Used by
-- initialize and by restart. Reads go through the ROM path, so this
-- yields on page faults. Requires staticMemoryBase to be set.
function ZMemory:seedRam(): ()
    self:releaseRam()
    local size = self.staticMemoryBase
    assert(self.ramMaxResident >= 2, "ramMaxResident must be at least 2")

    if size <= self.ramFlatLimit then
        local ram = buffer.create(size)
        for address = 0, size - 1 do
            buffer.writeu8(ram, address, fetchRomByte(self, address))
        end
        self.ram = ram
        return
    end

    local pageCount = math.ceil(size / RAM_PAGE_SIZE)
    local image = buffer.create(RAM_PAGE_SIZE)
    for pageIndex = 0, pageCount - 1 do
        buffer.fill(image, 0, 0, RAM_PAGE_SIZE)
        local base = pageIndex * RAM_PAGE_SIZE
        for i = 0, math.min(RAM_PAGE_SIZE, size - base) - 1 do
            buffer.writeu8(image, i, fetchRomByte(self, base + i))
        end
        lsdStore(self, pageIndex, image)
    end
    self.ramPaged = true
    self.ramPageCount = pageCount
end

-- Writes every modified resident page back to LinksetData.
function ZMemory:flush(): ()
    if not self.ramPaged then
        return
    end
    for pageIndex in self.ramDirty do
        ramWriteBack(self, pageIndex)
    end
end

-- Discards the resident RAM pages without writing them back, so the next
-- access reloads from LinksetData. For a script that shares the story's
-- RAM with another: call it after the other script may have written, and
-- (since dirty pages are lost) only after flush() if this script has
-- writes of its own to keep. Does nothing for flat RAM, which cannot be
-- shared.
function ZMemory:invalidateRam(): ()
    if not self.ramPaged then
        return
    end
    self.ramPages = {}
    self.ramOrder = {}
    self.ramDirty = {}
    self.ramLastPage = -1
    self.ramLastBuf = nil
end

-- Makes this instance read a story that another instance (in another
-- script) has already loaded and seeded: ROM pages come from the Memory
-- Manager as usual, and RAM comes from the other script's LinksetData
-- pages. Does not load a notecard, seed RAM or delete any keys, and the
-- LinksetData pages stay owned by the instance that created them.
-- Writes through this instance are written back by flush().
function ZMemory:attach(config: AttachConfig): ()
    self.pageSize = config.pageSize
    self.storySize = config.storySize
    self.staticMemoryBase = config.staticBase
    self.ramKeyPrefix = config.ramPrefix
    self.romCache = {}
    self.romCacheOrder = {}
    self.romCacheMisses = 0
    self.ram = buffer.create(0)
    self.ramPaged = true
    self.ramPageCount = math.ceil(config.staticBase / RAM_PAGE_SIZE)
    self:invalidateRam()
    self.ramFaults = 0
    self.ramWritebacks = 0
end

function ZMemory:initialize(notecardName: string): ()
    local requestId: uuid = ll.GenerateKey()

    ll.MessageLinked(LINK_SET, MemAPI.MEMORY_CHANNEL, lljson.encode({
        type = MemAPI.LOAD_CARD,
        name = notecardName,
    }), requestId)

    local ok, message = await_event(`mapi{requestId}`, 30)
    if not ok or typeof(message) ~= "string" then
        error("LOAD_CARD request failed")
    end

    local decodedOk, payload = pcall(lljson.decode, message)
    if not decodedOk or typeof(payload) ~= "table" then
        error("LOAD_CARD response is not valid JSON")
    end

    if payload.type ~= MemAPI.LOAD_CARD_RES then
        error("Unexpected LOAD_CARD response type")
    end
    if payload.loaded ~= true then
        error("Notecard did not load successfully")
    end
    if payload.magic ~= "ZROM1" then
        error("LOAD_CARD response has invalid ROM magic")
    end
    if typeof(payload.pageSize) ~= "number" or payload.pageSize <= 0 then
        error("LOAD_CARD response has invalid page size")
    end
    if typeof(payload.pageCount) ~= "number" or payload.pageCount <= 0 then
        error("LOAD_CARD response has invalid page count")
    end

    self.pageSize = payload.pageSize
    self.storySize = payload.pageSize * payload.pageCount
    self.staticMemoryBase = 0
    self.romCache = {}
    self.romCacheOrder = {}

    local header = self:readHeader()

    if header.staticMemoryBase < 0
        or header.staticMemoryBase > header.storySize
    then
        error("Story header has an invalid static-memory boundary")
    end

    if header.storySize <= 0 or header.storySize > self.storySize then
        error("Story header has an invalid story size")
    end

    self.storySize = header.storySize
    self.staticMemoryBase = header.staticMemoryBase
    self:seedRam()

    -- Seeding read dynamic memory through the ROM path and cached its
    -- last pages. Dynamic addresses are served from RAM from here on, so
    -- those pages are dead weight (up to ROM_CACHE_SIZE * pageSize bytes,
    -- a large share of a very tight budget). Static memory pages are
    -- fetched again on demand.
    self.romCache = {}
    self.romCacheOrder = {}
    self.romCacheMisses = 0  -- count only misses that happen during play
    self.ramFaults = 0
    self.ramWritebacks = 0
end

-- Converts a Z-machine address to a one-based page and zero-based buffer offset.
function ZMemory:getRomPageLocation(address: number): PageLocation
    assertAddress(self, address)
    assert(not isRamAddress(self, address), "address is not in ROM")

    return {
        pageNumber = math.floor(address / self.pageSize) + 1,
        byteOffset = address % self.pageSize,
    }
end

-- Reads one byte from RAM or a resident ROM page.
--
-- The function must be called from a VM coroutine. ROM cache-miss
-- handling will be added with the PAGE_REQ/PAGE_RES transport layer.
function ZMemory:readU8(address: number): number
    assertAddress(self, address)

    if isRamAddress(self, address) then
        return ramReadByte(self, address)
    end

    return fetchRomByte(self, address)
end

-- Reads a byte from the story's ROM image, ignoring the RAM/ROM boundary.
-- Used to recover a dynamic-memory byte's pristine original value (e.g.
-- for restart or a future @restore), since `ram` may have been mutated
-- by gameplay but the ROM page data never changes.
function ZMemory:readOriginalU8(address: number): number
    assertAddress(self, address)
    return fetchRomByte(self, address)
end

-- Reads a big-endian unsigned 16-bit value.
function ZMemory:readU16(address: number): number
    local high = self:readU8(address)
    local low = self:readU8(address + 1)
    return (high * 256) + low
end

-- Reads a big-endian signed 16-bit value.
function ZMemory:readS16(address: number): number
    local value = self:readU16(address)
    if value >= 0x8000 then
        return value - 0x10000
    end
    return value
end

-- Reads the standard Z-machine header from the story image.
function ZMemory:readHeader(): StoryHeader
    local version = self:readU8(0)
    assert(version >= 1 and version <= 8, "unsupported Z-machine version")
    -- V6 needs pictures, pixel-addressed windows, a mouse and menus, none of
    -- which this port provides; refuse it at load rather than failing later
    -- on an unimplemented opcode.
    assert(version ~= 6, "unsupported Z-machine version: V6 stories are not supported")

    local storyLengthScale = 8
    if version <= 3 then
        storyLengthScale = 2
    elseif version <= 5 then
        storyLengthScale = 4
    end

    local serialBytes = {}
    for i = 1, 6 do
        serialBytes[i] = string.char(self:readU8(17 + i))
    end

    return {
        version = version,
        flags1 = self:readU8(1),
        release = self:readU16(2),
        highMemoryBase = self:readU16(4),
        initialPC = self:readU16(6),
        dictionary = self:readU16(8),
        objects = self:readU16(10),
        globals = self:readU16(12),
        staticMemoryBase = self:readU16(14),
        flags2 = self:readU16(16),
        serial = table.concat(serialBytes),
        abbreviations = self:readU16(24),
        storySize = self:readU16(26) * storyLengthScale,
        checksum = self:readU16(28),
        interpreterNumber = self:readU8(30),
        interpreterVersion = self:readU8(31),
        screenHeightLines = self:readU8(32),
        screenWidthCharacters = self:readU8(33),
        screenWidthUnits = self:readU16(34),
        screenHeightUnits = self:readU16(36),
        fontWidthUnits = self:readU8(38),
        fontHeightUnits = self:readU8(39),
        routinesOffset = self:readU16(40),
        stringsOffset = self:readU16(42),
        defaultBackground = self:readU8(44),
        defaultForeground = self:readU8(45),
        terminatingCharacters = self:readU16(46),
        standardRevision = self:readU16(50),
        alphabetTable = self:readU16(52),
        headerExtensionTable = self:readU16(54),
    }
end

-- Writes one byte to dynamic memory and rejects static-memory writes.
function ZMemory:writeU8(address: number, value: number): boolean
    assertAddress(self, address)
    assert(value >= 0 and value <= 0xFF, "byte value out of range")

    if not isRamAddress(self, address) then
        return false
    end

    ramWriteByte(self, address, value)
    return true
end

-- Writes a big-endian unsigned 16-bit value without partial ROM writes.
function ZMemory:writeU16(address: number, value: number): boolean
    assertAddress(self, address)
    assert(address + 1 < self.storySize, "16-bit address out of range")
    assert(value >= 0 and value <= 0xFFFF, "word value out of range")

    if not isRamAddress(self, address) or not isRamAddress(self, address + 1) then
        return false
    end

    ramWriteByte(self, address, math.floor(value / 256))
    ramWriteByte(self, address + 1, value % 256)
    return true
end

--------------------------------------------------------------------------

local function onLinkMessageHandler( _sender: number, channel: number, message: string, id: uuid | string )
    if channel ~= MemAPI.MEMORY_CHANNEL then
        return
    end

    -- Several scripts in the prim share this channel, and every reply
    -- reaches all of them. Check for a waiter before decoding: a ROM page
    -- reply is about 1 KB of JSON, and decoding another script's replies
    -- would waste memory and time.
    local eventName = `mapi{id}`
    if not CoroMgr:is_waiting(eventName) then
        return
    end

    local ok, payload = pcall(lljson.decode, message)

    if not ok or typeof(payload) ~= "table" then
        CoroMgr:handle_event(eventName, false, message)
        return
    end

    -- Only wake a waiter for genuine responses. LOAD_CARD/PAGE_REQ that
    -- this same script just broadcast on MEMORY_CHANNEL can loop back via
    -- link_message and carry the exact same `id` as the pending request;
    -- without this check that echo would be mistaken for the reply.
    if not RESPONSE_MESSAGE_TYPES[payload.type] then
        return
    end

    CoroMgr:handle_event(eventName, true, message)
end

LLEvents:on("link_message", onLinkMessageHandler)

return ZMemory

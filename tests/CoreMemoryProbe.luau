---------------------------------------------------------------------
-- T5: the script-memory footprint of the core VM script after the text
-- and input code moved to the Text Service. Requires exactly the modules
-- the core carries (no ZText, ZOutput, ZInput, ZHost, ChatHost,
-- TextService), loads the story with paged RAM as production will, and
-- prints the free memory after each step, then after stress that makes
-- garbage: reading every ROM page, every RAM page, and a run of
-- instructions.
--
-- SLua has no collectgarbage, so readings include uncollected garbage;
-- run it twice and use the second run. The Text Service script does not
-- have to be present: nothing here talks to it.
---------------------------------------------------------------------

local last = ll.GetFreeMemory()
local lowest = last

local function report(label: string)
    local free = ll.GetFreeMemory()
    lowest = math.min(lowest, free)
    print(`{label}: {last - free} bytes (free now {free})`)
    last = free
end

print(`Memory limit: {ll.GetMemoryLimit()}, used: {ll.GetUsedMemory()}, free: {last}`)

local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
report("coromgr")
local TextAPI = require("../VM/TextAPI.luau")
report("TextAPI")
local ZMemory = require("../VM/ZMemory.luau")
report("ZMemory")
local ZState = require("../VM/ZState.luau")
report("ZState")
local ZObject = require("../VM/ZObject.luau")
report("ZObject")
local ZOpcodes = require("../VM/ZOpcodes.luau")
report("ZOpcodes")
local ZTextClient = require("../VM/ZTextClient.luau")
report("ZTextClient")
local ZTextLink = require("../VM/ZTextLink.luau")
report("ZTextLink")

-- Keep the unused requires from being flagged.
local _ = TextAPI.TEXT_CHANNEL, ZObject

CoroutineMgr:create_task(function()
    local memory = ZMemory.new()
    memory.ramFlatLimit = 0
    memory:initialize("ZMachine ROM")
    report("story loaded (paged RAM)")

    local state = ZState.new(memory, memory:readHeader())
    report("ZState.new (stack buffer + tables)")
    ZOpcodes.applyVersionPatches(state.header.version)

    local link = ZTextLink.new()
    local client = ZTextClient.new(link, memory)
    ZOpcodes.attachText(state, client)
    report("text client attached")

    local startingFree = ll.GetFreeMemory()
    print(`CORE STARTING FREE MEMORY: {startingFree} bytes`)

    -- A few instructions through the real dispatcher (nop, 0xB4).
    local base = memory.staticMemoryBase - 64
    for i = 0, 2 do
        memory:writeU8(base + i, 0xB4)
    end
    state.pc = base
    for _ = 1, 3 do
        local before = ll.GetFreeMemory()
        ZOpcodes.step(state)
        print(`step: {before - ll.GetFreeMemory()} bytes`)
    end

    -- Every ROM page through the cache: each fetch decodes about 1 KB of
    -- JSON and Base64, and the 16-page cache evicts as it goes.
    local pages = math.ceil(memory.storySize / memory.pageSize)
    for page = 0, pages - 1 do
        local address = page * memory.pageSize
        if address >= memory.staticMemoryBase then
            memory:readU8(address)
        end
        lowest = math.min(lowest, ll.GetFreeMemory())
    end
    report(`read every ROM page ({memory.romCacheMisses} misses)`)

    -- Every RAM page, written and read, to run the LRU and the write-back.
    for address = 0, memory.staticMemoryBase - 1, memory.pageSize do
        memory:writeU8(address + 200, memory:readU8(address + 200))
        lowest = math.min(lowest, ll.GetFreeMemory())
    end
    memory:flush()
    report(`touched every RAM page ({memory.ramFaults} faults, {memory.ramWritebacks} write-backs)`)

    local ok, peak = pcall(function()
        return ll.GetSPMaxMemory()
    end)
    print(`Lowest free memory seen: {lowest} bytes`)
    if ok then
        print(`Peak used memory (script): {peak} bytes`)
    end
    print(`Core starting free {startingFree}; headroom after stress {lowest}`)
end)

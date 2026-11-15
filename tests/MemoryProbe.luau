---------------------------------------------------------------------
-- Measures the script-memory footprint of the core VM modules.
--
-- Requires each module in dependency order and prints the free-memory
-- delta it caused, then the cost of loading the story and creating a
-- ZState. SLua has no collectgarbage, so readings include any uncollected
-- garbage; run it twice and use the second run.
---------------------------------------------------------------------

local last = ll.GetFreeMemory()

local function report(label: string)
    local free = ll.GetFreeMemory()
    print(`{label}: {last - free} bytes (free now {free})`)
    last = free
end

print(`Memory limit: {ll.GetMemoryLimit()}, used: {ll.GetUsedMemory()}, free: {last}`)

local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
report("coromgr")
local ZMemory = require("../VM/ZMemory.luau")
report("ZMemory")
local ZState = require("../VM/ZState.luau")
report("ZState")
local ZObject = require("../VM/ZObject.luau")
report("ZObject")
local ZOpcodes = require("../VM/ZOpcodes.luau")
report("ZOpcodes")

CoroutineMgr:create_task(function()
    local memory = ZMemory.new()
    memory:initialize("ZMachine ROM")
    report("story loaded (RAM buffer + overhead)")

    local state = ZState.new(memory, memory:readHeader())
    report("ZState.new (stack buffer + tables)")

    -- A few instructions through the real dispatcher, as a sanity check
    -- that steady-state execution doesn't allocate much. nop (0xB4) is
    -- harmless at any frame depth.
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
    report("done")
end)

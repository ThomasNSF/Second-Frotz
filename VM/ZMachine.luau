---------------------------------------------------------------------
-- The core VM script: loads the story, runs the Z-machine, and talks to
-- the Text Service script (everything the player sees and types) over
-- link messages.
--
-- Put in one prim, with:
--   * Memory Manager   (serves the story's ROM pages from notecards)
--   * Text Service     (VM/Text Service.luau)
--   * this script
--   * the story's numbered notecards
-- Reset the Memory Manager, then the Text Service, then this script last.
-- To play again after the story ends, reset this script.
--
-- Dynamic memory is always paged out to LinksetData, because the Text
-- Service reads and writes the same story RAM. See docs/TEXT_SERVICE.md.
---------------------------------------------------------------------

local ZMemory = require("ZMemory.luau")
local ZState = require("ZState.luau")
local ZOpcodes = require("ZOpcodes.luau")
local ZRunner = require("ZRunner.luau")
local ZTextClient = require("ZTextClient.luau")
local ZTextLink = require("ZTextLink.luau")
local CoroMgr = table.unpack(require("coromgr.luau"))

-- The name of the story's notecards (the ROM image the Memory Manager serves).
local STORY_NAME = "ZMachine ROM"

-- Prints a line for every message to the Text Service and a memory reading
-- every 250 instructions. Turn off once the game runs reliably.
local DEBUG = true

local function start(): ()
    local memory = ZMemory.new()
    memory.ramFlatLimit = 0
    memory:initialize(STORY_NAME)

    local header = memory:readHeader()
    local state = ZState.new(memory, header)
    ZOpcodes.applyVersionPatches(header.version)

    local link = ZTextLink.new({ log = if DEBUG then print else nil })
    link:start()
    local client = ZTextClient.new(link, memory)
    ZOpcodes.attachText(state, client)
    state.directCall = function(routine: number): number
        return ZRunner.directCall(state, routine)
    end

    local reply = client:config(ZTextLink.configFor(memory))
    if reply.ok ~= true then
        error(`the Text Service refused or did not answer ({tostring(reply.message)}). `
            .. "Is the Text Service script in this prim and running?")
    end
    state.screenRows = reply.screenRows
    state.screenCols = reply.screenCols

    if DEBUG then
        state.trace = function(s: any)
            print(`trace: instr {s.instructionCount} pc {string.format("%x", s.instructionStart)} free {ll.GetFreeMemory()}`)
        end
    end

    print(`ZMachine: version {header.version} story running. Free memory: {ll.GetFreeMemory()} bytes`)
    state:restart()
    local how, err = ZRunner.play(state, client)
    if how == "fatal" then
        local bytes = {}
        for i = 0, 7 do
            table.insert(bytes, string.format("%02x", memory:readU8(err.start + i)))
        end
        print(`ZMachine: failing instruction at {string.format("%x", err.start)}: {table.concat(bytes, " ")}`)
        local peakOk, peak = pcall(function()
            return ll.GetSPMaxMemory()
        end)
        print(`ZMachine: memory used {ll.GetUsedMemory()}, peak {if peakOk then peak else "?"}`)
    end

    print(`ZMachine: story {if how == "quit" then "ended" else "stopped with an error"}. `
        .. `Instructions: {state.instructionCount}, ROM cache misses: {memory.romCacheMisses}, `
        .. `RAM faults: {memory.ramFaults}, write-backs: {memory.ramWritebacks}, `
        .. `free memory: {ll.GetFreeMemory()} bytes`)
end

CoroMgr:create_task(function()
    local ok, err = pcall(start)
    if not ok then
        ll.OwnerSay(`ZMachine failed to start: {if typeof(err) == "table" then tostring(err.message) else tostring(err)}`)
    end
end)

print("ZMachine Starting.")
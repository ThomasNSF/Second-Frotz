---------------------------------------------------------------------
-- Two-script smoke test of the Text Service link. This script plays the
-- core: it loads the story, configures the Text Service over link
-- messages, prints through it and reads the owner's chat.
--
-- Put in ONE prim: this script, "Text Service" (VM/Text Service.luau), the
-- Memory Manager and the "ZMachine ROM" cards. Run LinksetDataReset first,
-- reset the Text Service, then reset this script and follow its prompts in
-- local chat (channel 0). The Text Service says the story's text; this
-- script prints PASS/FAIL lines.
--
-- Mutates dynamic memory (a 64-byte scratch region at its top).
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZTextLink = require("../VM/ZTextLink.luau")
local ZTextClient = require("../VM/ZTextClient.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

local function readString(memory: any, addr: number, length: number): string
    local chars = {}
    for i = 1, length do
        chars[i] = string.char(memory:readU8(addr + i - 1))
    end
    return table.concat(chars)
end

-- The line stored in a text buffer: V5+ has a length byte, earlier
-- versions end with a zero byte.
local function storedLine(memory: any, text: number, version: number): string
    if version >= 5 then
        return readString(memory, text + 2, memory:readU8(text + 1))
    end
    local chars = {}
    local addr = text + 1
    while memory:readU8(addr) ~= 0 do
        table.insert(chars, string.char(memory:readU8(addr)))
        addr += 1
    end
    return table.concat(chars)
end

local function runAllTests()
    local memory = TestFramework.loadMemory(NOTECARD_NAME, { ramFlatLimit = 0 })
    if not memory then
        return
    end
    local version = memory:readHeader().version
    local base = memory.staticMemoryBase - 64
    local text = base - (base % 8)
    local parse = text + 44

    local link = ZTextLink.new()
    link:start()
    local failure: any = nil
    local client = ZTextClient.new(link, memory, function(err: any)
        failure = err
        error(`client error: {err.message or err.fault or err.code}`)
    end)

    runTest("config attaches the service to the story and returns the screen size", function()
        local reply = client:config(ZTextLink.configFor(memory))
        assertEqual(reply.ok, true, tostring(reply.message))
        assertEqual(reply.screenCols, 80)
    end)

    runTest("queued output and a ROM string reach the service in order; flush returns", function()
        client:queue({ "t", "Text link smoke test." })
        client:queue({ "nl" })
        client:queue({ "t", "Count: " })
        for n = 1, 3 do
            client:queue({ "n", n })
            client:queue({ "t", " " })
        end
        client:queue({ "nl" })
        client:queue({ "s", 0x3261 * 4 })
        client:queue({ "nl" })
        client:request("flush")
        assertEqual(failure, nil)
    end)

    runTest("check_unicode is answered by the service", function()
        assertEqual(client:request("check_unicode", { c = 0x41 }).value, 3)
        assertEqual(client:request("check_unicode", { c = 0x07 }).value, 0)
    end)

    runTest("a synchronous request takes about one link-message round trip", function()
        local started = os.clock()
        for _ = 1, 10 do
            client:request("get_cursor")
        end
        local average = (os.clock() - started) / 10
        print(`  average request: {math.floor(average * 1000)} ms`)
        assertTrue(average < 1, "slower than a second")
    end)

    runTest("read: the owner's chat line arrives in the story's text buffer", function()
        memory:writeU8(text, 40)
        memory:writeU8(parse, 4)

        client:queue({ "t", ">> Say exactly: open mailbox" })
        client:queue({ "nl" })
        local reply = client:request("read", { text = text, parse = parse })
        assertEqual(reply.status, "line")
        assertEqual(reply.key, 13)
        assertEqual(reply.wroteRam, true)
        assertEqual(storedLine(memory, text, version), "open mailbox")
        client:queue({ "t", "You said: " .. storedLine(memory, text, version) })
        client:queue({ "nl" })
        client:request("flush")
    end)

    runTest("read with a timeout replies 'timeout' when nobody speaks", function()
        client:queue({ "t", ">> Say nothing for 3 seconds." })
        client:queue({ "nl" })
        local reply = client:request("read", { text = text, parse = parse, timeout = 30 })
        assertEqual(reply.status, "timeout")
        local ended = client:request("read_end", { text = text })
        assertEqual(ended.key, 0)
        assertEqual(storedLine(memory, text, version), "")
    end)

    runTest("the core can write a string table entry after a barrier and the service sees it", function()
        -- A Z-string "hi" in the scratch region, printed by the service from RAM
        -- through the `s` entry (the service reads the core's flushed page).
        local addr = text + 20
        local word = (13 * 32 + 14) * 32 + 5 + 0x8000  -- h i pad, end bit
        memory:writeU8(addr, bit32.rshift(word, 8))
        memory:writeU8(addr + 1, bit32.band(word, 0xFF))
        client:queue({ "t", "From RAM: " })
        client:queue({ "s", addr })
        client:queue({ "nl" })
        client:barrier()
        assertEqual(failure, nil)
    end)

    runTest("finish ends the story and the service says so", function()
        client:finish("quit")
    end)

    TestFramework.printSummary("Text link smoke test")
end

ll.LinksetDataReset()
print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

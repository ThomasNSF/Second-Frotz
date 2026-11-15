---------------------------------------------------------------------
-- Tests for TextService: the output entries (`out`), the synchronous
-- requests (`request`), reset and finish, driven by a scripted fake host.
-- These replace the output and input checks that ran through the opcode
-- tables (TextOpcodeTests, IoOpcodeTests) with the same checks against
-- the service itself, with no ZState or ZOpcodes in the script.
--
-- Most tests share the loaded story memory with the service
-- (sharedMemory = true). One test gives the service its own attached
-- ZMemory and checks the flush/invalidate protocol between the two.
--
-- Requires the "ZMachine ROM" cards and the Memory Manager. Dynamic
-- memory is paged out to LinksetData (the shared-RAM scheme) and the
-- 64-byte scratch region at its top holds the buffers. Mutates dynamic
-- memory; do not follow with real interpretation on the same loaded
-- modules.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local TextService = require("../VM/TextService.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

-- The framework's scratch helpers take a ZState; this script has no state,
-- only memory, so it has its own: the last 64 bytes of dynamic memory.
local function scratchBase(m: any): number
    local base = m.staticMemoryBase - 64
    return base - (base % 8)
end

local function writeBytesAt(m: any, address: number, bytes: { number }): number
    for i, value in ipairs(bytes) do
        assert(m:writeU8(address + i - 1, value))
    end
    return address
end

local memory: ZMemory.ZMemory?

-- A host whose answers come from `script`: a list of {text, timedOut}.
local function newHost(script: { { any } }?)
    local host: any = { script = script or {}, index = 0, calls = {}, written = {}, events = {} }
    function host:write(text: string)
        table.insert(self.written, text)
    end
    local function nextAnswer(self: any, kind: string, ...)
        self.index += 1
        table.insert(self.calls, { kind, ... })
        local answer = self.script[self.index]
        assert(answer, "the host was asked for more input than the test scripted")
        return answer[1], answer[2] == true
    end
    function host:readLine(maxLength: number, timeout: number?)
        return nextAnswer(self, "readLine", maxLength, timeout)
    end
    function host:readChar(timeout: number?)
        return nextAnswer(self, "readChar", timeout)
    end
    function host:fatal(err: any)
        table.insert(self.events, { "fatal", err })
    end
    function host:quit()
        table.insert(self.events, { "quit" })
    end
    return host
end

-- A configured service sharing the test's memory, and its host.
local function newService(script: { { any } }?): (any, any)
    assert(memory, "ZMemory not initialized")
    local host = newHost(script)
    local service = TextService.new(host, memory, { sharedMemory = true })
    local reply = service:config()
    assertEqual(reply.ok, true, "config")
    return service, host
end

-- Pushes pending text to the host and returns everything written so far.
local function printed(service: any, host: any): string
    service:request("flush")
    return table.concat(host.written)
end

local function readString(addr: number, length: number): string
    assert(memory)
    local chars = {}
    for i = 1, length do
        chars[i] = string.char(memory:readU8(addr + i - 1))
    end
    return table.concat(chars)
end

-- A Z-string of Z-characters, three to a word, padded with 5s, end bit on
-- the last word.
local function zstringBytes(zchars: { number }): { number }
    local bytes = {}
    for i = 1, #zchars, 3 do
        local word = ((zchars[i] * 32 + (zchars[i + 1] or 5)) * 32 + (zchars[i + 2] or 5))
        if i + 3 > #zchars then
            word += 0x8000
        end
        table.insert(bytes, bit32.rshift(word, 8))
        table.insert(bytes, bit32.band(word, 0xFF))
    end
    return bytes
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME, { ramFlatLimit = 0 })
    if not memory then
        return
    end

    runTest("the service's error codes match ZState.Errors", function()
        assertEqual(TextService.ERR_STR3_NESTING, ZState.Errors.STR3_NESTING)
        assertEqual(TextService.ERR_ILL_WIN, ZState.Errors.ILL_WIN)
        assertEqual(TextService.ERR_ILL_PRINT_ADDR, ZState.Errors.ILL_PRINT_ADDR)
    end)

    runTest("before config, out and request report a fault; config returns the screen size", function()
        assert(memory)
        local host = newHost()
        local service = TextService.new(host, memory, { sharedMemory = true })
        local err = service:out({ { "nl" } })
        assertTrue(err ~= nil and err.fault == true, "out before config")
        local reply = service:request("flush")
        assertTrue(reply.fault ~= nil, "request before config")
        local config = service:config()
        assertEqual(config.ok, true)
        assertEqual(config.screenRows, 24)
        assertEqual(config.screenCols, 80)
    end)

    ------------------------------------------------------------------
    -- Output entries
    ------------------------------------------------------------------

    runTest("s: prints Z-strings out of ROM", function()
        local service, host = newService()
        assertEqual(service:out({ { "s", 0x3261 * 4 }, { "nl" }, { "s", 0x3256 * 4 } }), nil)
        assertEqual(printed(service, host),
            "Please give one of the answers above.\n\"Undo\" failed.  [Not all interpreters provide it.]")
    end)

    runTest("s: prints a Z-string held in dynamic memory", function()
        local service, host = newService()
        local addr = scratchBase(memory) + 32
        writeBytesAt(memory, addr, zstringBytes({ 13, 14 }))  -- "hi"
        service:out({ { "s", addr } })
        assertEqual(printed(service, host), "hi")
    end)

    runTest("z: prints a Z-string the core copied out of dynamic memory; a missing end bit prints nothing extra", function()
        local service, host = newService()
        local hi = (13 * 32 + 14) * 32 + 5 + 0x8000  -- "hi" with the end bit
        service:out({ { "z", { hi } } })
        assertEqual(printed(service, host), "hi")

        local noEnd = (13 * 32 + 14) * 32 + 5  -- "hi", end bit missing
        service:out({ { "z", { noEnd } }, { "t", "!" } })
        assertEqual(printed(service, host), "hihi!")
    end)

    runTest("st: the status line gets the location name decoded from its words", function()
        local service, host = newService()
        local seen: { any } = {}
        function host:statusLine(name, first, second, isTime)
            seen = { name, first, second, isTime }
        end
        local hi = (13 * 32 + 14) * 32 + 5 + 0x8000
        service:out({ { "st", { words = { hi }, first = 7, second = 3, isTime = true } } })
        assertEqual(seen[1], "hi")
        assertEqual(seen[2], 7)
        assertEqual(seen[3], 3)
        assertEqual(seen[4], true)

        service:out({ { "st", { words = {}, first = 1, second = 2, isTime = false } } })
        assertEqual(seen[1], "", "no location")
        assertEqual(printed(service, host), "", "a status line is not printed")
    end)

    runTest("check_unicode: 3 for printable and readable, 1 for printable only, 0 for the forbidden", function()
        local service = newService()
        local cases = {
            { 0x61, 3 }, { 0x20, 3 }, { 0x7E, 3 },
            { 0xA0, 1 },
            { 0xE4, 3 }, { 0xE9, 3 },
            { 0x263A, 1 }, { 0x20AC, 1 },
            { 0x00, 0 }, { 0x0A, 0 }, { 0x1F, 0 }, { 0x7F, 0 }, { 0x9F, 0 },
            { 0xD800, 0 }, { 0xDFFF, 0 }, { 0xFFFE, 0 }, { 0xFFFF, 0 },
        }
        for _, case in cases do
            assertEqual(service:request("check_unicode", { c = case[1] }).value, case[2],
                string.format("check_unicode U+%04X", case[1]))
        end
    end)

    runTest("t, c, u and n entries print literal text, ZSCII, Unicode and numbers; nl ends the chunk", function()
        local service, host = newService()
        service:out({
            { "t", "object#5" }, { "nl" },
            { "c", 155 }, { "c", 65 }, { "u", 0x263A }, { "nl" },
            { "n", -5 }, { "n", 32767 },
        })
        assertEqual(printed(service, host),
            "object#5\n" .. utf8.char(0xE4) .. "A" .. utf8.char(0x263A) .. "\n-532767")
        assertEqual(host.written[1], "object#5\n", "a newline ends the chunk")
    end)

    runTest("c and u entries may carry several codes", function()
        local service, host = newService()
        assertEqual(service:out({ { "c", 72, 105, 33 }, { "u", 0x263A, 7, 0x41 } }), nil)
        assertEqual(printed(service, host), "Hi!" .. utf8.char(0x263A) .. "?A")
    end)

    runTest("u: control codes and invalid code points print as '?'", function()
        local service, host = newService()
        local entries = {}
        for _, c in { 0x0A, 0x0D, 0x1F, 0x7F, 0x9F, 0xD800, 0xDFFF, 0xFFFE, 0xFFFF } do
            table.insert(entries, { "u", c })
        end
        table.insert(entries, { "u", 0xA0 })
        table.insert(entries, { "u", 0x20 })
        service:out(entries)
        assertEqual(printed(service, host), "?????????" .. utf8.char(0xA0) .. " ")
    end)

    runTest("o: stream -1 hides screen text and 1 restores it", function()
        local service, host = newService()
        service:out({ { "c", 65 }, { "o", -1 }, { "c", 66 }, { "o", 1 }, { "c", 67 } })
        assertEqual(printed(service, host), "AC")
    end)

    runTest("w: text printed in the upper window is discarded; erase -1 returns to the lower", function()
        local service, host = newService()
        service:out({ { "c", 65 }, { "w", "set", 1 }, { "c", 66 }, { "w", "set", 0 }, { "c", 67 } })
        assertEqual(printed(service, host), "AC")

        service:out({ { "w", "split", 4 }, { "w", "set", 1 }, { "w", "erase", -1 }, { "c", 68 } })
        assertEqual(service.screen.upperHeight, 0)
        assertEqual(service.screen.window, 0)
        assertEqual(printed(service, host), "ACD")
    end)

    runTest("w: an illegal window is returned as ERR_ILL_WIN and the rest of the batch is skipped", function()
        local service, host = newService()
        local err = service:out({ { "c", 65 }, { "w", "set", 2 }, { "c", 66 } })
        assertEqual(err.code, ZState.Errors.ILL_WIN)
        assertEqual(printed(service, host), "A")
    end)

    runTest("an illegal print address is returned as ERR_ILL_PRINT_ADDR", function()
        local service = newService()
        local err = service:out({ { "s", memory.storySize } })
        assertEqual(err.code, ZState.Errors.ILL_PRINT_ADDR)
    end)

    runTest("an unknown entry is reported as a fault", function()
        local service = newService()
        local err = service:out({ { "zz" } })
        assertTrue(err ~= nil and err.fault == true)
    end)

    runTest("w: a host with capabilities is told instead of the defaults applying", function()
        local service, host = newService()
        local told = {}
        function host:setWindow(w) table.insert(told, "window " .. w) end
        function host:splitWindow(h) table.insert(told, "split " .. h) end
        function host:eraseWindow(w) table.insert(told, "erase " .. w) end
        function host:setCursor(y, x) table.insert(told, `cursor {y},{x}`) end
        function host:setTextStyle(s) table.insert(told, "style " .. s) end
        function host:setColour(f, b) table.insert(told, `colour {f},{b}`) end
        function host:eraseLine(n) table.insert(told, "eraseline " .. n) end

        service:out({
            { "w", "split", 3 }, { "w", "set", 1 }, { "w", "cursor", 2, 4 }, { "w", "style", 2 },
            { "w", "colour", 3, 4 }, { "w", "eraseline", 1 }, { "w", "erase", -1 },
        })
        assertEqual(table.concat(told, "; "),
            "split 3; window 1; cursor 2,4; style 2; colour 3,4; eraseline 1; split 0; window 0; erase -1")

        service:out({ { "w", "set", 1 }, { "c", 69 } })
        assertEqual(printed(service, host), "E", "with setWindow the host decides; nothing is hidden")
    end)

    ------------------------------------------------------------------
    -- Requests
    ------------------------------------------------------------------

    runTest("read: stores a lowercased line, its length and the tokens, and replies with key 13", function()
        local service, host = newService({ { "Take LAMP" } })
        local text, parse = scratchBase(memory), scratchBase(memory) + 24
        writeBytesAt(memory, text, { 14, 0 })
        writeBytesAt(memory, parse, { 2, 0 })
        local reply = service:request("read", { text = text, parse = parse, timeout = 0 })
        assertEqual(reply.status, "line")
        assertEqual(reply.key, 13)
        assertEqual(reply.wroteRam, true, "the buffers were written")
        assertEqual(memory:readU8(text + 1), 9, "length byte")
        assertEqual(readString(text + 2, 9), "take lamp")
        assertEqual(memory:readU8(parse + 1), 2, "two tokens")
        assertEqual(host.calls[1][2], 14, "the maximum length is the buffer capacity")
    end)

    runTest("read: pending text reaches the host before the wait, and entries in `pre` come first", function()
        local service, host = newService({ { "go" } })
        local text = scratchBase(memory)
        writeBytesAt(memory, text, { 14, 0 })
        service:request("read", { text = text, parse = 0 }, { { "t", "West of House" }, { "nl" }, { "t", ">" } })
        assertEqual(table.concat(host.written), "West of House\n>", "the prompt was flushed before reading")
    end)

    runTest("read (V3 layout): the status line goes to the host and the text has a zero terminator", function()
        local service, host = newService({ { "Abc" } })
        service.header.version = 3
        service.input.header.version = 3
        local seen = {}
        function host:statusLine(name, first, second, isTime)
            seen = { name, first, second, isTime }
        end
        local text = scratchBase(memory)
        writeBytesAt(memory, text, { 12, 0, 0, 0, 0, 0 })
        service:request("read", {
            text = text, parse = 0,
            status = { name = "Kitchen", first = 7, second = 3, isTime = false },
        })
        assertEqual(seen[1], "Kitchen")
        assertEqual(seen[2], 7)
        assertEqual(seen[3], 3)
        assertEqual(seen[4], false)
        assertEqual(readString(text + 1, 3), "abc")
        assertEqual(memory:readU8(text + 4), 0, "terminator")
        assertEqual(host.calls[1][2], 11, "the V1-4 maximum is the buffer size less one")
    end)

    runTest("read: a timeout replies 'timeout' and stores nothing; read_end stores an empty buffer", function()
        local service, host = newService({ { "", true } })
        local text, parse = scratchBase(memory), scratchBase(memory) + 24
        writeBytesAt(memory, text, { 14, 9 })
        writeBytesAt(memory, parse, { 2, 0x55 })
        local reply = service:request("read", { text = text, parse = parse, timeout = 50 })
        assertEqual(reply.status, "timeout")
        assertEqual(host.calls[1][3], 50, "the timeout reaches the host")
        assertEqual(memory:readU8(text + 1), 9, "nothing stored on a timeout")

        reply = service:request("read_end", { text = text })
        assertEqual(reply.key, 0)
        assertEqual(memory:readU8(text + 1), 0, "empty text")
        assertEqual(memory:readU8(parse + 1), 0x55, "the parse buffer is untouched")
    end)

    runTest("read_char: replies with the ZSCII code; a newline is 13; a timeout is reported", function()
        local service = newService({ { "x" }, { "\n" }, { utf8.char(0xE9) }, { "", true } })
        assertEqual(service:request("read_char").value, 120)
        assertEqual(service:request("read_char").value, 13)
        assertEqual(service:request("read_char").value, service.text:toZscii(0xE9), "e-acute")
        assertEqual(service:request("read_char", { timeout = 15 }).status, "timeout")
    end)

    runTest("tokenise and encode_text work on story buffers", function()
        local service = newService()
        local text, parse = scratchBase(memory), scratchBase(memory) + 24
        writeBytesAt(memory, text, { 14, 4, string.byte("q"), string.byte("z"), string.byte("x"), string.byte("v") })
        writeBytesAt(memory, parse, { 2, 0 })
        local reply = service:request("tokenise", { text = text, parse = parse })
        assertEqual(reply.wroteRam, true)
        assertEqual(memory:readU8(parse + 1), 1)
        assertEqual(memory:readU16(parse + 2), 0, "unknown word")

        writeBytesAt(memory, text, { 0, 0, 0, 0, string.byte("l"), string.byte("o"), string.byte("o"), string.byte("k") })
        service:request("encode_text", { text = text, length = 4, offset = 4, dest = text + 16 })
        local expected = { 17 * 1024 + 20 * 32 + 20, 16 * 1024 + 5 * 32 + 5, 5 * 1024 + 5 * 32 + 5 + 0x8000 }
        for i = 1, 3 do
            assertEqual(memory:readU16(text + 16 + 2 * (i - 1)), expected[i], "word " .. i)
        end
    end)

    runTest("print_table: rows with a newline between them, skipping bytes between rows", function()
        local service, host = newService()
        local text = scratchBase(memory)
        local bytes = {}
        for _, c in { "A", "B", "C", "x", "y", "D", "E", "F" } do
            table.insert(bytes, string.byte(c))
        end
        writeBytesAt(memory, text, bytes)
        service:request("print_table", { addr = text, width = 3, height = 2, skip = 2 })
        assertEqual(printed(service, host), "ABC\nDEF")
    end)

    runTest("cursor, window height and fonts", function()
        local service = newService()
        service:out({ { "w", "set", 1 }, { "w", "cursor", 3, 5 } })
        local reply = service:request("get_cursor")
        assertEqual(reply.row, 3)
        assertEqual(reply.column, 5)
        service:out({ { "w", "set", 0 }, { "w", "cursor", 9, 9 } })
        reply = service:request("get_cursor")
        assertEqual(reply.row, 1, "the lower window's cursor is 1,1")
        assertEqual(reply.column, 1)

        assertEqual(service:request("set_font", { font = 0 }).value, 1, "font 0 asks for the current font")
        assertEqual(service:request("set_font", { font = 1 }).value, 1)
        assertEqual(service:request("set_font", { font = 3 }).value, 0, "font 3 is not available")
    end)

    runTest("stream 3: text printed meanwhile is written into the table; nesting is limited", function()
        local service, host = newService()
        local table1 = scratchBase(memory) + 40
        assertEqual(service:request("stream", { n = 3, table = table1 }).wroteRam, true)
        local err, wrote = service:out({ { "n", 42 }, { "c", 228 - 73 } })
        assertEqual(err, nil)
        assertEqual(wrote, true, "the batch wrote into the table")
        service:request("stream", { n = -3 })
        assertEqual(memory:readU16(table1), 3, "length word")
        assertEqual(memory:readU8(table1 + 2), 0x34, "'4'")
        assertEqual(memory:readU8(table1 + 3), 0x32, "'2'")
        assertEqual(memory:readU8(table1 + 4), 155, "ZSCII 155 stored for the a-umlaut")
        assertEqual(#host.written, 0, "nothing reached the host while redirected")

        for i = 1, 16 do
            assertEqual(service:request("stream", { n = 3, table = scratchBase(memory) + 2 * (i - 1) }).error, nil)
        end
        assertEqual(service:request("stream", { n = 3, table = scratchBase(memory) + 40 }).error,
            ZState.Errors.STR3_NESTING)
        for _ = 1, 16 do
            service:request("stream", { n = -3 })
        end
    end)

    runTest("an unknown request is a fault", function()
        local service = newService()
        assertTrue(service:request("nope").fault ~= nil)
    end)

    ------------------------------------------------------------------
    -- Reset, finish, and a service with its own memory
    ------------------------------------------------------------------

    runTest("reset returns the screen to its starting state and shows hidden text again", function()
        local service, host = newService()
        service:out({ { "w", "split", 4 }, { "w", "set", 1 } })
        service:reset()
        assertEqual(service.screen.window, 0)
        assertEqual(service.screen.upperHeight, 0)
        service:out({ { "c", 70 } })
        assertEqual(printed(service, host), "F")
    end)

    runTest("finish flushes pending text and tells the host", function()
        local service, host = newService()
        service:out({ { "t", "last words" } })
        service:finish("quit")
        assertEqual(table.concat(host.written), "last words")
        assertEqual(host.events[1][1], "quit")

        service:finish("fatal", { code = 100, message = "boom" })
        assertEqual(host.events[2][1], "fatal")
        assertEqual(host.events[2][2].code, 100)
    end)

    runTest("a service with its own attached memory shares RAM with the core through LinksetData", function()
        assert(memory)
        local core = memory
        local host = newHost({ { "look" } })
        local own = ZMemory.new()
        local service = TextService.new(host, own)  -- not shared: its own cache
        local config = service:config({
            pageSize = core.pageSize,
            storySize = core.storySize,
            staticBase = core.staticMemoryBase,
            ramPrefix = core.ramKeyPrefix,
        })
        assertEqual(config.ok, true)

        -- The core prepares a buffer and publishes it (rule R1)...
        local text = scratchBase(core)
        writeBytesAt(core, text, { 14, 0 })
        core:flush()

        -- ...the service reads a line into it and writes through (R2)...
        local reply = service:request("read", { text = text, parse = 0 })
        assertEqual(reply.wroteRam, true)

        -- ...and the core drops its cache and sees the result (R3).
        core:invalidateRam()
        assertEqual(core:readU8(text + 1), 4, "length")
        assertEqual(readString(text + 2, 4), "look")

        -- Output entries that print from RAM see what the core published.
        local addr = text + 20
        writeBytesAt(core, addr, zstringBytes({ 13, 14 }))
        core:flush()
        service:out({ { "s", addr } })
        service:request("flush")
        assertEqual(table.concat(host.written), "hi")
    end)

    TestFramework.printSummary("Text Service tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

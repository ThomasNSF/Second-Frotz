---------------------------------------------------------------------
-- Test harness for ZOutput (Phase 4.5.1).
--
-- Needs no story: stream 3 writes into a fake byte-addressed RAM, and
-- the sink records the chunks it is given.
---------------------------------------------------------------------

local ZOutput = require("../VM/ZOutput.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

-- Builds an output over a fake RAM. Returns the output, the list of
-- chunks delivered to the screen sink, and the RAM bytes.
local function newOutput(): (ZOutput.ZOutput, {string}, {[number]: number})
    local chunks: {string} = {}
    local bytes: {[number]: number} = {}
    local ram: ZOutput.Ram = {
        readWord = function(addr: number): number
            return (bytes[addr] or 0) * 256 + (bytes[addr + 1] or 0)
        end,
        writeByte = function(addr: number, value: number)
            bytes[addr] = value
        end,
        writeWord = function(addr: number, value: number)
            bytes[addr] = bit32.rshift(value, 8)
            bytes[addr + 1] = bit32.band(value, 0xFF)
        end,
    }
    local out = ZOutput.new(function(text: string)
        table.insert(chunks, text)
    end, ram)
    return out, chunks, bytes
end

local function runAllTests()
    runTest("putString then flush delivers one chunk; an empty flush delivers nothing", function()
        local out, chunks = newOutput()
        out:flush()
        assertEqual(#chunks, 0, "nothing buffered")
        out:putString("hello")
        assertEqual(#chunks, 0, "not delivered before flush")
        out:flush()
        assertEqual(#chunks, 1)
        assertEqual(chunks[1], "hello")
        out:flush()
        assertEqual(#chunks, 1, "flushing twice does not repeat the chunk")
    end)

    runTest("several writes before a flush join into one chunk, in order", function()
        local out, chunks = newOutput()
        out:putString("You ")
        out:putChar(0x61)  -- a
        out:putString("re here.")
        out:flush()
        assertEqual(#chunks, 1)
        assertEqual(chunks[1], "You are here.")
    end)

    runTest("newLine ends the chunk", function()
        local out, chunks = newOutput()
        out:putString("first")
        out:newLine()
        out:putString("second")
        assertEqual(#chunks, 1, "the newline flushed the first line")
        assertEqual(chunks[1], "first\n")
        out:flush()
        assertEqual(chunks[2], "second")
    end)

    runTest("code points above 127 arrive UTF-8 encoded", function()
        local out, chunks = newOutput()
        out:putChar(0xE9)  -- e acute
        out:flush()
        assertEqual(chunks[1], utf8.char(0xE9))
        assertEqual(#chunks[1], 2, "two UTF-8 bytes")
    end)

    runTest("closing the screen stream discards later text but delivers earlier text", function()
        local out, chunks = newOutput()
        out:putString("before")
        out:setScreen(false)
        assertEqual(chunks[1], "before", "text printed while the stream was open is delivered")
        out:putString("hidden")
        out:newLine()
        out:setScreen(true)
        out:putString("after")
        out:flush()
        assertEqual(#chunks, 2)
        assertEqual(chunks[2], "after")
    end)

    runTest("the transcript receives the same chunks, including while the screen is off", function()
        local out, chunks = newOutput()
        local transcript: {string} = {}
        out:setTranscript(function(text: string)
            table.insert(transcript, text)
        end)
        out:putString("one")
        out:newLine()
        out:setScreen(false)
        out:putString("two")
        out:newLine()
        assertEqual(#chunks, 1, "the screen saw only the first line")
        assertEqual(chunks[1], "one\n")
        assertEqual(#transcript, 2)
        assertEqual(transcript[1], "one\n")
        assertEqual(transcript[2], "two\n")
    end)

    runTest("memory stream stores the length and text, newline as 13, and hides output from the sink", function()
        local out, chunks, bytes = newOutput()
        assertTrue(out:openMemory(100), "open")
        out:putString("AB")
        out:putChar(0x43)
        out:newLine()
        assertEqual(#chunks, 0, "nothing reaches the sink while redirected")
        out:closeMemory()
        assertEqual(bytes[100] * 256 + bytes[101], 4, "length word")
        assertEqual(bytes[102], 0x41)
        assertEqual(bytes[103], 0x42)
        assertEqual(bytes[104], 0x43)
        assertEqual(bytes[105], 13, "newline is stored as 13")
        out:putString("back")
        out:flush()
        assertEqual(chunks[1], "back", "normal output resumes after closing")
    end)

    runTest("nested redirects each keep their own table and length", function()
        local out, _, bytes = newOutput()
        assertTrue(out:openMemory(100))
        out:putString("xy")
        assertTrue(out:openMemory(200))
        out:putString("Z")
        out:closeMemory()
        out:putString("w")
        out:closeMemory()
        assertEqual(bytes[100] * 256 + bytes[101], 3, "outer table holds x, y, w")
        assertEqual(bytes[102], 0x78)
        assertEqual(bytes[103], 0x79)
        assertEqual(bytes[104], 0x77)
        assertEqual(bytes[200] * 256 + bytes[201], 1, "inner table holds Z")
        assertEqual(bytes[202], 0x5A)
    end)

    runTest("the 17th open redirect is refused and the first 16 stay open", function()
        local out, _, bytes = newOutput()
        for i = 1, 16 do
            assertTrue(out:openMemory(i * 10), "open " .. i)
        end
        assertEqual(out:openMemory(500), false, "17th open")
        out:putString("q")
        assertEqual(bytes[160] * 256 + bytes[161], 1, "text still goes to the 16th table")
        assertEqual(bytes[500], nil, "the refused table was never touched")
    end)

    runTest("putChar 13 is a newline and putChar 0 prints nothing", function()
        local out, chunks = newOutput()
        out:putString("a")
        out:putChar(13)
        assertEqual(#chunks, 1, "the carriage return ended the chunk")
        assertEqual(chunks[1], "a\n")
        out:putChar(0)
        out:flush()
        assertEqual(#chunks, 1, "code 0 added nothing")
    end)

    runTest("in a memory stream putChar 13 stores 13 and putChar 0 stores nothing", function()
        local out, _, bytes = newOutput()
        assertTrue(out:openMemory(100))
        out:putChar(13)
        out:putChar(0)
        out:putChar(0x41)
        out:closeMemory()
        assertEqual(bytes[100] * 256 + bytes[101], 2, "length")
        assertEqual(bytes[102], 13)
        assertEqual(bytes[103], 0x41)
    end)

    TestFramework.printSummary("ZOutput tests")
end

CoroutineMgr:create_task(runAllTests)

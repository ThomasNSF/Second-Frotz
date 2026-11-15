---------------------------------------------------------------------
-- Tests for ChatText.split and ZHost.validate. Pure logic: needs no
-- story and no ROM cards.
---------------------------------------------------------------------

local ChatText = require("../VM/ChatText.luau")
local ZHost = require("../VM/ZHost.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

local split = ChatText.split

-- Removes the separators a split may drop, so a split can be compared
-- with its input.
local function withoutSeparators(text: string): string
    return (string.gsub(text, "[\n ]", ""))
end

local function checkPieces(pieces: {string}, input: string, maxBytes: number)
    local joined = {}
    for i, piece in pieces do
        assertTrue(#piece > 0, "piece " .. i .. " is empty")
        assertTrue(#piece <= maxBytes, "piece " .. i .. " has " .. #piece .. " bytes")
        assertTrue(utf8.len(piece) ~= nil, "piece " .. i .. " is not valid UTF-8")
        joined[i] = piece
    end
    assertEqual(withoutSeparators(table.concat(joined)), withoutSeparators(input), "no text lost or added")
end

local function runAllTests()
    runTest("split: short text is returned whole; empty text gives no pieces", function()
        local pieces = split("hello world", 20)
        assertEqual(#pieces, 1)
        assertEqual(pieces[1], "hello world")
        assertEqual(#split("", 20), 0)
    end)

    runTest("split: text exactly at the limit is one piece", function()
        local text = string.rep("a", 20)
        local pieces = split(text, 20)
        assertEqual(#pieces, 1)
        assertEqual(pieces[1], text)
    end)

    runTest("split: cuts at the last newline within the limit and drops it", function()
        local text = "line one\nline two\nline three"
        local pieces = split(text, 20)
        assertEqual(pieces[1], "line one\nline two")
        assertEqual(pieces[2], "line three")
        checkPieces(pieces, text, 20)
    end)

    runTest("split: a newline just past the limit still ends the piece at the limit", function()
        local text = string.rep("a", 10) .. "\n" .. "bbb"
        local pieces = split(text, 10)
        assertEqual(pieces[1], string.rep("a", 10))
        assertEqual(pieces[2], "bbb")
    end)

    runTest("split: prefers a newline over a later space", function()
        local text = "aa\nbbbb cccc dddd"
        local pieces = split(text, 12)
        assertEqual(pieces[1], "aa", "cut at the newline at byte 3, not the space at byte 10")
        assertEqual(pieces[2], "bbbb cccc")
        assertEqual(pieces[3], "dddd")
    end)

    runTest("split: with no newline it cuts at the last space", function()
        local text = "the quick brown fox jumps"
        local pieces = split(text, 12)
        assertEqual(pieces[1], "the quick")
        assertEqual(pieces[2], "brown fox")
        assertEqual(pieces[3], "jumps")
        checkPieces(pieces, text, 12)
    end)

    runTest("split: a word longer than the limit is cut at the limit", function()
        local text = string.rep("x", 25)
        local pieces = split(text, 10)
        assertEqual(#pieces, 3)
        assertEqual(pieces[1], string.rep("x", 10))
        assertEqual(pieces[3], string.rep("x", 5))
        checkPieces(pieces, text, 10)
    end)

    runTest("split: multibyte characters are never divided", function()
        local two = utf8.char(0xE9)       -- 2 bytes
        local three = utf8.char(0x263A)   -- 3 bytes
        local four = utf8.char(0x1F600)   -- 4 bytes
        for _, character in { two, three, four } do
            for offset = 0, 4 do
                local text = string.rep("a", 8 + offset) .. string.rep(character, 6)
                local pieces = split(text, 10)
                checkPieces(pieces, text, 10)
            end
        end
    end)

    runTest("split: a long run of multibyte characters fills pieces without splitting any", function()
        local text = string.rep(utf8.char(0xE9), 300)  -- 600 bytes
        local pieces = split(text, 101)                -- odd limit forces a back-up
        checkPieces(pieces, text, 101)
        for _, piece in pieces do
            assertTrue(#piece % 2 == 0, "pieces hold whole two-byte characters")
        end
    end)

    runTest("split: the llSay limit on a 2,649-byte message of 52-byte lines", function()
        local lines = {}
        for i = 1, 50 do
            lines[i] = string.format("line %02d: the quick brown fox jumps over the lazy dog", i)
        end
        local text = table.concat(lines, "\n")
        local pieces = split(text, ChatText.MAX_BYTES)
        assertEqual(#pieces, 3)
        checkPieces(pieces, text, ChatText.MAX_BYTES)
        for _, piece in pieces do
            assertTrue(string.sub(piece, -1) ~= "\n", "pieces do not end in a newline")
        end
    end)

    runTest("split: a limit below four bytes is refused", function()
        assertEqual(pcall(split, "text", 3), false)
    end)

    runTest("ZHost.validate names the first missing required method", function()
        local function noop() end
        local complete = { write = noop, readLine = noop, readChar = noop, fatal = noop, quit = noop }
        ZHost.validate(complete)

        local incomplete = { write = noop, readLine = noop, readChar = noop, quit = noop }
        local ok, err = pcall(ZHost.validate, incomplete)
        assertEqual(ok, false)
        assertTrue(string.find(tostring(err), "fatal", 1, true) ~= nil, "message names 'fatal': " .. tostring(err))
        assertEqual(pcall(ZHost.validate, "not a table"), false)
    end)

    TestFramework.printSummary("ChatText tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

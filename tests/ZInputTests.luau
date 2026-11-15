---------------------------------------------------------------------
-- Tests for ZInput: dictionary encoding and lookup, tokenising, storing
-- an input line, and the encode_text helper.
--
-- Uses Adventureland's real dictionary (every word is decoded, encoded
-- again and found), plus small synthetic dictionaries and buffers in the
-- scratch region at the top of dynamic memory (64 bytes). Mutates
-- dynamic memory; do not follow with real interpretation on the same
-- loaded modules.
--
-- Requires the "ZMachine ROM" cards and the Memory Manager.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZText = require("../VM/ZText.luau")
local ZInput = require("../VM/ZInput.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt

local memory: ZMemory.ZMemory?

-- The story-memory writes ZInput makes, without ZOpcodes' extra checks:
-- this script does not carry the opcode module, to save script memory.
local function makeRam(state: ZState.ZState): ZInput.Ram
    return {
        writeByte = function(addr: number, value: number)
            assert(state.memory:writeU8(addr, value))
        end,
        writeWord = function(addr: number, value: number)
            assert(state.memory:writeU16(addr, value))
        end,
    }
end

-- Everything a test needs: a state, a ZText, and a ZInput over the real
-- story header.
local function newInput(header: any?): (ZState.ZState, ZInput.ZInput, any)
    assert(memory, "ZMemory not initialized")
    local state = TestFramework.freshState(memory)
    local text = ZText.new(state.memory, state.header)
    local input = ZInput.new(state.memory, header or state.header, text, makeRam(state))
    return state, input, text
end

-- Packs Z-characters three to a word and sets the end bit, written
-- independently of ZInput so the expectations do not share its code.
local function pack(zchars: { number }): { number }
    local words = {}
    for i = 1, #zchars, 3 do
        table.insert(words, zchars[i] * 1024 + zchars[i + 1] * 32 + zchars[i + 2])
    end
    words[#words] += 0x8000
    return words
end

local function codePoints(word: string): { number }
    local list = {}
    for i = 1, #word do
        list[i] = string.byte(word, i)
    end
    return list
end

-- The dictionary's layout: where its entries start, their length and count.
local function dictionaryLayout(state: ZState.ZState): (number, number, number, number)
    local dict = state.header.dictionary
    local mem = state.memory
    local separators = mem:readU8(dict)
    local entryLength = mem:readU8(dict + 1 + separators)
    local count = mem:readU16(dict + 2 + separators)
    return dict + 4 + separators, entryLength, count, separators
end

-- Decodes the dictionary word at an entry address into a string of code
-- points (a list), using ZText.
local function decodeEntry(text: any, entry: number): { number }
    local chars: { number } = {}
    local sink = {
        putChar = function(_, codePoint: number)
            table.insert(chars, codePoint)
        end,
        newLine = function()
            table.insert(chars, 10)
        end,
    }
    text:printAt(sink, entry)
    return chars
end

local function asString(list: { number }): string
    local parts = {}
    for i, codePoint in list do
        parts[i] = utf8.char(codePoint)
    end
    return table.concat(parts)
end

-- Two short dictionary words made only of lowercase letters.
local function pickWords(state: ZState.ZState, text: any): ({ string }, { number })
    local first, entryLength, count = dictionaryLayout(state)
    local words: { string } = {}
    local addresses: { number } = {}
    for n = 0, count - 1 do
        local entry = first + n * entryLength
        local chars = decodeEntry(text, entry)
        local word = asString(chars)
        if #word >= 3 and #word <= 6 and string.match(word, "^%l+$") then
            table.insert(words, word)
            table.insert(addresses, entry)
            if #words == 2 then
                break
            end
        end
    end
    return words, addresses
end

-- Builds a V5 text buffer at `addr` holding `line` (capacity 40).
local function writeV5Text(state: ZState.ZState, addr: number, line: string)
    local bytes = { 40, #line }
    for i = 1, #line do
        table.insert(bytes, string.byte(line, i))
    end
    writeBytesAt(state, addr, bytes)
end

-- Sets up a parse buffer with room for `max` tokens, empty.
local function writeParse(state: ZState.ZState, addr: number, max: number)
    writeBytesAt(state, addr, { max, 0 })
end

local function token(state: ZState.ZState, parse: number, n: number): (number, number, number)
    local slot = parse + 2 + 4 * (n - 1)
    return state.memory:readU16(slot), state.memory:readU8(slot + 2), state.memory:readU8(slot + 3)
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    runTest("encodeWord: padding, truncation to nine Z-characters, shifts and the ZSCII escape", function()
        local _, input = newInput()
        local function enc(word: string, padding: number?)
            return input:encodeWord(codePoints(word), padding or 5)
        end
        -- "a" is Z-character 6; the rest is padding.
        assertEqual(table.concat(enc("a"), ","), table.concat(pack({ 6, 5, 5, 5, 5, 5, 5, 5, 5 }), ","))
        -- Only nine Z-characters fit: a..i.
        assertEqual(table.concat(enc("abcdefghijk"), ","), table.concat(pack({ 6, 7, 8, 9, 10, 11, 12, 13, 14 }), ","))
        -- Capital A: shift to A1 (Z-character 4 in V3+), then 6.
        assertEqual(table.concat(enc("A"), ","), table.concat(pack({ 4, 6, 5, 5, 5, 5, 5, 5, 5 }), ","))
        -- Digit 0 is A2 index 2: shift 5, then 2 + 6.
        assertEqual(table.concat(enc("0"), ","), table.concat(pack({ 5, 8, 5, 5, 5, 5, 5, 5, 5 }), ","))
        -- '%' is in no alphabet: escape 5, 6, then 0x25 split in 3 and 5 bits.
        assertEqual(table.concat(enc("%"), ","), table.concat(pack({ 5, 6, 1, 5, 5, 5, 5, 5, 5 }), ","))
        -- A different padding (as used by word completion) fills the rest.
        assertEqual(table.concat(enc("a", 0), ","), table.concat(pack({ 6, 0, 0, 0, 0, 0, 0, 0, 0 }), ","))
    end)

    runTest("every dictionary word decodes, re-encodes to its own entry, and is found by lookup", function()
        local state, input, text = newInput()
        local first, entryLength, count = dictionaryLayout(state)
        assertTrue(count > 50, "the dictionary should have many entries (" .. count .. ")")
        local mem = state.memory
        for n = 0, count - 1 do
            local entry = first + n * entryLength
            local chars = decodeEntry(text, entry)
            local encoded = input:encodeWord(chars, 5)
            for i = 1, 3 do
                if encoded[i] ~= mem:readU16(entry + 2 * (i - 1)) then
                    assertTrue(false, string.format("entry %d (%s) re-encodes differently in word %d",
                        n, asString(chars), i))
                end
            end
            if input:lookup(encoded, state.header.dictionary) ~= entry then
                assertTrue(false, string.format("lookup of entry %d (%s) did not return its address", n, asString(chars)))
            end
        end
    end)

    runTest("lookup: an unknown word returns 0", function()
        local state, input = newInput()
        local encoded = input:encodeWord(codePoints("qzxvwk"), 5)
        assertEqual(input:lookup(encoded, state.header.dictionary), 0)
    end)

    runTest("lookup: an unsorted dictionary (negative count) is searched linearly", function()
        local state, input = newInput()
        local base = scratchBase(state)
        local words = {}
        for _, w in { "cat", "ant", "bee" } do  -- deliberately out of order
            table.insert(words, input:encodeWord(codePoints(w), 5))
        end
        local bytes = { 0, 7, 0xFF, 0xFD }  -- no separators, entry length 7, count -3
        for _, word in words do
            for i = 1, 3 do
                table.insert(bytes, bit32.rshift(word[i], 8))
                table.insert(bytes, bit32.band(word[i], 0xFF))
            end
            table.insert(bytes, 0)  -- one data byte
        end
        writeBytesAt(state, base, bytes)
        for i, w in { "cat", "ant", "bee" } do
            local encoded = input:encodeWord(codePoints(w), 5)
            assertEqual(input:lookup(encoded, base), base + 4 + 7 * (i - 1), w .. " found at its position")
        end
        assertEqual(input:lookup(input:encodeWord(codePoints("dog"), 5), base), 0, "dog is not there")
    end)

    runTest("tokenise (V5): two words, one token each, with their lengths and offsets", function()
        local state, input, text = newInput()
        local words, addresses = pickWords(state, text)
        assertEqual(#words, 2, "found two plain dictionary words")
        local base = scratchBase(state)
        local textAddr, parse = base, base + 16
        local line = words[1] .. " " .. words[2]
        writeV5Text(state, textAddr, line)
        writeParse(state, parse, 6)
        input:tokenise(textAddr, parse, 0, false)

        assertEqual(state.memory:readU8(parse + 1), 2, "token count")
        local a1, l1, o1 = token(state, parse, 1)
        local a2, l2, o2 = token(state, parse, 2)
        assertEqual(a1, addresses[1])
        assertEqual(l1, #words[1])
        assertEqual(o1, 2, "the first word starts at byte 2 of a V5 buffer")
        assertEqual(a2, addresses[2])
        assertEqual(l2, #words[2])
        assertEqual(o2, 2 + #words[1] + 1)
    end)

    runTest("tokenise (V5): extra spaces are skipped; an unknown word gets address 0", function()
        local state, input, text = newInput()
        local words, addresses = pickWords(state, text)
        local base = scratchBase(state)
        local textAddr, parse = base, base + 20
        writeV5Text(state, textAddr, "  " .. words[1] .. "   qzxv ")
        writeParse(state, parse, 6)
        input:tokenise(textAddr, parse, 0, false)
        assertEqual(state.memory:readU8(parse + 1), 2)
        local a1, l1, o1 = token(state, parse, 1)
        assertEqual(a1, addresses[1])
        assertEqual(l1, #words[1])
        assertEqual(o1, 4)
        local a2, l2, o2 = token(state, parse, 2)
        assertEqual(a2, 0, "unknown word")
        assertEqual(l2, 4)
        assertEqual(o2, 4 + #words[1] + 3)
    end)

    runTest("tokenise (V5): a dictionary separator is a word of its own", function()
        local state, input, text = newInput()
        local _, _, _, separatorCount = dictionaryLayout(state)
        assertTrue(separatorCount > 0, "Adventureland's dictionary has separators")
        local separator = state.memory:readU8(state.header.dictionary + 1)
        local words = pickWords(state, text)
        local base = scratchBase(state)
        local textAddr, parse = base, base + 20
        writeV5Text(state, textAddr, words[1] .. string.char(separator) .. words[2])
        writeParse(state, parse, 6)
        input:tokenise(textAddr, parse, 0, false)
        assertEqual(state.memory:readU8(parse + 1), 3, "word, separator, word")
        local _, l2, o2 = token(state, parse, 2)
        assertEqual(l2, 1, "the separator token is one character")
        assertEqual(o2, 2 + #words[1])
        local _, _, o3 = token(state, parse, 3)
        assertEqual(o3, 2 + #words[1] + 1)
    end)

    runTest("tokenise (V5): stops at the parse buffer's token limit", function()
        local state, input, text = newInput()
        local words = pickWords(state, text)
        local base = scratchBase(state)
        local textAddr, parse = base, base + 24
        writeV5Text(state, textAddr, words[1] .. " " .. words[2] .. " " .. words[1])
        writeParse(state, parse, 2)
        input:tokenise(textAddr, parse, 0, false)
        assertEqual(state.memory:readU8(parse + 1), 2, "only two tokens fit")
    end)

    runTest("tokenise (V5): skipUnknown leaves an unknown word's slot alone; otherwise it is zeroed", function()
        local state, input = newInput()
        local base = scratchBase(state)
        local textAddr, parse = base, base + 16
        writeV5Text(state, textAddr, "qzxv")

        writeParse(state, parse, 3)
        writeBytesAt(state, parse + 2, { 0xAA, 0xAA, 0xBB, 0xCC })
        input:tokenise(textAddr, parse, 0, true)
        assertEqual(state.memory:readU8(parse + 1), 1, "the count still advances")
        local a, l, o = token(state, parse, 1)
        assertEqual(a, 0xAAAA)
        assertEqual(l, 0xBB)
        assertEqual(o, 0xCC)

        writeParse(state, parse, 3)
        writeBytesAt(state, parse + 2, { 0xAA, 0xAA, 0xBB, 0xCC })
        input:tokenise(textAddr, parse, 0, false)
        a, l, o = token(state, parse, 1)
        assertEqual(a, 0)
        assertEqual(l, 4)
        assertEqual(o, 2)
    end)

    runTest("storeLine (V5): lowercases, stores the length, tokenises, and truncates to capacity", function()
        local state, input, text = newInput()
        local words, addresses = pickWords(state, text)
        local base = scratchBase(state)
        local textAddr, parse = base, base + 24
        writeBytesAt(state, textAddr, { 30, 0 })
        writeParse(state, parse, 4)

        local line = string.upper(words[1])
        input:storeLine(textAddr, parse, line, true)
        local mem = state.memory
        assertEqual(mem:readU8(textAddr + 1), #line, "length byte")
        for i = 1, #line do
            assertEqual(mem:readU8(textAddr + 1 + i), string.byte(words[1], i), "lowercased byte " .. i)
        end
        assertEqual(mem:readU8(parse + 1), 1)
        assertEqual((token(state, parse, 1)), addresses[1], "the lowercased word is found")

        -- Capacity 5: a longer line is cut.
        writeBytesAt(state, textAddr, { 5, 0, 0, 0, 0, 0, 0, 0, 0, 0 })  -- clears earlier text too
        input:storeLine(textAddr, 0, "abcdefghij", true)
        assertEqual(mem:readU8(textAddr + 1), 5)
        assertEqual(mem:readU8(textAddr + 2 + 4), string.byte("e"))
        assertEqual(mem:readU8(textAddr + 2 + 5), 0, "nothing written past the capacity")
    end)

    runTest("storeLine (V5): a line ended by a timeout keeps its case and is not tokenised", function()
        local state, input = newInput()
        local base = scratchBase(state)
        local textAddr, parse = base, base + 24
        writeBytesAt(state, textAddr, { 30, 0 })
        writeParse(state, parse, 4)
        writeBytesAt(state, parse + 1, { 0x77 })
        input:storeLine(textAddr, parse, "Abc", false)
        assertEqual(state.memory:readU8(textAddr + 2), string.byte("A"), "case kept")
        assertEqual(state.memory:readU8(textAddr + 1), 3)
        assertEqual(state.memory:readU8(parse + 1), 0x77, "parse buffer untouched")
    end)

    runTest("storeLine (V5): Latin-1 capitals lowercase and characters map to ZSCII", function()
        local state, input, text = newInput()
        local base = scratchBase(state)
        writeBytesAt(state, base, { 30, 0 })
        input:storeLine(base, 0, utf8.char(0xC9) .. "A", true)  -- E-acute, A
        assertEqual(state.memory:readU8(base + 1), 2)
        assertEqual(state.memory:readU8(base + 2), text:toZscii(0xE9), "E-acute became e-acute")
        assertEqual(state.memory:readU8(base + 3), string.byte("a"))
    end)

    runTest("V3 layout: zero-terminated text from byte 1, two-word dictionary", function()
        local state, _, text = newInput()
        local v3 = table.clone(state.header)
        v3.version = 3
        local base = scratchBase(state)
        local textAddr, parse, dict = base, base + 16, base + 40
        v3.dictionary = dict

        -- A two-word-resolution dictionary: sorted "cat", "dog".
        local input = ZInput.new(state.memory, v3, text, makeRam(state))
        local bytes = { 0, 5, 0, 2 }  -- no separators, entry length 5, two entries
        for _, w in { "cat", "dog" } do
            local encoded = input:encodeWord(codePoints(w), 5)
            assertEqual(#encoded, 2, "two words per entry up to V3")
            for i = 1, 2 do
                table.insert(bytes, bit32.rshift(encoded[i], 8))
                table.insert(bytes, bit32.band(encoded[i], 0xFF))
            end
            table.insert(bytes, 0)
        end
        writeBytesAt(state, dict, bytes)
        writeBytesAt(state, textAddr, { 12, 0 })
        writeParse(state, parse, 4)

        input:storeLine(textAddr, parse, "Cat dog", true)
        local mem = state.memory
        for i, ch in codePoints("cat dog") do
            assertEqual(mem:readU8(textAddr + i), ch, "text byte " .. i)
        end
        assertEqual(mem:readU8(textAddr + 8), 0, "terminator")
        assertEqual(mem:readU8(parse + 1), 2)
        local a1, l1, o1 = token(state, parse, 1)
        local a2, l2, o2 = token(state, parse, 2)
        assertEqual(a1, dict + 4, "cat is the first entry")
        assertEqual(l1, 3)
        assertEqual(o1, 1, "the first word starts at byte 1 of a V3 buffer")
        assertEqual(a2, dict + 9, "dog is the second entry")
        assertEqual(l2, 3)
        assertEqual(o2, 5)
    end)

    runTest("encodeText writes the three encoded words at the destination", function()
        local state, input = newInput()
        local base = scratchBase(state)
        writeBytesAt(state, base, { 0, 0, 0, 0, string.byte("l"), string.byte("o"), string.byte("o"), string.byte("k") })
        input:encodeText(base, 4, 4, base + 16)
        local expected = input:encodeWord(codePoints("look"), 5)
        for i = 1, 3 do
            assertEqual(state.memory:readU16(base + 16 + 2 * (i - 1)), expected[i], "word " .. i)
        end
    end)

    TestFramework.printSummary("ZInput tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroutineMgr:create_task(runAllTests)

---------------------------------------------------------------------
-- Test harness for ZText part one (Phase 4.5.2): alphabets and ZSCII <->
-- Unicode translation.
--
-- Synthetic tables (a custom alphabet, a story Unicode table, a header
-- extension table) are written into scratch RAM, and header variants are
-- clones of the real header. Mutates dynamic memory; do not follow with
-- real interpretation on the same loaded modules.
---------------------------------------------------------------------

local ZMemory = require("../VM/ZMemory.luau")
local ZState = require("../VM/ZState.luau")
local ZObject = require("../VM/ZObject.luau")
local ZText = require("../VM/ZText.luau")
local ZOutput = require("../VM/ZOutput.luau")
local CoroutineMgr = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local NOTECARD_NAME = "ZMachine ROM"

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt

local memory: ZMemory.ZMemory?

local function freshState(): ZState.ZState
    assert(memory, "ZMemory not initialized")
    return TestFramework.freshState(memory)
end

-- Writes a header extension table at `base` whose Unicode-table word
-- points at base + 16, and a Unicode table there with three entries:
-- U+263A, U+0010 (too low to be valid), U+00E9. Returns a header clone
-- pointing at the extension table.
local function headerWithUnicodeTable(state: ZState.ZState): any
    local base = scratchBase(state)
    writeBytesAt(state, base, { 0, 0, 0, 0, 0, 0, 0, 0 })
    assert(state.memory:writeU16(base, 3))            -- the table holds 3 words
    assert(state.memory:writeU16(base + 6, base + 16))  -- word 3: the Unicode table
    writeBytesAt(state, base + 16, { 3, 0x26, 0x3A, 0x00, 0x10, 0x00, 0xE9 })
    local header = table.clone(state.header)
    header.headerExtensionTable = base
    return header
end

-- Packs Z-characters three to a word, padding with 5 and setting the
-- end bit on the last word.
local function packZchars(zchars: {number}): {number}
    local words = {}
    for i = 1, #zchars, 3 do
        table.insert(words, (zchars[i] * 32 + (zchars[i + 1] or 5)) * 32 + (zchars[i + 2] or 5))
    end
    words[#words] += 0x8000
    return words
end

local function writeZString(state: ZState.ZState, addr: number, zchars: {number}): number
    for i, word in packZchars(zchars) do
        assert(state.memory:writeU16(addr + 2 * (i - 1), word))
    end
    return addr
end

-- A stand-in for ZOutput that records what the decoder sends it.
local function recorder(): (any, () -> string)
    local parts: {string} = {}
    local out = {
        putChar = function(_, codePoint: number)
            table.insert(parts, utf8.char(codePoint))
        end,
        newLine = function()
            table.insert(parts, "\n")
        end,
    }
    return out, function(): string
        return table.concat(parts)
    end
end

local function runAllTests()
    memory = TestFramework.loadMemory(NOTECARD_NAME)
    if not memory then
        return
    end

    runTest("default alphabets: A0 lowercase, A1 uppercase, A2 punctuation (V1 differs)", function()
        local state = freshState()
        local header = table.clone(state.header)
        header.alphabetTable = 0
        header.version = 5
        local text = ZText.new(state.memory, header)
        assertEqual(text:alphabet(0, 0), 97, "a")
        assertEqual(text:alphabet(0, 25), 122, "z")
        assertEqual(text:alphabet(1, 0), 65, "A")
        assertEqual(text:alphabet(1, 25), 90, "Z")
        assertEqual(text:alphabet(2, 0), 32, "space")
        assertEqual(text:alphabet(2, 1), 94, "V2+ index 1 is the newline marker '^'")
        assertEqual(text:alphabet(2, 2), 48, "V2+ index 2 is '0'")
        assertEqual(text:alphabet(2, 21), 92, "V2+ index 21 is a backslash")
        assertEqual(text:alphabet(2, 22), 45, "'-'")

        header.version = 1
        local v1 = ZText.new(state.memory, header)
        assertEqual(v1:alphabet(2, 1), 48, "V1 index 1 is '0'")
        assertEqual(v1:alphabet(2, 21), 60, "V1 index 21 is '<'")
        assertEqual(v1:alphabet(2, 22), 45, "'-'")
    end)

    runTest("a custom alphabet table is read from memory and translated from ZSCII", function()
        local state = freshState()
        local base = scratchBase(state)
        writeBytesAt(state, base, { 0x7A, 0x79, 0x78 })       -- A0: z y x
        writeBytesAt(state, base + 26, { 0x31 })              -- A1 index 0: '1'
        writeBytesAt(state, base + 52, { 0x9B, 0x41 })        -- A2: ZSCII 155 (a-umlaut), 'A'
        local header = table.clone(state.header)
        header.alphabetTable = base
        local text = ZText.new(state.memory, header)
        assertEqual(text:alphabet(0, 0), 0x7A, "A0 index 0")
        assertEqual(text:alphabet(0, 2), 0x78, "A0 index 2")
        assertEqual(text:alphabet(1, 0), 0x31, "A1 index 0")
        assertEqual(text:alphabet(2, 0), 0xE4, "ZSCII 155 maps through the standard extra characters")
        assertEqual(text:alphabet(2, 1), 0x41, "A2 index 1")
    end)

    runTest("fromZscii: ASCII passes through; 155-223 use the standard extra characters", function()
        local state = freshState()
        local header = table.clone(state.header)
        header.headerExtensionTable = 0
        local text = ZText.new(state.memory, header)
        assertEqual(text:fromZscii(65), 65)
        assertEqual(text:fromZscii(13), 13, "control codes pass through")
        assertEqual(text:fromZscii(155), 0xE4, "a-umlaut")
        assertEqual(text:fromZscii(162), 0xBB, "right guillemet")
        assertEqual(text:fromZscii(163), 0xAB, "left guillemet")
        assertEqual(text:fromZscii(219), 0xA3, "pound sign")
        assertEqual(text:fromZscii(220), 0x153, "oe ligature")
        assertEqual(text:fromZscii(221), 0x152, "OE ligature")
        assertEqual(text:fromZscii(223), 0xBF, "inverted question mark")
        assertEqual(text:fromZscii(224), 63, "beyond the standard set is '?'")
    end)

    runTest("fromZscii with a story Unicode table", function()
        local state = freshState()
        local text = ZText.new(state.memory, headerWithUnicodeTable(state))
        assertEqual(text.unicodeTable, scratchBase(state) + 16, "the table pointer was read from the extension")
        assertEqual(text:fromZscii(155), 0x263A, "first entry")
        assertEqual(text:fromZscii(156), 63, "an entry below U+0020 is '?'")
        assertEqual(text:fromZscii(157), 0xE9, "third entry")
        assertEqual(text:fromZscii(158), 63, "beyond the table is '?'")
        assertEqual(text:fromZscii(70), 70, "ASCII is unaffected")
    end)

    runTest("toZscii: ASCII and 0 pass through, standard characters map back, others are '?'", function()
        local state = freshState()
        local header = table.clone(state.header)
        header.headerExtensionTable = 0
        local text = ZText.new(state.memory, header)
        assertEqual(text:toZscii(0), 0)
        assertEqual(text:toZscii(65), 65)
        assertEqual(text:toZscii(0x9F), 0x9F, "below U+00A0 maps to itself")
        assertEqual(text:toZscii(0xE4), 155, "a-umlaut")
        assertEqual(text:toZscii(0x153), 220, "oe ligature")
        assertEqual(text:toZscii(0x4E2D), 63, "a character the story cannot represent")
    end)

    runTest("toZscii with a story Unicode table", function()
        local state = freshState()
        local text = ZText.new(state.memory, headerWithUnicodeTable(state))
        assertEqual(text:toZscii(0x263A), 155, "first entry")
        assertEqual(text:toZscii(0xE9), 157, "third entry")
        assertEqual(text:toZscii(0xE4), 63, "in the standard set but not in this story's table")
        assertEqual(text:toZscii(65), 65, "ASCII is unaffected")
    end)

    runTest("every standard extra character round-trips through Unicode", function()
        local state = freshState()
        local header = table.clone(state.header)
        header.headerExtensionTable = 0
        local text = ZText.new(state.memory, header)
        for zscii = 155, 223 do
            assertEqual(text:toZscii(text:fromZscii(zscii)), zscii, "ZSCII " .. zscii)
        end
    end)

    runTest("the real story parses: no custom Unicode table, and a short extension table is ignored", function()
        local state = freshState()
        local text = ZText.new(state.memory, state.header)
        if text.alphabetTable == 0 then
            for i = 0, 25 do
                assertEqual(text:alphabet(0, i), 97 + i, "default A0 " .. i)
            end
        end

        local base = scratchBase(state)
        assert(state.memory:writeU16(base, 2))            -- table holds only 2 words
        assert(state.memory:writeU16(base + 6, 0x1234))   -- word 3 exists in memory but not in the table
        local header = table.clone(state.header)
        header.headerExtensionTable = base
        assertEqual(ZText.new(state.memory, header).unicodeTable, 0, "word 3 is beyond the table's size")
    end)

    runTest("ZOutput uses ZText for stream 3 and still delivers UTF-8 to the screen", function()
        local state = freshState()
        local header = table.clone(state.header)
        header.headerExtensionTable = 0
        local text = ZText.new(state.memory, header)

        local bytes: {[number]: number} = {}
        local chunks: {string} = {}
        local out = ZOutput.new(function(chunk: string)
            table.insert(chunks, chunk)
        end, {
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
        })
        out.toZscii = function(codePoint: number): number
            return text:toZscii(codePoint)
        end

        assertTrue(out:openMemory(100))
        out:putChar(0xE4)
        out:putChar(0x4E2D)
        out:closeMemory()
        assertEqual(bytes[102], 155, "a-umlaut is stored as ZSCII 155")
        assertEqual(bytes[103], 63, "an unrepresentable character is stored as '?'")

        out:putChar(0xE4)
        out:flush()
        assertEqual(chunks[1], utf8.char(0xE4), "the screen receives UTF-8")
    end)

    ------------------------------------------------------------------
    -- Z-string decoding (Phase 4.5.3)
    ------------------------------------------------------------------

    runTest("decode: lowercase letters from lower memory", function()
        local state = freshState()
        local text = ZText.new(state.memory, state.header)
        local out, result = recorder()
        text:printLow(out, writeZString(state, scratchBase(state), { 13, 10, 17, 17, 20 }))
        assertEqual(result(), "hello")
    end)

    runTest("decode: a single shift to A1 capitalises one letter; zero is a space", function()
        local state = freshState()
        local text = ZText.new(state.memory, state.header)
        local out, result = recorder()
        text:printLow(out, writeZString(state, scratchBase(state), { 4, 13, 14, 0, 25, 13, 10, 23, 10 }))
        assertEqual(result(), "Hi there")
    end)

    runTest("decode: A2 digits, and A2 index 7 is a newline", function()
        local state = freshState()
        local text = ZText.new(state.memory, state.header)
        local out, result = recorder()
        text:printLow(out, writeZString(state, scratchBase(state), { 5, 8, 5, 9 }))
        assertEqual(result(), "01")

        out, result = recorder()
        text:printLow(out, writeZString(state, scratchBase(state), { 6, 5, 7, 7 }))
        assertEqual(result(), "a\nb")
    end)

    runTest("decode: V1-V2 shift-lock characters stay locked, V3+ shifts last one character", function()
        local state = freshState()
        local header = table.clone(state.header)
        local addr = writeZString(state, scratchBase(state), { 4, 13, 14 })

        header.version = 2
        local out, result = recorder()
        ZText.new(state.memory, header):printLow(out, addr)
        assertEqual(result(), "HI", "V2: the lock persists")

        header.version = 3
        out, result = recorder()
        ZText.new(state.memory, header):printLow(out, addr)
        assertEqual(result(), "Hi", "V3: the shift applies to one character")
    end)

    runTest("decode: the two-part ZSCII escape", function()
        local state = freshState()
        local header = table.clone(state.header)
        header.headerExtensionTable = 0
        local text = ZText.new(state.memory, header)
        local out, result = recorder()
        text:printLow(out, writeZString(state, scratchBase(state), { 5, 6, 4, 27, 5, 6, 3, 1 }))
        assertEqual(result(), utf8.char(0xE4) .. "a", "ZSCII 155 then 97")
    end)

    runTest("decode: abbreviations expand in place", function()
        local state = freshState()
        local base = scratchBase(state)
        local header = table.clone(state.header)
        header.abbreviations = base + 32
        assert(state.memory:writeU16(base + 32, (base + 40) / 2))
        writeZString(state, base + 40, { 6, 7 })           -- "ab"
        writeZString(state, base, { 1, 0, 29 })            -- abbreviation 1/0, then "x"
        local out, result = recorder()
        ZText.new(state.memory, header):printLow(out, base)
        assertEqual(result(), "abx")
    end)

    runTest("decode: an embedded string consumes exactly its own words", function()
        local state = freshState()
        local text = ZText.new(state.memory, state.header)
        local queue = { packZchars({ 13, 14 })[1], 0x1234 }
        local taken = 0
        local out, result = recorder()
        text:printEmbedded(out, queue, function(source: {number}): number
            taken += 1
            return source[taken]
        end)
        assertEqual(result(), "hi")
        assertEqual(taken, 1, "the word after the end bit is left alone")
    end)

    runTest("decode: printAt reads a full byte address; illegal addresses call onIllegalAddress", function()
        local state = freshState()
        local base = scratchBase(state)
        writeZString(state, base, { 13, 14 })
        local flagged = false
        local text = ZText.new(state.memory, state.header, function()
            flagged = true
            error("illegal")
        end)

        local out, result = recorder()
        text:printAt(out, base)
        assertEqual(result(), "hi")
        assertEqual(flagged, false)

        assertEqual(pcall(function()
            text:printAt(out, state.memory.storySize)
        end), false, "past the end of the story")
        assertEqual(flagged, true)

        flagged = false
        assertEqual(pcall(function()
            text:printLow(out, 0x10000)
        end), false, "lower-memory strings are limited to 64K")
        assertEqual(flagged, true)
    end)

    runTest("decode: an abbreviation that refers to itself stops at the depth limit", function()
        local state = freshState()
        local base = scratchBase(state)
        local header = table.clone(state.header)
        header.abbreviations = base + 32
        assert(state.memory:writeU16(base + 32, (base + 40) / 2))
        writeZString(state, base + 40, { 1, 0 })           -- refers to abbreviation 1/0 again
        writeZString(state, base, { 1, 0 })
        local flagged = false
        local text = ZText.new(state.memory, header, function()
            flagged = true
            error("illegal")
        end)
        local out = recorder()
        assertEqual(pcall(function()
            text:printLow(out, base)
        end), false)
        assertEqual(flagged, true)
    end)

    runTest("decode: Adventureland's object names match an independent decoder", function()
        local state = freshState()
        local text = ZText.new(state.memory, state.header)
        local expected = {
            [1] = "Class",
            [2] = "Object",
            [5] = "CompassDirection",
            [19] = "(darkness object)",
            [20] = "(self object)",
            [29] = "*GOLDEN FISH*",
            [30] = "rusty axe (magic word- BUNYON -on it)",
            [34] = "*SMALL STATUE OF A BLUE OX*",
        }
        for obj, name in expected do
            local out, result = recorder()
            text:printLow(out, ZObject.nameAddress(state, obj) + 1)
            assertEqual(result(), name, "object " .. obj)
        end

        local decoded = 0
        for obj = 1, TestFramework.objectCount(state) do
            local nameAddr = ZObject.nameAddress(state, obj)
            if state.memory:readU8(nameAddr) ~= 0 then
                local out, result = recorder()
                text:printLow(out, nameAddr + 1)
                assertTrue(string.match(result(), "^[ -~]*$") ~= nil, "object " .. obj .. " decodes to printable text")
                decoded += 1
            end
        end
        assertTrue(decoded > 0, "at least one object has a name")
    end)

    TestFramework.printSummary("ZText tests")
end

CoroutineMgr:create_task(runAllTests)

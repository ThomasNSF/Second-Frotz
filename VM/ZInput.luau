---------------------------------------------------------------------
-- Z-machine text input: dictionary encoding and lookup, tokenising an
-- input line, and storing a line into the story's text buffer.
--
-- Takes the story memory, parsed header, a ZText and a RAM write
-- interface as arguments and requires no other VM module, so it can be
-- tested alone or moved into its own script. Dictionary reads go through
-- memory and may yield, so everything here must run inside the VM
-- coroutine.
--
-- Mirrors encode_text, load_string, lookup_text, tokenise_text,
-- tokenise_line and z_encode_text (text.c) and the buffer handling of
-- z_read (input.c). Deviations from Frotz:
--   * The -x option that expands "g", "x" and "z" is off by default and
--     is omitted.
--   * The trailing-"?" removal for a list of Infocom stories is omitted,
--     since it needs Frotz's story identification table.
--   * Text already in a V5 input buffer is not pre-filled, because a chat
--     host cannot edit a line.
--   * Lowercasing covers ASCII and Latin-1 only.
--   * Word completion (lookup modes 0x00 and 0x1f) is not provided.
---------------------------------------------------------------------

-- Frotz reads at most this many characters, whatever the story's buffer.
local INPUT_BUFFER_SIZE = 200

-- Z-character padding that marks an exact dictionary lookup.
local PAD_EXACT = 0x05

export type Ram = {
    writeByte: (number, number) -> (),
    writeWord: (number, number) -> (),
}

export type ZInput = {
    memory: any,
    header: any,
    text: any,
    ram: Ram,
    resolution: (ZInput) -> number,
    encodeWord: (ZInput, { number }, number) -> { number },
    loadString: (ZInput, number, number) -> { number },
    lookup: (ZInput, { number }, number) -> number,
    tokenise: (ZInput, number, number, number, boolean) -> (),
    storeLine: (ZInput, number, number, string, boolean) -> (),
    encodeText: (ZInput, number, number, number, number) -> (),
}

local ZInput = {}
ZInput.__index = ZInput

ZInput.PAD_EXACT = PAD_EXACT
ZInput.INPUT_BUFFER_SIZE = INPUT_BUFFER_SIZE

function ZInput.new(memory: any, header: any, text: any, ram: Ram): ZInput
    return setmetatable({
        memory = memory,
        header = header,
        text = text,
        ram = ram,
    }, ZInput) :: any
end

-- Lowercases a code point: ASCII and Latin-1 letters.
function ZInput.lower(codePoint: number): number
    if codePoint >= 65 and codePoint <= 90 then
        return codePoint + 32
    elseif codePoint >= 0xC0 and codePoint <= 0xDE and codePoint ~= 0xD7 then
        return codePoint + 32
    end
    return codePoint
end

-- Dictionary words are two Z-words long up to V3, three from V4.
function ZInput:resolution(): number
    return if self.header.version <= 3 then 2 else 3
end

-- Encodes up to 3 * resolution characters (Unicode code points; a 0 or a
-- missing entry means the word has ended) into dictionary form. Longer
-- words are cut, shorter ones are padded with `padding`.
function ZInput:encodeWord(codePoints: { number }, padding: number): { number }
    local version = self.header.version
    local text = self.text
    local resolution = self:resolution()
    local wanted = 3 * resolution
    local zchars: { number } = {}
    local position = 1

    while #zchars < wanted do
        local c = codePoints[position]
        position += 1
        if c ~= nil and c ~= 0 then
            local foundSet, foundIndex = nil, nil
            for set = 0, 2 do
                for index = 0, 25 do
                    if text:alphabet(set, index) == c then
                        foundSet, foundIndex = set, index
                        break
                    end
                end
                if foundSet then
                    break
                end
            end

            if foundSet then
                if foundSet ~= 0 then
                    table.insert(zchars, (if version <= 2 then 1 else 3) + foundSet)
                end
                table.insert(zchars, foundIndex + 6)
            else
                -- Not in any alphabet: the four-Z-character ZSCII escape.
                local zscii = text:toZscii(c)
                table.insert(zchars, 5)
                table.insert(zchars, 6)
                table.insert(zchars, bit32.rshift(zscii, 5))
                table.insert(zchars, bit32.band(zscii, 0x1F))
            end
        else
            table.insert(zchars, padding)
        end
    end

    local words: { number } = {}
    for i = 0, resolution - 1 do
        words[i + 1] = zchars[3 * i + 1] * 1024 + zchars[3 * i + 2] * 32 + zchars[3 * i + 3]
    end
    words[resolution] = bit32.bor(words[resolution], 0x8000)
    return words
end

-- Reads `length` ZSCII bytes at `addr` as Unicode code points, padded
-- with zeros up to the length a dictionary word can use.
function ZInput:loadString(addr: number, length: number): { number }
    local wanted = 3 * self:resolution()
    local chars: { number } = {}
    for i = 0, wanted - 1 do
        if i < length then
            chars[i + 1] = self.text:fromZscii(self.memory:readU8(bit32.band(addr + i, 0xFFFF)))
        else
            chars[i + 1] = 0
        end
    end
    return chars
end

-- Looks an encoded word up in the dictionary at `dict`, returning the
-- address of its entry or 0. A negative entry count marks an unsorted
-- dictionary, which is searched linearly.
function ZInput:lookup(encoded: { number }, dict: number): number
    local memory = self.memory
    local resolution = self:resolution()

    local separators = memory:readU8(dict)
    local addr = dict + 1 + separators
    local entryLength = memory:readU8(addr)
    local entryCount = memory:readU16(addr + 1)
    addr += 3

    local sorted = true
    if entryCount >= 0x8000 then
        entryCount = 0x10000 - entryCount
        sorted = false
    end

    local lower, upper = 0, entryCount - 1
    while lower <= upper do
        local number = if sorted then (lower + upper) // 2 else lower
        local entryAddr = addr + number * entryLength

        local mismatchEncoded, mismatchEntry = nil, nil
        for i = 1, resolution do
            local entry = memory:readU16(entryAddr + 2 * (i - 1))
            if encoded[i] ~= entry then
                mismatchEncoded, mismatchEntry = encoded[i], entry
                break
            end
        end
        if mismatchEncoded == nil then
            return entryAddr
        end

        if not sorted then
            lower += 1
        elseif mismatchEncoded > mismatchEntry then
            lower = number + 1
        else
            upper = number - 1
        end
    end
    return 0
end

-- Appends one word's token to the parse buffer, if there is room.
-- A token is the dictionary entry's address (0 if unknown), the word's
-- length, and its offset from the start of the text buffer.
local function tokeniseWord(self: ZInput, textAddr: number, length: number, from: number,
        parse: number, dict: number, skipUnknown: boolean)
    local memory = self.memory
    local max = memory:readU8(parse)
    local count = memory:readU8(parse + 1)
    if count >= max then
        return
    end
    self.ram.writeByte(parse + 1, count + 1)
    local encoded = self:encodeWord(self:loadString(textAddr + from, length), PAD_EXACT)
    local entry = self:lookup(encoded, dict)
    if entry ~= 0 or not skipUnknown then
        local slot = parse + 2 + 4 * count
        self.ram.writeWord(slot, entry)
        self.ram.writeByte(slot + 2, bit32.band(length, 0xFF))
        self.ram.writeByte(slot + 3, bit32.band(from, 0xFF))
    end
end

-- Splits the text in the buffer at `textAddr` into words and writes their
-- tokens to the parse buffer at `parse`. Dictionary 0 means the story's
-- own. With `skipUnknown`, unknown words leave their slot untouched.
function ZInput:tokenise(textAddr: number, parse: number, dict: number, skipUnknown: boolean): ()
    local memory = self.memory
    local version = self.header.version
    if dict == 0 then
        dict = self.header.dictionary
    end

    -- The word separators are read once; they are a set of ZSCII codes.
    local separators: {[number]: boolean} = {}
    for i = 1, memory:readU8(dict) do
        separators[memory:readU8(dict + i)] = true
    end

    self.ram.writeByte(parse + 1, 0)  -- discard earlier tokens

    local addr1 = textAddr
    local wordStart = 0
    local length = 0
    if version >= 5 then
        addr1 += 1
        length = memory:readU8(addr1)
    end

    local c
    repeat
        addr1 += 1
        if version >= 5 and addr1 == textAddr + 2 + length then
            c = 0
        else
            c = memory:readU8(addr1)
        end

        local isSeparator = separators[c] == true
        if not isSeparator and c ~= 32 and c ~= 0 then
            if wordStart == 0 then
                wordStart = addr1
            end
        elseif wordStart ~= 0 then
            tokeniseWord(self, textAddr, addr1 - wordStart, wordStart - textAddr, parse, dict, skipUnknown)
            wordStart = 0
        end

        -- A separator is a word in its own right.
        if isSeparator then
            tokeniseWord(self, textAddr, 1, addr1 - textAddr, parse, dict, skipUnknown)
        end
    until c == 0
end

-- Stores a line the player typed into the text buffer at `textAddr`, as
-- the tail of z_read does. `line` is UTF-8. When the line ended with
-- Return (not a timeout) it is lowercased and, if `parse` is non-zero,
-- tokenised.
--
-- V1-4: byte 0 is the buffer size and the text starts at byte 1, ended by
-- a zero. V5+: byte 0 is the capacity, byte 1 receives the length, and
-- the text starts at byte 2.
function ZInput:storeLine(textAddr: number, parse: number, line: string, endedWithReturn: boolean): ()
    local version = self.header.version
    local capacity = self.memory:readU8(textAddr)
    local limit = if version <= 4 then capacity - 1 else capacity
    if limit >= INPUT_BUFFER_SIZE then
        limit = INPUT_BUFFER_SIZE - 1
    end

    local codePoints: { number } = {}
    if utf8.len(line) then
        for _, codePoint in utf8.codes(line) do
            table.insert(codePoints, codePoint)
        end
    else
        for i = 1, #line do
            table.insert(codePoints, string.byte(line, i))
        end
    end

    local first = if version <= 4 then 1 else 2
    local count = math.min(#codePoints, math.max(limit, 0))
    for i = 1, count do
        local codePoint = codePoints[i]
        if endedWithReturn then
            codePoint = ZInput.lower(codePoint)
        end
        self.ram.writeByte(textAddr + first + i - 1, self.text:toZscii(codePoint))
    end

    if version <= 4 then
        self.ram.writeByte(textAddr + 1 + count, 0)
    else
        self.ram.writeByte(textAddr + 1, count)
    end

    if endedWithReturn and parse ~= 0 then
        self:tokenise(textAddr, parse, 0, false)
    end
end

-- The encode_text opcode: encodes `length` ZSCII characters found at
-- textAddr + offset and writes three words at `dest`. V5+ only.
function ZInput:encodeText(textAddr: number, length: number, offset: number, dest: number): ()
    local chars = self:loadString(bit32.band(textAddr + offset, 0xFFFF), length)
    local words = self:encodeWord(chars, PAD_EXACT)
    for i = 1, 3 do
        self.ram.writeWord(bit32.band(dest + 2 * (i - 1), 0xFFFF), words[i])
    end
end

return ZInput

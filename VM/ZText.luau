---------------------------------------------------------------------
-- Z-machine text: alphabets and ZSCII <-> Unicode translation.
--
-- Takes the story memory and parsed header as arguments and requires no
-- other VM module, so it can be moved into its own script later. Reads
-- of the custom alphabet and Unicode tables go through memory and may
-- yield, so everything here must run inside the VM coroutine.
--
-- Mirrors alphabet, translate_from_zscii, unicode_to_zscii and
-- translate_to_zscii (text.c), taking the USE_UTF8 branches: Unicode
-- output is not limited to Latin-1. Two deviations: the Beyond Zork
-- character remapping and the mouse-click pseudo-characters (V6) are
-- omitted.
---------------------------------------------------------------------

-- The default Unicode values of ZSCII 155-223 (the "extra characters").
-- Index = zscii - 154.
local STANDARD_EXTRA: {number} = {
    0x0E4, 0x0F6, 0x0FC, 0x0C4, 0x0D6, 0x0DC, 0x0DF, 0x0BB,
    0x0AB, 0x0EB, 0x0EF, 0x0FF, 0x0CB, 0x0CF, 0x0E1, 0x0E9,
    0x0ED, 0x0F3, 0x0FA, 0x0FD, 0x0C1, 0x0C9, 0x0CD, 0x0D3,
    0x0DA, 0x0DD, 0x0E0, 0x0E8, 0x0EC, 0x0F2, 0x0F9, 0x0C0,
    0x0C8, 0x0CC, 0x0D2, 0x0D9, 0x0E2, 0x0EA, 0x0EE, 0x0F4,
    0x0FB, 0x0C2, 0x0CA, 0x0CE, 0x0D4, 0x0DB, 0x0E5, 0x0C5,
    0x0F8, 0x0D8, 0x0E3, 0x0F1, 0x0F5, 0x0C3, 0x0D1, 0x0D5,
    0x0E6, 0x0C6, 0x0E7, 0x0C7, 0x0FE, 0x0F0, 0x0DE, 0x0D0,
    0x0A3, 0x153, 0x152, 0x0A1, 0x0BF,
}

-- Alphabet 2 when the story has no alphabet table. V1 differs.
local A2_V1 = " 0123456789.,!?_#'\"/\\<-:()"
local A2_V2 = " ^0123456789.,!?_#'\"/\\-:()"

-- Unicode characters from here up are looked up through ZSCII 155+.
local LATIN1_MIN = 0xA0
local HX_UNICODE_TABLE = 3  -- header extension table word holding it

local EMBEDDED, LOW, HIGH = 1, 2, 3  -- where a string's words come from
local MAX_ABBREVIATION_DEPTH = 8     -- Frotz recurses without a limit

export type ZText = {
    memory: any,
    header: any,
    version: number,
    alphabetTable: number,
    unicodeTable: number,
    onIllegalAddress: () -> (),
    refresh: (ZText) -> (),
    alphabet: (ZText, number, number) -> number,
    fromZscii: (ZText, number) -> number,
    toZscii: (ZText, number) -> number,
    printEmbedded: (ZText, any, any, (any) -> number) -> (),
    printLow: (ZText, any, number) -> (),
    printAt: (ZText, any, number) -> (),
}

local ZText = {}
ZText.__index = ZText

-- `onIllegalAddress` is called when a string would be read from an
-- illegal address; the opcode layer passes one that raises
-- ERR_ILL_PRINT_ADDR, keeping this module independent of ZState.
function ZText.new(memory: any, header: any, onIllegalAddress: (() -> ())?): ZText
    local self = setmetatable({
        memory = memory,
        header = header,
        version = header.version,
        alphabetTable = 0,
        unicodeTable = 0,
        onIllegalAddress = onIllegalAddress or function()
            error("illegal print address")
        end,
    }, ZText) :: any
    self:refresh()
    return self
end

-- Re-reads the story's alphabet and Unicode table pointers. Call after
-- a restart or restore, as Frotz does when it reloads the header.
function ZText:refresh(): ()
    self.alphabetTable = self.header.alphabetTable
    local extension = self.header.headerExtensionTable
    if extension ~= 0 and self.memory:readU16(extension) >= HX_UNICODE_TABLE then
        self.unicodeTable = self.memory:readU16(extension + 2 * HX_UNICODE_TABLE)
    else
        self.unicodeTable = 0
    end
end

-- Returns the Unicode code point for a Z-character `index` (0-25) in
-- alphabet `set` (0 = A0, 1 = A1, 2 = A2).
function ZText:alphabet(set: number, index: number): number
    if self.alphabetTable ~= 0 then
        return self:fromZscii(self.memory:readU8(self.alphabetTable + 26 * set + index))
    elseif set == 0 then
        return 97 + index  -- 'a'
    elseif set == 1 then
        return 65 + index  -- 'A'
    end
    return string.byte(if self.version == 1 then A2_V1 else A2_V2, index + 1)
end

-- ZSCII to Unicode. Codes below 155 are ASCII or control codes and pass
-- through. 155-251 go through the story's Unicode table if it has one,
-- otherwise the standard table (155-223 only). Anything else is '?'.
function ZText:fromZscii(zscii: number): number
    if zscii < 0x9B then
        return zscii
    end
    local unicodeTable = self.unicodeTable
    if unicodeTable ~= 0 then
        if zscii - 0x9B < self.memory:readU8(unicodeTable) then
            local unicode = self.memory:readU16(unicodeTable + 1 + 2 * (zscii - 0x9B))
            return if unicode < 0x20 then 63 else unicode
        end
        return 63
    elseif zscii <= 0xDF then
        return STANDARD_EXTRA[zscii - 0x9A]
    end
    return 63
end

-- Unicode to ZSCII, with '?' for anything the story cannot represent.
-- 0 stays 0, and code points below 160 map to themselves.
function ZText:toZscii(codePoint: number): number
    if codePoint == 0 then
        return 0
    elseif codePoint < LATIN1_MIN then
        return codePoint
    end
    local unicodeTable = self.unicodeTable
    if unicodeTable ~= 0 then
        for i = 0, self.memory:readU8(unicodeTable) - 1 do
            if self.memory:readU16(unicodeTable + 1 + 2 * i) == codePoint then
                return 0x9B + i
            end
        end
    else
        for i = 1, #STANDARD_EXTRA do
            if STANDARD_EXTRA[i] == codePoint then
                return 0x9A + i
            end
        end
    end
    return 63
end

-- Decodes one Z-string, sending characters to `out` (putChar / newLine).
-- Mirrors decode_text (text.c) except for the VOCABULARY source, which
-- only serves word completion. Each call has its own shift state, so a
-- nested abbreviation starts fresh, as in C.
--   EMBEDDED: words come from `nextWord(ctx)` (the instruction stream)
--   LOW:      `addr` is a byte address that must stay below 64K
--   HIGH:     `addr` is a full byte address (packed strings, abbreviations)
local function decode(self: ZText, out: any, source: number, addr: number,
                      nextWord: ((any) -> number)?, ctx: any, depth: number): ()
    local memory = self.memory
    local version = self.version
    local shiftState, shiftLock, status, prevC = 0, 0, 0, 0
    local code: number

    repeat
        if source == EMBEDDED then
            code = (nextWord :: (any) -> number)(ctx)
        else
            if (source == LOW and addr > 0xFFFF) or addr + 1 >= memory.storySize then
                self.onIllegalAddress()
            end
            code = memory:readU16(addr)
            addr += 2
        end

        for shift = 10, 0, -5 do
            local c = bit32.band(bit32.rshift(code, shift), 0x1F)
            if status == 0 then
                if shiftState == 2 and c == 6 then
                    status = 2                          -- ZSCII escape
                elseif version == 1 and c == 1 then
                    out:newLine()
                elseif version >= 2 and shiftState == 2 and c == 7 then
                    out:newLine()
                elseif c >= 6 then
                    out:putChar(self:alphabet(shiftState, c - 6))
                elseif c == 0 then
                    out:putChar(32)
                elseif version >= 2 and c == 1 then
                    status = 1                          -- abbreviation
                elseif version >= 3 and c <= 3 then
                    status = 1
                else
                    -- A shift character. V1-V2 codes 4 and 5 also lock.
                    shiftState = (shiftLock + bit32.band(c, 1) + 1) % 3
                    if version <= 2 and c >= 4 then
                        shiftLock = shiftState
                    end
                    prevC = c
                    continue
                end
                shiftState = shiftLock
            elseif status == 1 then
                if depth >= MAX_ABBREVIATION_DEPTH then
                    self.onIllegalAddress()
                end
                local entry = bit32.band(self.header.abbreviations + 64 * (prevC - 1) + 2 * c, 0xFFFF)
                decode(self, out, HIGH, memory:readU16(entry) * 2, nil, nil, depth + 1)
                status = 0
            elseif status == 2 then
                status = 3                              -- first half of the ZSCII code
            else
                out:putChar(self:fromZscii(bit32.bor(bit32.lshift(prevC, 5), c)))
                status = 0
            end
            prevC = c
        end
    until bit32.btest(code, 0x8000)
end

-- print: words come from the instruction stream, fetched with
-- nextWord(ctx) one at a time. Passing a method and its object, not a
-- closure, keeps print from allocating.
function ZText:printEmbedded(out: any, ctx: any, nextWord: (any) -> number): ()
    decode(self, out, EMBEDDED, 0, nextWord, ctx, 0)
end

-- print_addr / print_obj: a byte address in the lower 64K.
function ZText:printLow(out: any, addr: number): ()
    decode(self, out, LOW, addr, nil, nil, 0)
end

-- print_paddr: an already-unpacked byte address (ZState:unpackString).
function ZText:printAt(out: any, byteAddress: number): ()
    decode(self, out, HIGH, byteAddress, nil, nil, 0)
end

return ZText

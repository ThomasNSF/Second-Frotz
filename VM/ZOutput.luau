---------------------------------------------------------------------
-- Output streams for the Z-machine.
--
-- Stream 1 (screen) and stream 2 (transcript) accumulate text into a
-- reused buffer; flush() delivers it to the sink as ONE chunk, which is
-- the unit the host sees. Stream 3 redirects text into story memory
-- instead (nestable to 16 deep) and suppresses the other streams while
-- open. Mirrors stream.c and redirect.c, except that the width argument
-- of output_stream 3 is ignored: it only mattered for V6.
--
-- Requires no other VM module. Text arrives as Unicode code points or
-- UTF-8 strings; stream 3 converts to ZSCII through `toZscii`, which
-- ZText will replace with the story's real translation table.
---------------------------------------------------------------------

local MAX_REDIRECTS = 16

export type Ram = {
    readWord: (number) -> number,
    writeByte: (number, number) -> (),
    writeWord: (number, number) -> (),
}

export type ZOutput = {
    sink: (string) -> (),
    ram: Ram,
    toZscii: (number) -> number,
    screenOn: boolean,
    hidden: boolean,
    transcript: ((string) -> ())?,
    parts: {string},
    count: number,
    tables: {number},
    depth: number,
    putChar: (ZOutput, number) -> (),
    putString: (ZOutput, string) -> (),
    newLine: (ZOutput) -> (),
    flush: (ZOutput) -> (),
    setScreen: (ZOutput, boolean) -> (),
    setHidden: (ZOutput, boolean) -> (),
    setTranscript: (ZOutput, ((string) -> ())?) -> (),
    openMemory: (ZOutput, number) -> boolean,
    closeMemory: (ZOutput) -> (),
}

local ZOutput = {}
ZOutput.__index = ZOutput

-- Until ZText installs the real translation: code points below 256 pass
-- through, anything else becomes '?'.
local function defaultToZscii(codePoint: number): number
    return if codePoint < 256 then codePoint else 63
end

function ZOutput.new(sink: (string) -> (), ram: Ram): ZOutput
    return setmetatable({
        sink = sink,
        ram = ram,
        toZscii = defaultToZscii,
        screenOn = true,
        hidden = false,
        transcript = nil,
        parts = {},
        count = 0,
        tables = {},
        depth = 0,
    }, ZOutput) :: any
end

-- Appends one character to the table stream 3 currently writes into,
-- bumping the table's length word. The length wraps like a zword.
local function memoryByte(self: ZOutput, zscii: number): ()
    local tableAddr = self.tables[self.depth]
    local size = self.ram.readWord(tableAddr)
    self.ram.writeByte(bit32.band(tableAddr + 2 + size, 0xFFFF), zscii)
    self.ram.writeWord(tableAddr, bit32.band(size + 1, 0xFFFF))
end

local function addPart(self: ZOutput, text: string): ()
    if self.hidden then
        return
    end
    if self.screenOn or self.transcript then
        self.count += 1
        self.parts[self.count] = text
    end
end

-- Mirrors print_char (buffer.c): 13 is a newline and 0 prints nothing.
function ZOutput:putChar(codePoint: number): ()
    if codePoint == 13 then
        self:newLine()
    elseif codePoint == 0 then
        return
    elseif self.depth > 0 then
        memoryByte(self, self.toZscii(codePoint))
    else
        addPart(self, utf8.char(codePoint))
    end
end

function ZOutput:putString(text: string): ()
    if self.depth > 0 then
        for _, codePoint in utf8.codes(text) do
            memoryByte(self, self.toZscii(codePoint))
        end
    else
        addPart(self, text)
    end
end

-- A newline is stored as 13 in stream 3 (redirect.c); otherwise it ends
-- the chunk, so the host receives output line by line.
function ZOutput:newLine(): ()
    if self.depth > 0 then
        memoryByte(self, 13)
    else
        addPart(self, "\n")
        self:flush()
    end
end

-- Delivers everything accumulated so far as a single chunk.
function ZOutput:flush(): ()
    if self.count == 0 then
        return
    end
    local text = table.concat(self.parts, "", 1, self.count)
    table.clear(self.parts)
    self.count = 0
    if self.screenOn then
        self.sink(text)
    end
    if self.transcript then
        self.transcript(text)
    end
end

-- Stream changes flush first, as z_output_stream does, so text printed
-- before the change reaches the streams that were open when it was
-- printed.
function ZOutput:setScreen(on: boolean): ()
    self:flush()
    self.screenOn = on
end

-- Hides or shows text written to the screen and transcript streams. Used
-- while the upper window is selected on a host that cannot show it. Does
-- not affect a stream 3 redirect, which still captures the text.
function ZOutput:setHidden(hidden: boolean): ()
    self:flush()
    self.hidden = hidden
end

function ZOutput:setTranscript(sink: ((string) -> ())?): ()
    self:flush()
    self.transcript = sink
end

-- Opens a stream 3 redirect into the table at `tableAddr`, zeroing its
-- length word. Returns false when 16 are already open; the caller raises
-- the nesting error.
function ZOutput:openMemory(tableAddr: number): boolean
    if self.depth >= MAX_REDIRECTS then
        return false
    end
    self:flush()
    self.ram.writeWord(tableAddr, 0)
    self.depth += 1
    self.tables[self.depth] = tableAddr
    return true
end

function ZOutput:closeMemory(): ()
    if self.depth > 0 then
        self.tables[self.depth] = nil
        self.depth -= 1
    end
end

return ZOutput

---------------------------------------------------------------------
-- The Text Service: everything the player sees and types, as a plain
-- object with no transport. Built from the story memory, a ZHost, and the
-- text modules (ZText, ZOutput, ZInput). The core talks to it through
-- four calls: `out` (a batch of output entries), `request` (a
-- synchronous operation), `reset` and `finish`. See docs/TEXT_SERVICE.md.
--
-- The link-message script and the in-process loopback used by tests both
-- wrap this object. It requires neither ZState nor ZOpcodes: error codes
-- are repeated below and checked against ZState.Errors by a test.
--
-- Everything here runs in a coroutine, since reads may yield and ROM
-- reads may fault pages in.
--
-- Memory coherence (docs/TEXT_SERVICE.md, rules R1-R3): when the memory
-- is not shared with the core in the same script, each call starts by
-- dropping the cached RAM pages and ends by writing back any changes, and
-- replies say whether RAM was written (`wroteRam`) so the core can drop
-- its own cache. With `sharedMemory = true` the memory object is the
-- core's own, so there is no second cache and none of that is needed.
---------------------------------------------------------------------

local ZText = require("ZText.luau")
local ZOutput = require("ZOutput.luau")
local ZInput = require("ZInput.luau")
local ZHost = require("ZHost.luau")

-- Error codes the service can raise, matching ZState.Errors.
local ERR_STR3_NESTING = 15
local ERR_ILL_WIN = 16
local ERR_ILL_PRINT_ADDR = 18

local MESSAGES: {[number]: string} = {
    [ERR_STR3_NESTING] = "Nesting stream #3 too deep",
    [ERR_ILL_WIN] = "Illegal window",
    [ERR_ILL_PRINT_ADDR] = "Print at illegal address",
}

local DEFAULT_SCREEN_ROWS = 24
local DEFAULT_SCREEN_COLS = 80

export type Screen = {
    window: number,
    upperHeight: number,
    cursors: { { number } },  -- indexed by window + 1: {row, column}, from 1
    font: number,
}

export type Options = { sharedMemory: boolean? }

export type TextService = {
    host: any,
    memory: any,
    shared: boolean,
    wrote: boolean,
    header: any,
    text: any,
    output: any,
    input: any,
    screen: Screen,
    config: (TextService, any?) -> { [string]: any },
    out: (TextService, { { any } }) -> (any, boolean),
    request: (TextService, string, { [string]: any }?, { { any } }?) -> { [string]: any },
    reset: (TextService) -> (),
    finish: (TextService, string, any?) -> (),
}

local TextService = {}
TextService.__index = TextService

TextService.ERR_STR3_NESTING = ERR_STR3_NESTING
TextService.ERR_ILL_WIN = ERR_ILL_WIN
TextService.ERR_ILL_PRINT_ADDR = ERR_ILL_PRINT_ADDR

local function newScreen(): Screen
    return { window = 0, upperHeight = 0, cursors = { { 1, 1 }, { 1, 1 } }, font = 1 }
end

local function raise(code: number): ()
    error({ fatal = true, code = code, message = MESSAGES[code] or ("error " .. code) })
end

-- Turns whatever was raised into an error table with a code, or a fault
-- (a bug rather than a Z-machine error) with code 0.
local function asError(err: any): any
    if typeof(err) == "table" and err.code ~= nil then
        return err
    end
    return { fatal = true, code = 0, fault = true, message = tostring(err) }
end

-- Code points that are never emitted: control codes (the Z-machine
-- standard says they must not be used) and values that are not valid
-- UTF-8 scalars (surrogates, U+FFFE and U+FFFF).
local function isUnprintable(c: number): boolean
    return c < 0x20 or (c >= 0x7F and c <= 0x9F)
        or (c >= 0xD800 and c <= 0xDFFF) or c >= 0xFFFE
end

function TextService.new(host: any, memory: any, options: Options?): TextService
    ZHost.validate(host)
    return setmetatable({
        host = host,
        memory = memory,
        shared = options ~= nil and options.sharedMemory == true,
        wrote = false,
        screen = newScreen(),
    }, TextService) :: any
end

----------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------

-- Starts a call: forget RAM that another script may have changed.
local function begin(self: TextService): ()
    self.wrote = false
    if not self.shared then
        self.memory:invalidateRam()
    end
end

-- Ends a call: publish anything this script wrote.
local function complete(self: TextService): ()
    if not self.shared then
        self.memory:flush()
    end
end

-- (Re)reads the header and builds the text objects over it.
local function build(self: TextService): ()
    local memory = self.memory
    local header = memory:readHeader()
    local ram = {
        readWord = function(addr: number): number
            return memory:readU16(addr)
        end,
        writeByte = function(addr: number, value: number)
            memory:writeU8(addr, value)
            self.wrote = true
        end,
        writeWord = function(addr: number, value: number)
            memory:writeU16(addr, value)
            self.wrote = true
        end,
    }
    local text = ZText.new(memory, header, function()
        raise(ERR_ILL_PRINT_ADDR)
    end)
    local output = ZOutput.new(function(chunk: string)
        self.host:write(chunk)
    end, ram)
    output.toZscii = function(codePoint: number): number
        return text:toZscii(codePoint)
    end
    self.header = header
    self.text = text
    self.output = output
    self.input = ZInput.new(memory, header, text, ram)
    self.screen = newScreen()
end

-- Prepares the service for a story. `cfg` is the TS_CONFIG payload
-- (pageSize, storySize, staticBase, ramPrefix) when the memory has to be
-- attached to a story loaded by another script; without it the memory is
-- used as it is. Returns the screen size the host offers.
function TextService:config(cfg: any?): { [string]: any }
    begin(self)
    local ok, err = pcall(function()
        if cfg ~= nil and cfg.pageSize ~= nil then
            self.memory:attach({
                pageSize = cfg.pageSize,
                storySize = cfg.storySize,
                staticBase = cfg.staticBase,
                ramPrefix = cfg.ramPrefix,
            })
        end
        begin(self)
        build(self)
    end)
    complete(self)
    if not ok then
        local e = asError(err)
        return { ok = false, error = e.code, message = e.message }
    end
    return {
        ok = true,
        screenRows = self.host.screenRows or DEFAULT_SCREEN_ROWS,
        screenCols = self.host.screenCols or DEFAULT_SCREEN_COLS,
    }
end

-- After a restart: a fresh screen and fresh stream state over the
-- reloaded header.
function TextService:reset(): ()
    begin(self)
    if self.output ~= nil then
        self.output:flush()
    end
    build(self)
    complete(self)
end

-- The story ended or failed: send what is pending and tell the host.
function TextService:finish(reason: string, err: any?): ()
    if self.output ~= nil then
        self.output:flush()
    end
    if reason == "fatal" then
        self.host:fatal(err)
    else
        self.host:quit()
    end
end

----------------------------------------------------------------------
-- Output entries
----------------------------------------------------------------------

local function selectWindow(self: TextService, window: number): ()
    self.output:flush()
    local screen = self.screen
    screen.window = window
    if window == 1 then
        screen.cursors[2] = { 1, 1 }
    end
    if self.host.setWindow then
        self.host:setWindow(window)
    else
        -- A host that cannot show the upper window loses its text.
        self.output:setHidden(window ~= 0)
    end
end

-- Window and screen operations: {"w", op, b, c}. Mirrors the screen
-- opcodes in screen.c for non-V6 stories, text only.
local function windowOp(self: TextService, op: string, optionalB: number?, optionalC: number?): ()
    local host, screen, output = self.host, self.screen, self.output
    -- Entries always carry their numbers; the defaults only satisfy the
    -- type checker.
    local b: number, c: number = optionalB or 0, optionalC or 0
    if op == "split" then
        output:flush()
        screen.upperHeight = b
        if host.splitWindow then
            host:splitWindow(b)
        end
    elseif op == "set" then
        if b < 0 or b >= 2 then
            raise(ERR_ILL_WIN)
        end
        selectWindow(self, b)
    elseif op == "erase" then
        output:flush()
        if b == -1 or b == -2 then
            if b == -1 then
                screen.upperHeight = 0
                if host.splitWindow then
                    host:splitWindow(0)
                end
                selectWindow(self, 0)
            end
            if host.eraseWindow then
                host:eraseWindow(b)
            end
        else
            if b < 0 or b >= 2 then
                raise(ERR_ILL_WIN)
            end
            if host.eraseWindow then
                host:eraseWindow(b)
            end
        end
    elseif op == "eraseline" then
        output:flush()
        if host.eraseLine then
            host:eraseLine(b)
        end
    elseif op == "cursor" then
        -- Cursor addressing only applies to the upper window; a negative
        -- row turns the cursor on or off, which has no visible effect.
        output:flush()
        local row, column = b, c
        if row < 0 or screen.window == 0 then
            return
        end
        local cursor = screen.cursors[2]
        if row == 0 then
            row = cursor[1]
        end
        if column == 0 then
            column = cursor[2]
        end
        cursor[1], cursor[2] = row, column
        if host.setCursor then
            host:setCursor(row, column)
        end
    elseif op == "style" then
        output:flush()
        if host.setTextStyle then
            host:setTextStyle(b)
        end
    elseif op == "colour" then
        output:flush()
        if host.setColour then
            host:setColour(b, c)
        end
    elseif op == "buffer" then
        output:flush()
    else
        error("unknown window operation: " .. tostring(op))
    end
end

local function selectStream(self: TextService, stream: number): ()
    if stream == 1 then
        self.output:setScreen(true)
    elseif stream == -1 then
        self.output:setScreen(false)
    end
    -- Streams 2 and -2 (transcript) and 4 (input record) are not offered.
end

-- Feeds the words of a Z-string the core copied out of dynamic memory to
-- ZText's embedded-string decoder. A missing word ends the string with
-- 0x94A5, the empty Z-string (two shifts and a third, with the end bit),
-- which prints nothing.
local function nextInlineWord(ctx: any): number
    ctx.index += 1
    return ctx.words[ctx.index] or 0x94A5
end

-- The location name for a status line, as text: given ready-made, or
-- decoded from the object name's words.
local function statusName(self: TextService, status: any): string
    if status.name ~= nil then
        return status.name
    end
    if status.words == nil or #status.words == 0 then
        return ""
    end
    local parts: { string } = {}
    local sink = {
        putChar = function(_, codePoint: number)
            table.insert(parts, utf8.char(codePoint))
        end,
        newLine = function()
            table.insert(parts, " ")
        end,
    }
    self.text:printEmbedded(sink, { index = 0, words = status.words }, nextInlineWord)
    return table.concat(parts)
end

-- V1-V3 status line: hands the host the location and the two numbers if it
-- can show a status line; otherwise does nothing.
local function showStatus(self: TextService, status: any): ()
    if self.host.statusLine then
        self.host:statusLine(statusName(self, status), status.first, status.second, status.isTime)
    end
end

local function runEntry(self: TextService, entry: { any }): ()
    local kind = entry[1]
    local output = self.output
    if kind == "s" then
        self.text:printAt(output, entry[2])
    elseif kind == "z" then
        self.text:printEmbedded(output, { index = 0, words = entry[2] }, nextInlineWord)
    elseif kind == "st" then
        showStatus(self, entry[2])
    elseif kind == "t" then
        output:putString(entry[2])
    elseif kind == "c" then
        -- One or more ZSCII codes: the core combines runs of characters.
        for i = 2, #entry do
            output:putChar(self.text:fromZscii(entry[i]))
        end
    elseif kind == "u" then
        for i = 2, #entry do
            local codePoint = entry[i]
            output:putChar(if isUnprintable(codePoint) then 63 else codePoint)
        end
    elseif kind == "n" then
        output:putString(tostring(entry[2]))
    elseif kind == "nl" then
        output:newLine()
    elseif kind == "w" then
        windowOp(self, entry[2], entry[3], entry[4])
    elseif kind == "o" then
        selectStream(self, entry[2])
    else
        error("unknown output entry: " .. tostring(kind))
    end
end

local function runEntries(self: TextService, entries: { { any } }): ()
    for _, entry in entries do
        runEntry(self, entry)
    end
end

-- Processes an output batch in order. Returns an error table if one was
-- hit (the rest of the batch is skipped), and whether RAM was written.
function TextService:out(entries: { { any } }): (any, boolean)
    if self.text == nil then
        return { fatal = true, code = 0, fault = true, message = "the Text Service is not configured" }, false
    end
    begin(self)
    local ok, err = pcall(runEntries, self, entries)
    complete(self)
    if ok then
        return nil, self.wrote
    end
    return asError(err), self.wrote
end

----------------------------------------------------------------------
-- Synchronous requests
----------------------------------------------------------------------

type Args = { [string]: any }
type Reply = { [string]: any }

-- Reads a line into the story's text buffer and tokenises it. Mirrors the
-- input half of z_read (input.c). A timeout stores nothing: the core runs
-- the story's routine and either asks again or sends read_end.
local function opRead(self: TextService, args: Args): Reply
    local version = self.header.version
    local capacity = self.memory:readU8(args.text)
    local max = math.min(
        if version <= 4 then capacity - 1 else capacity,
        ZInput.INPUT_BUFFER_SIZE - 1)

    if args.status ~= nil then
        showStatus(self, args.status)
    end

    self.output:flush()
    local line, timedOut = self.host:readLine(max, args.timeout or 0)
    if timedOut then
        return { status = "timeout" }
    end
    self.input:storeLine(args.text, args.parse or 0, line, true)
    return { status = "line", key = 13 }
end

-- Ends a read that a timeout routine cancelled: an empty text buffer and
-- no tokens, terminating key 0.
local function opReadEnd(self: TextService, args: Args): Reply
    self.input:storeLine(args.text, 0, "", false)
    return { key = 0 }
end

-- Reads one key (the first character of a line on a chat host) and
-- replies with its ZSCII code. Mirrors z_read_char (input.c).
local function opReadChar(self: TextService, args: Args): Reply
    self.output:flush()
    local char, timedOut = self.host:readChar(args.timeout or 0)
    if timedOut then
        return { status = "timeout" }
    end
    if char == "" or char == "\n" then
        return { status = "key", value = 13 }
    end
    return { status = "key", value = self.text:toZscii(utf8.codepoint(char, 1)) }
end

local function opTokenise(self: TextService, args: Args): Reply
    self.input:tokenise(args.text, args.parse, args.dict or 0, args.skip == true)
    return {}
end

local function opEncodeText(self: TextService, args: Args): Reply
    self.input:encodeText(args.text, args.length, args.offset, args.dest)
    return {}
end

-- Prints `height` rows of `width` ZSCII characters from a table, with a
-- newline between rows and `skip` bytes skipped after each row. Mirrors
-- z_print_table (screen.c) for the lower window.
local function opPrintTable(self: TextService, args: Args): Reply
    local addr = args.addr
    local height = args.height or 1
    local skip = args.skip or 0
    for row = 0, height - 1 do
        if row ~= 0 then
            self.output:newLine()
        end
        for _ = 1, args.width do
            self.output:putChar(self.text:fromZscii(self.memory:readU8(addr)))
            addr = bit32.band(addr + 1, 0xFFFF)
        end
        addr = bit32.band(addr + skip, 0xFFFF)
    end
    return {}
end

local function opGetCursor(self: TextService, _args: Args): Reply
    self.output:flush()
    if self.host.getCursor then
        local row, column = self.host:getCursor()
        return { row = row, column = column }
    end
    local cursor = self.screen.cursors[self.screen.window + 1]
    return { row = cursor[1], column = cursor[2] }
end

-- Replies with the previous font, or 0 if the requested font is not
-- available; font 0 only asks for the current one. Mirrors z_set_font.
local function opSetFont(self: TextService, args: Args): Reply
    local font = args.font
    local screen = self.screen
    if font == 0 then
        return { value = screen.font }
    end
    self.output:flush()
    local previous
    if self.host.setFont then
        previous = self.host:setFont(font)
    else
        previous = if font == 1 then screen.font else 0
    end
    if previous ~= 0 then
        screen.font = font
    end
    return { value = previous }
end

-- Opens (n = 3, with the table address) or closes (n = -3) a stream 3
-- redirect. Text printed meanwhile is written into the table, so RAM
-- counts as written.
local function opStream(self: TextService, args: Args): Reply
    if args.n == 3 then
        if not self.output:openMemory(args.table) then
            raise(ERR_STR3_NESTING)
        end
    else
        self.output:closeMemory()
    end
    self.wrote = true
    return {}
end

-- Everything sent earlier has been handled by the time this runs, so it
-- only has to push the pending text to the host.
local function opFlush(self: TextService, _args: Args): Reply
    self.output:flush()
    return {}
end

-- Stores bit 0 = can be printed, bit 1 = can be read, for a Unicode code
-- point. The host is assumed able to print any valid character, so
-- readability (a ZSCII mapping) decides between 3 and 1. Mirrors
-- z_check_unicode (text.c) with the USE_UTF8 branch; ZText:toZscii returns
-- '?' where C returns 0.
local function opCheckUnicode(self: TextService, args: Args): Reply
    local c = args.c
    if isUnprintable(c) then
        return { value = 0 }
    elseif c <= 0x7E then
        return { value = 3 }
    elseif c == 0xA0 then
        return { value = 1 }
    end
    return { value = if self.text:toZscii(c) ~= 63 then 3 else 1 }
end

local REQUESTS: {[string]: (TextService, Args) -> Reply} = {
    check_unicode = opCheckUnicode,
    read = opRead,
    read_end = opReadEnd,
    read_char = opReadChar,
    tokenise = opTokenise,
    encode_text = opEncodeText,
    print_table = opPrintTable,
    get_cursor = opGetCursor,
    set_font = opSetFont,
    stream = opStream,
    flush = opFlush,
    barrier = opFlush,
}

-- Handles `pre` (output entries that came with the request) and then the
-- operation, and replies. The reply carries `error` (a Z-machine error
-- code) or `fault` (a bug) if something went wrong, and `wroteRam`.
function TextService:request(op: string, args: Args?, pre: { { any } }?): Reply
    if self.text == nil then
        return { fault = "the Text Service is not configured", wroteRam = false }
    end
    begin(self)
    local ok, result = pcall(function()
        if pre ~= nil then
            runEntries(self, pre)
        end
        local handler = REQUESTS[op]
        if handler == nil then
            return { fault = "unknown request: " .. tostring(op) }
        end
        return handler(self, args or {})
    end)
    complete(self)

    local reply: Reply
    if ok then
        reply = result
    else
        local e = asError(result)
        reply = if e.fault then { fault = e.message } else { error = e.code, message = e.message }
    end
    reply.wroteRam = self.wrote
    return reply
end

return TextService

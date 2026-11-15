---------------------------------------------------------------------
-- Opcode dispatch for the Luau Z-machine interpreter.
--
-- Owns operand decoding, the four opcode tables backing the five
-- instruction forms, and the per-instruction handlers as they're added
-- across later Phase 4 slices.
--
-- 2OP and VAR share one table (`var`), not two: 2OP opcodes 0-31 are the
-- same operations as VAR opcodes 0xC0-0xDF with different operand
-- encodings (see process.c's dispatch). This is not an odd design choice
-- to normalize away; keep them merged.
--
-- Each table literal below is the single source of truth for what that
-- opcode currently dispatches to -- no separate override statements.
-- Handler functions are defined in groups, each group immediately before
-- the table that references it, so a table's dependencies (e.g. `ext`
-- for `extended`) already exist by the time it's built.
---------------------------------------------------------------------

local ZState = require("ZState.luau")
local ZObject = require("ZObject.luau")

local ERR_ILL_OPCODE = ZState.Errors.ILL_OPCODE
local ERR_ILL_JUMP_ADDR = ZState.Errors.ILL_JUMP_ADDR
local ERR_ILL_PRINT_ADDR = ZState.Errors.ILL_PRINT_ADDR
local Warnings = ZState.Warnings

export type Handler = (ZState.ZState) -> ()

local ZOpcodes = {}

-- Handler for table slots that no Z-machine version defines (2OP number
-- 0, VAR 0x1D-0x1F, EXT 0x0E-0x0F).
local function illegal(state: ZState.ZState): ()
    state:runtimeError(ERR_ILL_OPCODE)
end

-- Builds the handler for a valid opcode this port does not provide: V6
-- graphics, mouse and menus, and the features still to come (save/restore
-- and the screen and input opcodes). Raises ERR_UNSUPPORTED naming it.
-- Each handler is recorded in `unsupportedNames` so the table audit can
-- tell these slots from real ones.
local unsupportedNames: {[Handler]: string} = {}
local function unsupported(name: string): Handler
    local handler = function(state: ZState.ZState): ()
        state:unsupportedOpcode(name)
    end
    unsupportedNames[handler] = name
    return handler
end

-- Undo is not available: save_undo stores -1 ("not supported"), which
-- stories report as a failed undo. Mirrors z_save_undo with no undo
-- buffer (fastmem.c).
local function z_save_undo(state: ZState.ZState): ()
    state:store(0xFFFF)
end

local function z_restore_undo(state: ZState.ZState): ()
    state:store(0)
end

----------------------------------------------------------------------
-- Operand decoding
----------------------------------------------------------------------

-- Operand type codes, from the 2-bit fields in an operand specifier byte.
local OPERAND_LARGE_CONSTANT = 0
local OPERAND_SMALL_CONSTANT = 1
local OPERAND_VARIABLE = 2
local OPERAND_OMITTED = 3

-- Loads one operand into state.zargs and advances zargc. Mirrors
-- load_operand (process.c) -- called both directly, twice, for the 2OP
-- long form's two single-bit operand types, and in a loop by
-- loadAllOperands for VAR/EXT's 2-bit-per-operand specifier byte. Never
-- called with OPERAND_OMITTED; loadAllOperands filters that out before
-- calling.
--
-- Does not reset zargc -- that's step()'s job (4.1.5), once per
-- instruction, before any operand loading starts. Leaving it alone here
-- is what lets the two-specifier 8-argument call opcodes (0xEC, 0xFA)
-- accumulate operands across two loadAllOperands calls into one zargs.
local function loadOperand(state: ZState.ZState, operandType: number): ()
    local value: number
    if operandType == OPERAND_LARGE_CONSTANT then
        value = state:codeWord()
    elseif operandType == OPERAND_SMALL_CONSTANT then
        value = state:codeByte()
    elseif operandType == OPERAND_VARIABLE then
        value = state:readVariable(state:codeByte())
    else
        -- OPERAND_OMITTED never reaches here -- loadAllOperands filters
        -- it out before calling, and the 2OP long form only ever passes
        -- SMALL_CONSTANT or VARIABLE directly. A caller bug, not a
        -- Z-machine runtime error.
        error("loadOperand called with an invalid operand type: " .. tostring(operandType))
    end

    state.zargc += 1
    state.zargs[state.zargc] = value
end

-- Reads a VAR/EXT-form specifier byte and loads up to four operands,
-- stopping at the first OPERAND_OMITTED field. Mirrors
-- load_all_operands (process.c): four 2-bit type fields, most
-- significant pair first.
local function loadAllOperands(state: ZState.ZState, specifier: number): ()
    for shift = 6, 0, -2 do
        local operandType = bit32.band(bit32.rshift(specifier, shift), 0x03)
        if operandType == OPERAND_OMITTED then
            break
        end
        loadOperand(state, operandType)
    end
end

----------------------------------------------------------------------
-- Shared memory helpers
----------------------------------------------------------------------

local ERR_STORE_RANGE = ZState.Errors.STORE_RANGE

-- Header address of the flags word; a write to its low byte (16 + 1)
-- must reach ZState:writeHeaderFlags so the shadow copy stays in sync.
local H_FLAGS = 16

-- Writes one byte to dynamic memory. Mirrors storeb (fastmem.c):
-- anything at or above the static-memory boundary is ERR_STORE_RANGE
-- (checked first, so an address past the end of the story raises the
-- proper error rather than ZMemory's address assert), and a write to the
-- flags register's low byte goes through writeHeaderFlags.
local function storeByte(state: ZState.ZState, addr: number, value: number): ()
    if addr >= state.header.staticMemoryBase then
        state:runtimeError(ERR_STORE_RANGE)
    end

    -- A write into one of the tables the Text Service decodes text with
    -- (alphabet, abbreviations, Unicode): text sent so far must be
    -- decoded with the old contents, and the new contents must reach
    -- LinksetData before the next message (rule R6).
    local textClient = state.textClient
    local watched = textClient ~= nil and textClient:isWatched(addr)
    if watched then
        textClient:barrier()
    end

    if addr == H_FLAGS + 1 then
        local highByte = bit32.band(state.memory:readU16(H_FLAGS), 0xFF00)
        state:writeHeaderFlags(bit32.bor(highByte, value))
    else
        state.memory:writeU8(addr, value)
    end

    if watched then
        state.memory:flush()
    end
end

-- Writes a big-endian word as two storeByte calls, wrapping the second
-- address at 16 bits like C's (zword)(addr + 1). Mirrors storew
-- (fastmem.c). As in C, if the second byte is out of range the first
-- has already been written.
local function storeWord(state: ZState.ZState, addr: number, value: number): ()
    storeByte(state, addr, bit32.rshift(value, 8))
    storeByte(state, bit32.band(addr + 1, 0xFFFF), bit32.band(value, 0xFF))
end

----------------------------------------------------------------------
-- Stack (EXT): user-stack bookkeeping needed before the ext table
----------------------------------------------------------------------

-- Discards zargs[1] values from a stack: the user stack named by
-- zargs[2] if two operands were given, otherwise the game stack.
-- Mirrors z_pop_stack (variable.c). The game-stack branch matches C's
-- unchecked `sp += zargs[0]` exactly -- no bounds validation, same as
-- the reference.
local function z_pop_stack(state: ZState.ZState): ()
    if state.zargc == 2 then
        local addr = state.zargs[2]
        local size = state.memory:readU16(addr) + state.zargs[1]
        storeWord(state, addr, size)
    else
        state.sp += state.zargs[1]
    end
end

-- Pushes zargs[1] onto the user stack at zargs[2], then branches on
-- whether a free slot existed. Mirrors z_push_stack (variable.c).
--
-- Note the branch value is the free-slot count AFTER the push, not a
-- clean success flag: pushing into the very last free slot decrements
-- that count to 0, so branch(false) fires even though the push
-- succeeded. This looks backwards but is exactly what the reference
-- does, so it's preserved rather than "fixed."
local function z_push_stack(state: ZState.ZState): ()
    local addr = state.zargs[2]
    local size = state.memory:readU16(addr)
    if size ~= 0 then
        storeWord(state, addr + 2 * size, state.zargs[1])
        size -= 1
        storeWord(state, addr, size)
    end
    state:branch(size ~= 0)
end

----------------------------------------------------------------------
-- Shifts (EXT)
----------------------------------------------------------------------

-- Logical shift: positive count shifts left, zero or negative shifts
-- right, zero-filling. The value is unsigned. Mirrors z_log_shift
-- (math.c). Left shifts wrap to 16 bits like C's (zword) cast.
local function z_log_shift(state: ZState.ZState): ()
    local places = ZState.toS16(state.zargs[2])
    if places > 0 then
        state:store(bit32.band(bit32.lshift(state.zargs[1], places), 0xFFFF))
    else
        state:store(bit32.rshift(state.zargs[1], -places))
    end
end

-- Arithmetic shift: same count convention, but the value is signed and
-- right shifts sign-extend. Arithmetic right shift is exactly floor
-- division by 2^n, which is exact for any 16-bit value. Mirrors
-- z_art_shift (math.c).
local function z_art_shift(state: ZState.ZState): ()
    local value = ZState.toS16(state.zargs[1])
    local places = ZState.toS16(state.zargs[2])
    if places > 0 then
        state:store(ZState.toU16(value * 2 ^ places))
    else
        state:store(ZState.toU16(math.floor(value / 2 ^ -places)))
    end
end

----------------------------------------------------------------------
-- Text, input and screen: the core's side of the Text Service
----------------------------------------------------------------------

-- Nothing in this section decodes or prints text. Output opcodes hand
-- state.textClient small entries to be sent in batches; opcodes that need
-- an answer (reading, tokenising, the cursor, fonts) make a synchronous
-- request. The Text Service owns ZText, ZOutput, ZInput, the host and the
-- screen model. See docs/TEXT_SERVICE.md.

local ERR_ILL_WIN = ZState.Errors.ILL_WIN

-- Header flags1 bit that says V3 games show the time, not score and moves.
local CONFIG_TIME = 0x02

local function client(state: ZState.ZState): any
    local textClient = state.textClient
    if textClient == nil then
        error("no text client is attached to the state")
    end
    return textClient
end

-- Rejects a string address the Text Service could not read from. A ROM
-- string is checked at its start only; one that runs off the end of the
-- story is reported when the Text Service decodes it.
local function checkPrintAddress(state: ZState.ZState, addr: number, low: boolean): ()
    if (low and addr > 0xFFFF) or addr + 1 >= state.memory.storySize then
        state:runtimeError(ERR_ILL_PRINT_ADDR)
    end
end

-- An output entry for the Z-string at a byte address. A string in ROM is
-- sent by address and read by the Text Service itself. A string in
-- dynamic memory is copied now, word by word up to the end bit, so it
-- prints as it was at this moment even though the printing happens later.
-- `low` marks the 64K-limited addresses of print_addr and print_obj.
local function stringEntry(state: ZState.ZState, addr: number, low: boolean): { any }
    local memory = state.memory
    if addr >= memory.staticMemoryBase then
        return { "s", addr }
    end
    local words: { number } = {}
    local at = addr
    repeat
        checkPrintAddress(state, at, low)
        local word = memory:readU16(at)
        table.insert(words, word)
        at += 2
    until bit32.btest(word, 0x8000)
    return { "z", words }
end

-- Prints a Unicode code point directly, bypassing ZSCII translation. The
-- Text Service replaces control codes and invalid code points with '?'.
-- Mirrors z_print_unicode (text.c).
local function z_print_unicode(state: ZState.ZState): ()
    client(state):queue({ "u", state.zargs[1] })
end

-- Stores bit 0 = can be printed, bit 1 = can be read; the Text Service
-- answers. Mirrors z_check_unicode (text.c).
local function z_check_unicode(state: ZState.ZState): ()
    state:store(client(state):request("check_unicode", { c = state.zargs[1] }).value)
end

-- Stores the previous font, or 0 if the requested font is not available.
-- Mirrors z_set_font (screen.c).
local function z_set_font(state: ZState.ZState): ()
    state:store(client(state):request("set_font", { font = state.zargs[1] }).value)
end

-- Options that have no effect on a text-only host.
local function ignore(_state: ZState.ZState): ()
end
local z_set_true_colour = ignore
local z_input_stream = ignore
local z_sound_effect = ignore

-- Prints one ZSCII character; only the low byte counts. Mirrors
-- z_print_char (text.c).
local function z_print_char(state: ZState.ZState): ()
    client(state):queue({ "c", bit32.band(state.zargs[1], 0xFF) })
end

-- Prints a signed number. Mirrors z_print_num / print_num (text.c).
local function z_print_num(state: ZState.ZState): ()
    client(state):queue({ "n", ZState.toS16(state.zargs[1]) })
end

local function z_new_line(state: ZState.ZState): ()
    client(state):queue({ "nl" })
end

-- Queues the string that follows the opcode in the instruction stream,
-- leaving the PC past it. The core finds the end by scanning for the end
-- bit; it does not decode anything. Mirrors z_print (text.c).
local function printEmbedded(state: ZState.ZState): ()
    local start = state.pc
    local dynamic = start < state.memory.staticMemoryBase
    local words: { number } = {}
    repeat
        local word = state:codeWord()
        if dynamic then
            table.insert(words, word)
        end
    until bit32.btest(word, 0x8000)
    client(state):queue(if dynamic then { "z", words } else { "s", start })
end

local function z_print(state: ZState.ZState): ()
    printEmbedded(state)
end

-- Prints the embedded string, a newline, and returns true. Mirrors
-- z_print_ret (text.c).
local function z_print_ret(state: ZState.ZState): ()
    printEmbedded(state)
    client(state):queue({ "nl" })
    state:ret(1)
end

-- Prints the string at a byte address in the lower 64K. Mirrors
-- z_print_addr (text.c).
local function z_print_addr(state: ZState.ZState): ()
    local addr = state.zargs[1]
    checkPrintAddress(state, addr, true)
    client(state):queue(stringEntry(state, addr, true))
end

-- Prints the string at a packed address. Mirrors z_print_paddr (text.c).
local function z_print_paddr(state: ZState.ZState): ()
    local addr = state:unpackString(state.zargs[1])
    checkPrintAddress(state, addr, false)
    client(state):queue(stringEntry(state, addr, false))
end

-- Prints an object's short name. An empty name prints nothing; the
-- placeholder 0x94A5 (an empty encoded string) prints "object#N". The
-- name lives in the object table, so its words are copied now. Mirrors
-- print_object (text.c).
local function z_print_obj(state: ZState.ZState): ()
    local obj = state.zargs[1]
    local memory = state.memory
    local nameAddr = ZObject.nameAddress(state, obj)
    local count = memory:readU8(nameAddr)
    if count == 0 then
        return
    end
    if memory:readU16(nameAddr + 1) == 0x94A5 then
        client(state):queue({ "t", "object#" .. obj })
        return
    end
    local words: { number } = {}
    for i = 0, count - 1 do
        words[i + 1] = memory:readU16(nameAddr + 1 + 2 * i)
    end
    client(state):queue({ "z", words })
end

-- Selects or deselects an output stream. Streams 1 and -1 (the screen)
-- are output entries; 3 and -3 (a table in memory) are requests, since
-- the Text Service writes into RAM while one is open. Stream 2
-- (transcript) and 4 (input record) are not offered. Mirrors
-- z_output_stream (stream.c).
local function z_output_stream(state: ZState.ZState): ()
    local textClient = client(state)
    local stream = ZState.toS16(state.zargs[1])
    if stream == 1 or stream == -1 then
        textClient:queue({ "o", stream })
    elseif stream == 3 then
        local tableAddr = state.zargs[2]
        if tableAddr + 1 >= state.header.staticMemoryBase then
            state:runtimeError(ERR_STORE_RANGE)
        end
        textClient:request("stream", { n = 3, table = tableAddr })
        textClient:setRedirect(1)
    elseif stream == -3 then
        textClient:request("stream", { n = -3 })
        textClient:setRedirect(-1)
    end
end

-- Prints `height` rows of `width` ZSCII characters from a table. The Text
-- Service reads the table from RAM, so this is a request. Mirrors
-- z_print_table (screen.c).
local function z_print_table(state: ZState.ZState): ()
    local zargs, argc = state.zargs, state.zargc
    client(state):request("print_table", {
        addr = zargs[1],
        width = zargs[2],
        height = if argc >= 3 then zargs[3] else 1,
        skip = if argc >= 4 then zargs[4] else 0,
    })
end

-- The location name's words and the two numbers a V1-V3 status line
-- shows, for the Text Service to hand to a host that has one.
local function statusInfo(state: ZState.ZState): { [string]: any }
    local memory = state.memory
    local globals = state.header.globals
    local location = memory:readU16(globals)
    local words: { number } = {}
    if location ~= 0 then
        local nameAddr = ZObject.nameAddress(state, location)
        for i = 0, memory:readU8(nameAddr) - 1 do
            words[i + 1] = memory:readU16(nameAddr + 1 + 2 * i)
        end
    end
    return {
        words = words,
        first = memory:readU16(globals + 2),
        second = memory:readU16(globals + 4),
        isTime = bit32.band(state.header.flags1, CONFIG_TIME) ~= 0,
    }
end

-- Mirrors z_show_status (screen.c); only V1-V3 have a status line.
local function z_show_status(state: ZState.ZState): ()
    if state.header.version >= 4 then
        return
    end
    client(state):queue({ "st", statusInfo(state) })
end

-- Calls the story's timeout routine. Returns true if it asked for the
-- input to end. A routine address of 0 is a call that returns false.
local function timeoutEndsInput(state: ZState.ZState, routine: number): boolean
    if routine == 0 then
        return false
    end
    return state.directCall(routine) ~= 0
end

-- Reads a line into the story's text buffer and tokenises it; the Text
-- Service does the reading and fills the buffers. A timeout runs the
-- story's routine: 0 means keep waiting, anything else ends the input
-- with key 0. Mirrors z_read (input.c).
local function z_read(state: ZState.ZState): ()
    local zargs, argc = state.zargs, state.zargc
    local textClient = client(state)
    local text = zargs[1]
    local args = {
        text = text,
        parse = zargs[2],
        timeout = if argc >= 3 then zargs[3] else 0,
    }
    local routine = if argc >= 4 then zargs[4] else 0
    local version = state.header.version
    if version <= 3 then
        args.status = statusInfo(state)
    end

    local reply
    while true do
        reply = textClient:request("read", args)
        if reply.status ~= "timeout" then
            break
        end
        if timeoutEndsInput(state, routine) then
            reply = textClient:request("read_end", { text = text })
            break
        end
    end
    if version >= 5 then
        state:store(reply.key)
    end
end

-- Reads one key and stores its ZSCII code (0 after a timeout). Mirrors
-- z_read_char (input.c).
local function z_read_char(state: ZState.ZState): ()
    local zargs, argc = state.zargs, state.zargc
    local textClient = client(state)
    local timeout = if argc >= 2 then zargs[2] else 0
    local routine = if argc >= 3 then zargs[3] else 0

    local reply
    while true do
        reply = textClient:request("read_char", { timeout = timeout })
        if reply.status ~= "timeout" then
            state:store(reply.value)
            return
        end
        if timeoutEndsInput(state, routine) then
            state:store(0)
            return
        end
    end
end

-- Mirrors z_tokenise (text.c).
local function z_tokenise(state: ZState.ZState): ()
    local zargs, argc = state.zargs, state.zargc
    client(state):request("tokenise", {
        text = zargs[1],
        parse = zargs[2],
        dict = if argc >= 3 then zargs[3] else 0,
        skip = argc >= 4 and zargs[4] ~= 0,
    })
end

-- Mirrors z_encode_text (text.c).
local function z_encode_text(state: ZState.ZState): ()
    local zargs = state.zargs
    client(state):request("encode_text", {
        text = zargs[1], length = zargs[2], offset = zargs[3], dest = zargs[4],
    })
end

-- The window operand: 0 or 1. Anything else is ERR_ILL_WIN, including
-- -3 ("current window"), which only V6 accepts. Mirrors winarg0.
local function windowArg(state: ZState.ZState): number
    local window = state.zargs[1]
    if window >= 2 then
        state:runtimeError(ERR_ILL_WIN)
    end
    return window
end

local function z_split_window(state: ZState.ZState): ()
    client(state):queue({ "w", "split", state.zargs[1] })
end

local function z_set_window(state: ZState.ZState): ()
    client(state):queue({ "w", "set", windowArg(state) })
end

-- -1 clears everything and unsplits, -2 clears everything, 0 and 1 clear
-- one window. Mirrors z_erase_window (screen.c).
local function z_erase_window(state: ZState.ZState): ()
    local value = ZState.toS16(state.zargs[1])
    if value ~= -1 and value ~= -2 then
        value = windowArg(state)
    end
    client(state):queue({ "w", "erase", value })
end

local function z_erase_line(state: ZState.ZState): ()
    client(state):queue({ "w", "eraseline", state.zargs[1] })
end

local function z_set_cursor(state: ZState.ZState): ()
    client(state):queue({ "w", "cursor", ZState.toS16(state.zargs[1]), state.zargs[2] })
end

local function z_set_text_style(state: ZState.ZState): ()
    client(state):queue({ "w", "style", state.zargs[1] })
end

local function z_set_colour(state: ZState.ZState): ()
    client(state):queue({ "w", "colour", state.zargs[1], state.zargs[2] })
end

local function z_buffer_mode(state: ZState.ZState): ()
    client(state):queue({ "w", "buffer", state.zargs[1] })
end

-- Writes the current window's cursor position (row, column) as two words
-- at the given address. Mirrors z_get_cursor (screen.c).
local function z_get_cursor(state: ZState.ZState): ()
    local reply = client(state):request("get_cursor")
    local addr = state.zargs[1]
    storeWord(state, addr, reply.row)
    storeWord(state, bit32.band(addr + 2, 0xFFFF), reply.column)
end

-- The address ranges of the three tables the Text Service reads when it
-- decodes text: the alphabet table, the abbreviations table and the
-- Unicode translation table. A story write to any of them waits for the
-- text sent so far (rule R6).
local function watchRanges(state: ZState.ZState): { { number } }
    local header, memory = state.header, state.memory
    local ranges: { { number } } = {}
    if header.alphabetTable ~= 0 then
        table.insert(ranges, { header.alphabetTable, header.alphabetTable + 77 })
    end
    if header.version >= 2 and header.abbreviations ~= 0 then
        local size = if header.version == 2 then 64 else 192
        table.insert(ranges, { header.abbreviations, header.abbreviations + size - 1 })
    end
    local extension = header.headerExtensionTable
    if extension ~= 0 and memory:readU16(extension) >= 3 then
        local unicode = memory:readU16(extension + 6)
        if unicode ~= 0 then
            table.insert(ranges, { unicode, unicode + 2 * memory:readU8(unicode) })
        end
    end
    return ranges
end

-- Restarts the story: sends what it printed, reloads dynamic memory,
-- resets the stack and PC, and has the Text Service reset its screen.
-- Mirrors z_restart (fastmem.c).
local function z_restart(state: ZState.ZState): ()
    local textClient = client(state)
    textClient:flush()
    state:restart()
    textClient:reset()
    textClient:setWatch(watchRanges(state))
end

----------------------------------------------------------------------
-- EXT opcodes and the extended escape
----------------------------------------------------------------------

-- EXT opcodes (0xBE prefix byte, then this opcode number), 0x00-0x1C.
local ext: {[number]: Handler} = {
    [0x00] = unsupported("save"),  -- save (V5+ table form)
    [0x01] = unsupported("restore"),  -- restore (V5+ table form)
    [0x02] = z_log_shift,
    [0x03] = z_art_shift,
    [0x04] = z_set_font,
    [0x05] = unsupported("draw_picture"),
    [0x06] = unsupported("picture_data"),
    [0x07] = unsupported("erase_picture"),
    [0x08] = unsupported("set_margins"),
    [0x09] = z_save_undo,
    [0x0A] = z_restore_undo,
    [0x0B] = z_print_unicode,
    [0x0C] = z_check_unicode,
    [0x0D] = z_set_true_colour,
    [0x0E] = illegal,  -- (unused)
    [0x0F] = illegal,  -- (unused)
    [0x10] = unsupported("move_window"),
    [0x11] = unsupported("window_size"),
    [0x12] = unsupported("window_style"),
    [0x13] = unsupported("get_wind_prop"),
    [0x14] = unsupported("scroll_window"),
    [0x15] = z_pop_stack,
    [0x16] = unsupported("read_mouse"),
    [0x17] = unsupported("mouse_window"),
    [0x18] = z_push_stack,
    [0x19] = unsupported("put_wind_prop"),
    [0x1A] = unsupported("print_form"),
    [0x1B] = unsupported("make_menu"),
    [0x1C] = unsupported("picture_table"),
}

-- Extended opcodes are dispatched through a second opcode byte after the
-- 0xBE prefix, then one specifier byte, exactly like a VAR instruction's
-- single-specifier form. Mirrors __extended__ (process.c).
--
-- Opcode numbers >= 0x1D are reserved for future spec versions and are
-- silently ignored -- not an error. This is the one dispatch path where
-- a story-provided value the port doesn't recognize is expected, not a
-- bug, so it does not go through `illegal`.
local function extended(state: ZState.ZState): ()
    local extOpcode = state:codeByte()
    local specifier = state:codeByte()
    loadAllOperands(state, specifier)

    if extOpcode < 0x1D then
        ext[extOpcode](state)
    end
end

----------------------------------------------------------------------
-- Calls
--
-- Shared by both op1 (call_1s/call_1n) and var (call_2s/call_2n,
-- call/call_vs, call_vs2, call_vn, call_vn2) -- defined before both
-- tables for that reason.
----------------------------------------------------------------------

local CT_STORE = ZState.CallType.STORE
local CT_DISCARD = ZState.CallType.DISCARD

-- Scratch buffer for the argument array ZState:call expects, reused
-- across every call opcode to avoid allocating a table per call
-- instruction (mirrors why state.zargs itself is preallocated). Sized
-- for the maximum real-argument count: 7, from the 8-operand
-- two-specifier forms (1 routine + 7 args).
local callArgsBuffer: {number} = table.create(7, 0)

-- Builds the (argc, args) pair ZState:call expects from zargs[2..zargc],
-- shifting past the routine address at zargs[1].
local function buildCallArgs(state: ZState.ZState): number
    local argc = state.zargc - 1
    for i = 1, argc do
        callArgsBuffer[i] = state.zargs[i + 1]
    end
    return argc
end

-- Calls a subroutine and stores its result. Routine address 0 is a
-- special case: no call happens, and 0 is stored directly. Mirrors
-- z_call_s (process.c).
local function z_call_s(state: ZState.ZState): ()
    local routine = state.zargs[1]
    if routine ~= 0 then
        local argc = buildCallArgs(state)
        state:call(routine, argc, callArgsBuffer, CT_STORE)
    else
        state:store(0)
    end
end

-- Calls a subroutine and discards its result. Routine address 0 does
-- nothing at all -- not even a store. Mirrors z_call_n (process.c).
local function z_call_n(state: ZState.ZState): ()
    local routine = state.zargs[1]
    if routine ~= 0 then
        local argc = buildCallArgs(state)
        state:call(routine, argc, callArgsBuffer, CT_DISCARD)
    end
end

----------------------------------------------------------------------
-- Frame introspection
--
-- Thin wrappers over the ZState primitives built for exactly this
-- purpose in Phase 3 -- see catchFrame/throwFrame/checkArgCount.
----------------------------------------------------------------------

-- Stores the current call depth, for later use with z_throw.
local function z_catch(state: ZState.ZState): ()
    state:store(state:catchFrame())
end

-- Unwinds the stack back to the frame identified by zargs[2] (as
-- returned by z_catch) and returns from it with zargs[1].
local function z_throw(state: ZState.ZState): ()
    state:throwFrame(state.zargs[1], state.zargs[2])
end

-- Branches if the current routine was called with at least zargs[1]
-- arguments.
local function z_check_arg_count(state: ZState.ZState): ()
    state:checkArgCount(state.zargs[1])
end

----------------------------------------------------------------------
-- Stack (VAR)
----------------------------------------------------------------------

local function z_push(state: ZState.ZState): ()
    state:push(state.zargs[1])
end

-- Pops a value and writes it to the named variable. Non-V6: pop, then
-- write in place using the post-pop stack top for variable 0 -- exactly
-- ZState:writeVariable's contract. V6: either a user-stack pop (reversing
-- z_push_stack's bookkeeping: increment the free-slot count, then read
-- from the slot that boundary now points at) or, with no stack operand,
-- the game stack -- either way the result then goes through a store byte
-- read from the PC stream, same as any other stored result. Mirrors
-- z_pull (variable.c).
local function z_pull(state: ZState.ZState): ()
    if state.header.version ~= 6 then
        local value = state:pop()
        state:writeVariable(state.zargs[1], value)
    else
        local value: number
        if state.zargc == 1 then
            local addr = state.zargs[1]
            local size = state.memory:readU16(addr) + 1
            storeWord(state, addr, size)
            value = state.memory:readU16(addr + 2 * size)
        else
            value = state:pop()
        end
        state:store(value)
    end
end

----------------------------------------------------------------------
-- Variables (VAR)
----------------------------------------------------------------------

local function z_store(state: ZState.ZState): ()
    state:writeVariable(state.zargs[1], state.zargs[2])
end

-- Decrements a variable in place and branches if the new value is less
-- than zargs[2]. Mirrors z_dec_chk (variable.c). Reads via peekVariable
-- (not pop) so variable 0 modifies the current stack top rather than
-- consuming it -- the same read/modify/write-in-place pattern z_dec uses.
local function z_dec_chk(state: ZState.ZState): ()
    local variable = state.zargs[1]
    local value = ZState.toU16(state:peekVariable(variable) - 1)
    state:writeVariable(variable, value)
    state:branch(ZState.toS16(value) < ZState.toS16(state.zargs[2]))
end

-- Increments a variable in place and branches if the new value is
-- greater than zargs[2]. Mirrors z_inc_chk (variable.c).
local function z_inc_chk(state: ZState.ZState): ()
    local variable = state.zargs[1]
    local value = ZState.toU16(state:peekVariable(variable) + 1)
    state:writeVariable(variable, value)
    state:branch(ZState.toS16(value) > ZState.toS16(state.zargs[2]))
end

----------------------------------------------------------------------
-- Arithmetic
----------------------------------------------------------------------

local ERR_DIV_ZERO = ZState.Errors.DIV_ZERO

-- Signed 16-bit arithmetic. Operands are reinterpreted as signed via
-- toS16 (C's `(short)` cast) and results wrapped back into the unsigned
-- zword range via toU16 before storing. Mirror z_add/z_sub/z_mul
-- (math.c).
local function z_add(state: ZState.ZState): ()
    state:store(ZState.toU16(ZState.toS16(state.zargs[1]) + ZState.toS16(state.zargs[2])))
end

local function z_sub(state: ZState.ZState): ()
    state:store(ZState.toU16(ZState.toS16(state.zargs[1]) - ZState.toS16(state.zargs[2])))
end

local function z_mul(state: ZState.ZState): ()
    state:store(ZState.toU16(ZState.toS16(state.zargs[1]) * ZState.toS16(state.zargs[2])))
end

-- Signed division, truncating toward zero like C (Luau's // floors
-- toward negative infinity, which differs for mixed-sign operands).
-- Mirrors z_div (math.c). Note the divide-by-zero check is on the raw
-- operand, exactly as in the reference.
local function z_div(state: ZState.ZState): ()
    if state.zargs[2] == 0 then
        state:runtimeError(ERR_DIV_ZERO)
    end
    local quotient = ZState.toS16(state.zargs[1]) / ZState.toS16(state.zargs[2])
    quotient = if quotient < 0 then math.ceil(quotient) else math.floor(quotient)
    state:store(ZState.toU16(quotient))
end

-- Remainder with the dividend's sign, like C's % (Luau's % takes the
-- divisor's sign; math.fmod matches C). Mirrors z_mod (math.c).
local function z_mod(state: ZState.ZState): ()
    if state.zargs[2] == 0 then
        state:runtimeError(ERR_DIV_ZERO)
    end
    state:store(ZState.toU16(math.fmod(ZState.toS16(state.zargs[1]), ZState.toS16(state.zargs[2]))))
end

----------------------------------------------------------------------
-- Bitwise and logic (VAR)
----------------------------------------------------------------------

-- Mirrors z_and/z_or (math.c). Operands are unsigned, so the bit32
-- results are already in zword range.
local function z_and(state: ZState.ZState): ()
    state:store(bit32.band(state.zargs[1], state.zargs[2]))
end

local function z_or(state: ZState.ZState): ()
    state:store(bit32.bor(state.zargs[1], state.zargs[2]))
end

-- bit32.bnot flips all 32 bits, so mask back down to a zword. Mirrors
-- z_not (math.c). Also the V1-V4 1OP `not` once version patching lands.
local function z_not(state: ZState.ZState): ()
    state:store(bit32.band(bit32.bnot(state.zargs[1]), 0xFFFF))
end

----------------------------------------------------------------------
-- Comparison and branching (VAR)
----------------------------------------------------------------------

-- Branches if zargs[1] equals any of the following operands (up to
-- three). Comparison is unsigned. With a single operand there is nothing
-- to match, so the branch is false. Mirrors z_je (math.c), which only
-- inspects zargs[0..3].
local function z_je(state: ZState.ZState): ()
    local zargs = state.zargs
    local matched = false
    for i = 2, math.min(state.zargc, 4) do
        if zargs[1] == zargs[i] then
            matched = true
            break
        end
    end
    state:branch(matched)
end

-- Signed less-than / greater-than. Mirror z_jl / z_jg (math.c).
local function z_jl(state: ZState.ZState): ()
    state:branch(ZState.toS16(state.zargs[1]) < ZState.toS16(state.zargs[2]))
end

local function z_jg(state: ZState.ZState): ()
    state:branch(ZState.toS16(state.zargs[1]) > ZState.toS16(state.zargs[2]))
end

-- Branches if every bit set in the mask (zargs[2]) is also set in the
-- value (zargs[1]). Mirrors z_test (math.c).
local function z_test(state: ZState.ZState): ()
    state:branch(bit32.band(state.zargs[1], state.zargs[2]) == state.zargs[2])
end

----------------------------------------------------------------------
-- Memory tables (VAR)
----------------------------------------------------------------------

-- Table addresses are 16-bit: the sum wraps like C's zword arithmetic.
-- Mirror z_loadb/z_loadw/z_storeb/z_storew (table.c).
local function z_loadb(state: ZState.ZState): ()
    local addr = bit32.band(state.zargs[1] + state.zargs[2], 0xFFFF)
    state:store(state.memory:readU8(addr))
end

local function z_loadw(state: ZState.ZState): ()
    local addr = bit32.band(state.zargs[1] + 2 * state.zargs[2], 0xFFFF)
    state:store(state.memory:readU16(addr))
end

local function z_storeb(state: ZState.ZState): ()
    local addr = bit32.band(state.zargs[1] + state.zargs[2], 0xFFFF)
    storeByte(state, addr, bit32.band(state.zargs[3], 0xFF))
end

local function z_storew(state: ZState.ZState): ()
    local addr = bit32.band(state.zargs[1] + 2 * state.zargs[2], 0xFFFF)
    storeWord(state, addr, state.zargs[3])
end

-- Copies (or, with destination 0, zero-fills) a table of bytes. Mirrors
-- z_copy_table (table.c). The direction is what makes overlapping
-- copies safe: a positive size with source <= dest copies from the last
-- byte backward, so the destination overlapping above the source never
-- clobbers unread bytes; source > dest copies forward. A NEGATIVE size
-- forces a forward copy regardless -- the spec's deliberate "smear"
-- case, using |size| bytes. Destination 0 is checked first, and there
-- the size is unsigned. All addresses wrap at 16 bits, and writes go
-- through storeByte for the range check and flags routing.
local function z_copy_table(state: ZState.ZState): ()
    local source = state.zargs[1]
    local dest = state.zargs[2]
    local size = state.zargs[3]

    if dest == 0 then
        for i = 0, size - 1 do
            storeByte(state, bit32.band(source + i, 0xFFFF), 0)
        end
    elseif ZState.toS16(size) < 0 or source > dest then
        for i = 0, math.abs(ZState.toS16(size)) - 1 do
            local value = state.memory:readU8(bit32.band(source + i, 0xFFFF))
            storeByte(state, bit32.band(dest + i, 0xFFFF), value)
        end
    else
        for i = size - 1, 0, -1 do
            local value = state.memory:readU8(bit32.band(source + i, 0xFFFF))
            storeByte(state, bit32.band(dest + i, 0xFFFF), value)
        end
    end
end

-- Searches a table for a value. Operands: target, table address, entry
-- count, and an optional form byte (default 0x82): bit 7 selects word
-- entries over byte entries, and the low 7 bits are the step between
-- entries. Stores the address of the first match (or 0) and then
-- branches on it being nonzero -- store before branch, since both
-- consume PC bytes in that order. Mirrors z_scan_table (table.c).
local function z_scan_table(state: ZState.ZState): ()
    local target = state.zargs[1]
    local addr = state.zargs[2]
    local count = state.zargs[3]
    local form = if state.zargc >= 4 then state.zargs[4] else 0x82
    local isWords = bit32.band(form, 0x80) ~= 0
    local step = bit32.band(form, 0x7F)

    local found = 0
    for _ = 1, count do
        local value = if isWords then state.memory:readU16(addr) else state.memory:readU8(addr)
        if value == target then
            found = addr
            break
        end
        addr = bit32.band(addr + step, 0xFFFF)
    end

    state:store(found)
    state:branch(found ~= 0)
end

----------------------------------------------------------------------
-- Object tree (VAR)
----------------------------------------------------------------------

-- Branches if zargs[1] is a direct child of zargs[2]. With object 0 as
-- the child there is no parent to read, so it branches only when the
-- second operand is also 0 (Frotz: branch(0 == zargs[1])). Mirrors z_jin
-- (object.c).
local function z_jin(state: ZState.ZState): ()
    local obj = state.zargs[1]
    if obj == 0 then
        state:runtimeWarning(Warnings.JIN_0)
        state:branch(state.zargs[2] == 0)
        return
    end
    state:branch(ZObject.parent(state, obj) == state.zargs[2])
end

-- Moves zargs[1] to be the first child of zargs[2]. Mirrors z_insert_obj
-- (object.c); object 0 on either side warns and does nothing.
local function z_insert_obj(state: ZState.ZState): ()
    local obj = state.zargs[1]
    local dest = state.zargs[2]
    if obj == 0 then
        state:runtimeWarning(Warnings.MOVE_OBJECT_0)
        return
    end
    if dest == 0 then
        state:runtimeWarning(Warnings.MOVE_OBJECT_TO_0)
        return
    end
    ZObject.insert(state, obj, dest)
end

----------------------------------------------------------------------
-- Object attributes (VAR)
----------------------------------------------------------------------

local ERR_ILL_ATTR = ZState.Errors.ILL_ATTR

-- Attribute numbers run 0-31 in V1-V3 and 0-47 in V4+. Frotz checks this
-- before looking at the object, so object 0 with a bad number is still
-- fatal.
local function checkAttribute(state: ZState.ZState, attr: number): ()
    if attr > (if state.header.version <= 3 then 31 else 47) then
        state:runtimeError(ERR_ILL_ATTR)
    end
end

-- Address of the byte holding an attribute, and its bit mask within that
-- byte (attribute 0 is the top bit of the first byte).
local function attributeLocation(state: ZState.ZState, obj: number, attr: number): (number, number)
    return ZObject.address(state, obj) + bit32.rshift(attr, 3), bit32.rshift(0x80, bit32.band(attr, 7))
end

-- Branches if the object has the attribute. Mirrors z_test_attr (object.c).
local function z_test_attr(state: ZState.ZState): ()
    local obj, attr = state.zargs[1], state.zargs[2]
    checkAttribute(state, attr)
    if obj == 0 then
        state:runtimeWarning(Warnings.TEST_ATTR_0)
        state:branch(false)
        return
    end
    local addr, mask = attributeLocation(state, obj, attr)
    state:branch(bit32.band(state.memory:readU8(addr), mask) ~= 0)
end

-- Mirrors z_set_attr (object.c), minus its Sherlock-only special case.
local function z_set_attr(state: ZState.ZState): ()
    local obj, attr = state.zargs[1], state.zargs[2]
    checkAttribute(state, attr)
    if obj == 0 then
        state:runtimeWarning(Warnings.SET_ATTR_0)
        return
    end
    local addr, mask = attributeLocation(state, obj, attr)
    storeByte(state, addr, bit32.bor(state.memory:readU8(addr), mask))
end

-- Mirrors z_clear_attr (object.c), minus its Sherlock-only special case.
local function z_clear_attr(state: ZState.ZState): ()
    local obj, attr = state.zargs[1], state.zargs[2]
    checkAttribute(state, attr)
    if obj == 0 then
        state:runtimeWarning(Warnings.CLEAR_ATTR_0)
        return
    end
    local addr, mask = attributeLocation(state, obj, attr)
    storeByte(state, addr, bit32.band(state.memory:readU8(addr), bit32.bnot(mask)))
end

----------------------------------------------------------------------
-- Object properties (VAR)
----------------------------------------------------------------------

local ERR_NO_PROP = ZState.Errors.NO_PROP

-- Whether a property holds a byte rather than a word: the size field says
-- length 1. Mirrors the test in z_get_prop and z_put_prop (object.c).
local function isByteProperty(state: ZState.ZState, sizeByte: number): boolean
    return bit32.band(sizeByte, if state.header.version <= 3 then 0xE0 else 0xC0) == 0
end

-- Mirrors z_get_prop (object.c). A missing property yields the default
-- from the table of words that precedes the objects.
local function z_get_prop(state: ZState.ZState): ()
    local obj, id = state.zargs[1], state.zargs[2]
    if obj == 0 then
        state:runtimeWarning(Warnings.GET_PROP_0)
        state:store(0)
        return
    end
    local addr, sizeByte = ZObject.findProperty(state, obj, id)
    local value
    if bit32.band(sizeByte, ZObject.propertyMask(state)) == id then
        value = if isByteProperty(state, sizeByte)
            then state.memory:readU8(addr + 1)
            else state.memory:readU16(addr + 1)
    else
        value = state.memory:readU16(bit32.band(state.header.objects + 2 * (id - 1), 0xFFFF))
    end
    state:store(value)
end

-- Mirrors z_get_prop_addr (object.c).
local function z_get_prop_addr(state: ZState.ZState): ()
    local obj, id = state.zargs[1], state.zargs[2]
    if obj == 0 then
        state:runtimeWarning(Warnings.GET_PROP_ADDR_0)
        state:store(0)
        return
    end
    local addr, sizeByte = ZObject.findProperty(state, obj, id)
    if bit32.band(sizeByte, ZObject.propertyMask(state)) ~= id then
        state:store(0)
        return
    end
    if state.header.version >= 4 and bit32.band(sizeByte, 0x80) ~= 0 then
        addr += 1  -- two-byte size field
    end
    state:store(addr + 1)
end

-- Mirrors z_get_next_prop (object.c): property 0 asks for the first.
local function z_get_next_prop(state: ZState.ZState): ()
    local obj, id = state.zargs[1], state.zargs[2]
    if obj == 0 then
        state:runtimeWarning(Warnings.GET_NEXT_PROP_0)
        state:store(0)
        return
    end
    local mask = ZObject.propertyMask(state)
    local addr = ZObject.firstProperty(state, obj)
    if id ~= 0 then
        local found, sizeByte = ZObject.findProperty(state, obj, id)
        if bit32.band(sizeByte, mask) ~= id then
            state:runtimeError(ERR_NO_PROP)
        end
        addr = ZObject.nextProperty(state, found)
    end
    state:store(bit32.band(state.memory:readU8(addr), mask))
end

-- Mirrors z_put_prop (object.c).
local function z_put_prop(state: ZState.ZState): ()
    local obj, id, value = state.zargs[1], state.zargs[2], state.zargs[3]
    if obj == 0 then
        state:runtimeWarning(Warnings.PUT_PROP_0)
        return
    end
    local addr, sizeByte = ZObject.findProperty(state, obj, id)
    if bit32.band(sizeByte, ZObject.propertyMask(state)) ~= id then
        state:runtimeError(ERR_NO_PROP)
    end
    if isByteProperty(state, sizeByte) then
        storeByte(state, addr + 1, bit32.band(value, 0xFF))
    else
        storeWord(state, addr + 1, value)
    end
end

----------------------------------------------------------------------
-- Random numbers (VAR)
----------------------------------------------------------------------

-- A positive operand is a range: store a random value in 1..range. Zero
-- or negative reseeds instead (see ZState:seedRandom) and stores 0.
-- Mirrors z_random (random.c).
local function z_random(state: ZState.ZState): ()
    local range = ZState.toS16(state.zargs[1])
    if range <= 0 then
        state:seedRandom(-range)
        state:store(0)
    else
        state:store(state:nextRandom() % range + 1)
    end
end

----------------------------------------------------------------------
-- 2OP and VAR opcodes (shared table)
----------------------------------------------------------------------

-- 2OP opcodes (long form 0x01-0x7F, indexed by opcode & 0x1F) and VAR
-- opcodes (0xC0-0xDF, indexed by opcode - 0xC0) share this table.
local var: {[number]: Handler} = {
    [0x00] = illegal,  -- (2OP number 0 does not exist)
    [0x01] = z_je,
    [0x02] = z_jl,
    [0x03] = z_jg,
    [0x04] = z_dec_chk,
    [0x05] = z_inc_chk,
    [0x06] = z_jin,
    [0x07] = z_test,
    [0x08] = z_or,
    [0x09] = z_and,
    [0x0A] = z_test_attr,
    [0x0B] = z_set_attr,
    [0x0C] = z_clear_attr,
    [0x0D] = z_store,
    [0x0E] = z_insert_obj,
    [0x0F] = z_loadw,
    [0x10] = z_loadb,
    [0x11] = z_get_prop,
    [0x12] = z_get_prop_addr,
    [0x13] = z_get_next_prop,
    [0x14] = z_add,
    [0x15] = z_sub,
    [0x16] = z_mul,
    [0x17] = z_div,
    [0x18] = z_mod,
    [0x19] = z_call_s,  -- call_2s (V4+)
    [0x1A] = z_call_n,  -- call_2n (V5+)
    [0x1B] = z_set_colour,
    [0x1C] = z_throw,
    [0x1D] = illegal,  -- (unused)
    [0x1E] = illegal,  -- (unused)
    [0x1F] = illegal,  -- (unused)
    [0x20] = z_call_s,  -- call / call_vs
    [0x21] = z_storew,
    [0x22] = z_storeb,
    [0x23] = z_put_prop,
    [0x24] = z_read,  -- read / sread / aread
    [0x25] = z_print_char,
    [0x26] = z_print_num,
    [0x27] = z_random,
    [0x28] = z_push,
    [0x29] = z_pull,
    [0x2A] = z_split_window,
    [0x2B] = z_set_window,
    [0x2C] = z_call_s,  -- call_vs2
    [0x2D] = z_erase_window,
    [0x2E] = z_erase_line,
    [0x2F] = z_set_cursor,
    [0x30] = z_get_cursor,
    [0x31] = z_set_text_style,
    [0x32] = z_buffer_mode,
    [0x33] = z_output_stream,
    [0x34] = z_input_stream,
    [0x35] = z_sound_effect,
    [0x36] = z_read_char,
    [0x37] = z_scan_table,
    [0x38] = z_not,
    [0x39] = z_call_n,  -- call_vn
    [0x3A] = z_call_n,  -- call_vn2
    [0x3B] = z_tokenise,
    [0x3C] = z_encode_text,
    [0x3D] = z_copy_table,
    [0x3E] = z_print_table,
    [0x3F] = z_check_arg_count,
}

----------------------------------------------------------------------
-- 1OP opcodes
----------------------------------------------------------------------

-- Branches if the operand is zero. Mirrors z_jz (math.c); the (short)
-- cast in C is irrelevant to an equality test against zero.
local function z_jz(state: ZState.ZState): ()
    state:branch(state.zargs[1] == 0)
end

-- Object tree reads. Each guards object 0 first, reports its warning,
-- and falls back exactly as Frotz does (object.c).
local function z_get_parent(state: ZState.ZState): ()
    local obj = state.zargs[1]
    if obj == 0 then
        state:runtimeWarning(Warnings.GET_PARENT_0)
        state:store(0)
        return
    end
    state:store(ZObject.parent(state, obj))
end

-- Store before branch: both consume PC bytes in that order.
local function z_get_child(state: ZState.ZState): ()
    local obj = state.zargs[1]
    if obj == 0 then
        state:runtimeWarning(Warnings.GET_CHILD_0)
        state:store(0)
        state:branch(false)
        return
    end
    local child = ZObject.child(state, obj)
    state:store(child)
    state:branch(child ~= 0)
end

local function z_get_sibling(state: ZState.ZState): ()
    local obj = state.zargs[1]
    if obj == 0 then
        state:runtimeWarning(Warnings.GET_SIBLING_0)
        state:store(0)
        state:branch(false)
        return
    end
    local sibling = ZObject.sibling(state, obj)
    state:store(sibling)
    state:branch(sibling ~= 0)
end

-- Stores the length of the property whose data starts at zargs[1].
-- Address 0 stores 0 (Spec 1.1). Mirrors z_get_prop_len (object.c).
local function z_get_prop_len(state: ZState.ZState): ()
    local addr = state.zargs[1]
    state:store(if addr == 0 then 0 else ZObject.dataLength(state, addr))
end

-- Detaches an object from its parent. Mirrors z_remove_obj (object.c).
local function z_remove_obj(state: ZState.ZState): ()
    local obj = state.zargs[1]
    if obj == 0 then
        state:runtimeWarning(Warnings.REMOVE_OBJECT_0)
        return
    end
    ZObject.unlink(state, obj)
end

-- Reads a variable without consuming it (variable 0 peeks the stack top,
-- matching z_load's `value = *sp`), then stores it through a separate
-- store-destination byte. Mirrors z_load (variable.c).
local function z_load(state: ZState.ZState): ()
    state:store(state:peekVariable(state.zargs[1]))
end

-- Decrements a variable in place. Mirrors z_dec (variable.c).
local function z_dec(state: ZState.ZState): ()
    local variable = state.zargs[1]
    state:writeVariable(variable, ZState.toU16(state:peekVariable(variable) - 1))
end

-- Increments a variable in place. Mirrors z_inc (variable.c).
local function z_inc(state: ZState.ZState): ()
    local variable = state.zargs[1]
    state:writeVariable(variable, ZState.toU16(state:peekVariable(variable) + 1))
end

-- Returns from the current subroutine, restoring the previous frame.
local function z_ret(state: ZState.ZState): ()
    state:ret(state.zargs[1])
end

-- Jumps unconditionally by a signed PC-relative offset. Mirrors z_jump
-- (process.c). By the time this runs, state.pc already points past the
-- operand -- the same position GET_PC(pc) captures in the C source.
-- Frotz only bounds-checks the upper end (pc >= story_size); matched
-- here without adding a lower-bound check it doesn't have.
local function z_jump(state: ZState.ZState): ()
    local pc = state.pc + ZState.toS16(state.zargs[1]) - 2
    if pc >= state.header.storySize then
        state:runtimeError(ERR_ILL_JUMP_ADDR)
    end
    state.pc = pc
end

-- 1OP opcodes (opcode byte 0x80-0xAF), indexed by (opcode & 0x0F).
local op1: {[number]: Handler} = {
    [0x0] = z_jz,
    [0x1] = z_get_sibling,
    [0x2] = z_get_child,
    [0x3] = z_get_parent,
    [0x4] = z_get_prop_len,
    [0x5] = z_inc,
    [0x6] = z_dec,
    [0x7] = z_print_addr,
    [0x8] = z_call_s,  -- call_1s
    [0x9] = z_remove_obj,
    [0xA] = z_print_obj,
    [0xB] = z_ret,
    [0xC] = z_jump,
    [0xD] = z_print_paddr,
    [0xE] = z_load,
    [0xF] = z_call_n,  -- call_1n (V5+); V1-V4 patched to not, see applyVersionPatches
}

----------------------------------------------------------------------
-- 0OP opcodes
----------------------------------------------------------------------

local function z_rtrue(state: ZState.ZState): ()
    state:ret(1)
end

local function z_rfalse(state: ZState.ZState): ()
    state:ret(0)
end

local function z_nop(state: ZState.ZState): ()
    -- Do nothing.
end

-- Discards the top of the game stack. Mirrors z_pop (variable.c); uses
-- ZState:pop rather than a raw sp++ so an already-empty stack raises
-- ERR_STK_UNDF instead of the reference's unchecked pointer bump.
-- Reaches op0[0x9] only for V1-V4 stories, via applyVersionPatches.
local function z_pop(state: ZState.ZState): ()
    state:pop()
end

local function z_ret_popped(state: ZState.ZState): ()
    state:ret(state:pop())
end

local function z_quit(state: ZState.ZState): ()
    state.finished = 9999
end

-- Branches if the story image matches the checksum in its header. Sums
-- the pristine bytes from 64 to the end of the story (readOriginalU8, as C
-- reads the file). tick() yields periodically, since a run of ROM cache
-- hits would otherwise never yield. Mirrors z_verify (fastmem.c).
local function z_verify(state: ZState.ZState): ()
    local memory = state.memory
    local sum = 0
    for address = 64, memory.storySize - 1 do
        sum += memory:readOriginalU8(address)
        state:tick()
    end
    state:branch(bit32.band(sum, 0xFFFF) == state.header.checksum)
end

-- Branches if the story is a legal copy. Frotz's piracy option defaults
-- to off, so this always branches. Mirrors z_piracy (main.c).
local function z_piracy(state: ZState.ZState): ()
    state:branch(true)
end

-- 0OP opcodes (opcode byte 0xB0-0xBF), indexed by (opcode - 0xB0).
local op0: {[number]: Handler} = {
    [0x0] = z_rtrue,
    [0x1] = z_rfalse,
    [0x2] = z_print,
    [0x3] = z_print_ret,
    [0x4] = z_nop,
    [0x5] = unsupported("save"),
    [0x6] = unsupported("restore"),
    [0x7] = z_restart,
    [0x8] = z_ret_popped,
    [0x9] = z_catch,  -- catch (V5+); V1-V4 patched to pop, see applyVersionPatches
    [0xA] = z_quit,
    [0xB] = z_new_line,
    [0xC] = z_show_status,
    [0xD] = z_verify,
    [0xE] = extended,
    [0xF] = z_piracy,
}

----------------------------------------------------------------------
-- Version patching
----------------------------------------------------------------------

-- Two opcode slots mean different things by story version: 0OP:9 is
-- `catch` in V5+ but `pop` in V1-V4, and 1OP:15 is `call_1n` in V5+ but
-- `not` in V1-V4. The table literals hold the V5+ defaults (matching
-- Frotz's static tables); this swaps in the V1-V4 handlers. Mirrors the
-- table patching in init_memory (fastmem.c).
--
-- Sets both directions, unlike Frotz, because these tables are shared
-- module state rather than per-process: calling it for a V5 story after
-- a V3 one restores the defaults. Call once after the header is read.
local function applyVersionPatches(version: number): ()
    if version <= 4 then
        op0[0x9] = z_pop
        op1[0xF] = z_not
    else
        op0[0x9] = z_catch
        op1[0xF] = z_call_n
    end
end

----------------------------------------------------------------------
-- step()
----------------------------------------------------------------------

-- Fetches, decodes, and executes exactly one instruction. Mirrors the
-- body of interpret()'s do/while loop (process.c), minus the loop
-- itself and os_tick() -- Phase 5 owns iterating this and calling
-- ZState:tick().
local function step(state: ZState.ZState): ()
    local opcode = state:codeByte()
    state.zargc = 0

    if opcode < 0x80 then
        -- 2OP: bit 6 selects operand 1's type, bit 5 selects operand 2's.
        -- Each is small constant or variable; the compact 2OP encoding
        -- has no bit pattern for a large constant.
        loadOperand(state, bit32.extract(opcode, 6, 1) == 1 and OPERAND_VARIABLE or OPERAND_SMALL_CONSTANT)
        loadOperand(state, bit32.extract(opcode, 5, 1) == 1 and OPERAND_VARIABLE or OPERAND_SMALL_CONSTANT)
        var[bit32.band(opcode, 0x1f)](state)
    elseif opcode < 0xB0 then
        -- 1OP: bits 5-4 give the single operand's type (0/1/2) directly.
        loadOperand(state, bit32.extract(opcode, 4, 2))
        op1[bit32.band(opcode, 0x0f)](state)
    elseif opcode < 0xC0 then
        -- 0OP, including the extended escape at 0xBE (index 0x0E).
        op0[opcode - 0xB0](state)
    else
        -- VAR: one specifier byte, except opcodes 0xEC and 0xFA, which
        -- take two and can supply up to eight operands total.
        local specifier1 = state:codeByte()
        if opcode == 0xEC or opcode == 0xFA then
            local specifier2 = state:codeByte()
            loadAllOperands(state, specifier1)
            loadAllOperands(state, specifier2)
        else
            loadAllOperands(state, specifier1)
        end
        var[opcode - 0xC0](state)
    end
end

ZOpcodes.illegal = illegal
ZOpcodes.unsupportedNames = unsupportedNames
ZOpcodes.op0 = op0
ZOpcodes.op1 = op1
ZOpcodes.var = var
ZOpcodes.ext = ext
ZOpcodes.step = step
ZOpcodes.applyVersionPatches = applyVersionPatches

-- Connects a state to its ZTextClient (the core's side of the Text
-- Service). Errors the client reports become the story's fatal errors
-- with the PC attached; the client is given the address ranges of the
-- string tables so story writes to them wait for earlier output (R6); and
-- pending output is sent whenever the state yields.
--
-- The caller supplies state.directCall (the run loop does); until it
-- does, a timed read that expires raises an error.
function ZOpcodes.attachText(state: ZState.ZState, textClient: any)
    state.textClient = textClient
    textClient.onError = function(err: any)
        if err.fault ~= nil then
            error("Text Service fault: " .. tostring(if typeof(err.fault) == "string" then err.fault else err.message))
        end
        state:runtimeError(err.code)
    end
    textClient:setWatch(watchRanges(state))
    state.onYield = function()
        textClient:flush()
    end
    if state.directCall == nil then
        state.directCall = function()
            error("state.directCall is provided by the run loop")
        end
    end
end

return ZOpcodes

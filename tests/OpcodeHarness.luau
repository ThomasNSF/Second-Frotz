---------------------------------------------------------------------
-- Shared helpers for the ZOpcodes test scripts (OpcodeTests,
-- MathOpcodeTests, ObjectOpcodeTests).
--
-- Builds synthetic bytecode in scratch RAM and runs it through
-- ZOpcodes.step(). Every helper takes the ZState explicitly, so the
-- module holds no fixture of its own; each test script owns its loaded
-- ZMemory. Split out of the original single OpcodeTests script, which
-- outgrew the script memory limit.
---------------------------------------------------------------------

local ZState = require("../VM/ZState.luau")
local ZOpcodes = require("../VM/ZOpcodes.luau")
local TestFramework = require("TestFramework.luau")

local assertEqual = TestFramework.assertEqual
local scratchBase = TestFramework.scratchBase
local writeBytesAt = TestFramework.writeBytesAt

-- Writes bytecode into scratch RAM and returns its address.
local function writeBytecode(state: ZState.ZState, bytes: {number}): number
    return writeBytesAt(state, scratchBase(state), bytes)
end

-- Inverts ZState:unpackRoutine for a given byte address (mirrors the
-- same helper in StateTests.luau), so tests can construct real callable
-- routines at addresses they fully control.
local function packRoutineAddress(state: ZState.ZState, byteAddress: number): number
    local version = state.header.version
    if version <= 3 then
        return byteAddress / 2
    elseif version <= 5 then
        return byteAddress / 4
    elseif version <= 7 then
        return (byteAddress - state.header.routinesOffset * 8) / 4
    else
        return byteAddress / 8
    end
end

-- Builds the specifier byte and operand bytes for up to four large-
-- constant operands (00 = large constant, 11 = omitted). Large constants
-- are the only operand encoding that can carry any 16-bit value, such
-- as a negative number.
local function largeConstantOperands(operands: {number}): (number, {number})
    local specifier = 0
    local bytes = {}
    for i = 1, 4 do
        local used = i <= #operands
        specifier = specifier * 4 + (used and 0 or 3)
        if used then
            table.insert(bytes, bit32.rshift(operands[i], 8))
            table.insert(bytes, bit32.band(operands[i], 0xFF))
        end
    end
    return specifier, bytes
end

-- Runs one instruction: `prefix` opcode byte(s), a specifier, large-
-- constant operands, then `trailing` (store or branch byte). Returns the
-- address it was written at and its total length.
local function execInstruction(state: ZState.ZState, prefix: {number}, operands: {number}, trailing: {number}): (number, number)
    local specifier, operandBytes = largeConstantOperands(operands)
    local bytes = table.clone(prefix)
    table.insert(bytes, specifier)
    for _, b in ipairs(operandBytes) do
        table.insert(bytes, b)
    end
    for _, b in ipairs(trailing) do
        table.insert(bytes, b)
    end
    local base = writeBytecode(state, bytes)
    state.pc = base
    ZOpcodes.step(state)
    return base, #bytes
end

-- Runs a `var`-table opcode in VAR form and returns what it stored to
-- variable 0. (2OP opcodes work in VAR form because the table is shared.)
local function evalVar(state: ZState.ZState, opNumber: number, operands: {number}): number
    execInstruction(state, { 0xC0 + opNumber }, operands, { 0 })
    return state:pop()
end

-- Same for an EXT opcode (0xBE prefix).
local function evalExt(state: ZState.ZState, extOpcode: number, operands: {number}): number
    execInstruction(state, { 0xBE, extOpcode }, operands, { 0 })
    return state:pop()
end

-- Runs a branching `var`-table opcode with an on-true short branch of
-- offset 10, and reports whether the branch was taken.
local function branches(state: ZState.ZState, opNumber: number, operands: {number}): boolean
    local base, length = execInstruction(state, { 0xC0 + opNumber }, operands, { 0xCA })
    if state.pc == base + length + 8 then
        return true
    end
    assertEqual(state.pc, base + length, "pc should be the branch target or just past the branch byte")
    return false
end

-- Runs a 1OP-form instruction with a large-constant operand, then
-- `trailing` (store and/or branch bytes). Returns its address and length.
local function exec1op(state: ZState.ZState, opNumber: number, operand: number, trailing: {number}): (number, number)
    local bytes = { 0x80 + opNumber, bit32.rshift(operand, 8), bit32.band(operand, 0xFF) }
    for _, b in ipairs(trailing) do
        table.insert(bytes, b)
    end
    local base = writeBytecode(state, bytes)
    state.pc = base
    ZOpcodes.step(state)
    return base, #bytes
end

-- Asserts consecutive bytes starting at addr.
local function assertBytes(state: ZState.ZState, addr: number, expected: {number}, message: string?)
    for i, want in ipairs(expected) do
        assertEqual(state.memory:readU8(addr + i - 1), want, (message or "byte") .. " " .. (i - 1))
    end
end

-- Runs scan_table with a store byte then an on-true offset-10 branch;
-- returns the stored address and whether the branch was taken.
local function scan(state: ZState.ZState, operands: {number}): (number, boolean)
    local base, length = execInstruction(state, { 0xC0 + 0x37 }, operands, { 0, 0xCA })
    local found = state:pop()
    return found, state.pc == base + length + 8
end

-- Packs Z-characters three to a word, padding with 5 and setting the end
-- bit on the last word.
local function packZchars(zchars: {number}): {number}
    local words = {}
    for i = 1, #zchars, 3 do
        table.insert(words, (zchars[i] * 32 + (zchars[i + 1] or 5)) * 32 + (zchars[i + 2] or 5))
    end
    words[#words] += 0x8000
    return words
end

-- The same words as big-endian bytes, for splicing into bytecode.
local function zstringBytes(zchars: {number}): {number}
    local bytes = {}
    for _, word in packZchars(zchars) do
        table.insert(bytes, bit32.rshift(word, 8))
        table.insert(bytes, bit32.band(word, 0xFF))
    end
    return bytes
end

return {
    zstringBytes = zstringBytes,
    writeBytecode = writeBytecode,
    packRoutineAddress = packRoutineAddress,
    execInstruction = execInstruction,
    evalVar = evalVar,
    evalExt = evalExt,
    branches = branches,
    exec1op = exec1op,
    assertBytes = assertBytes,
    scan = scan,
}

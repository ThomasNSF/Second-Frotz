---------------------------------------------------------------------
-- Object table access for the Z-machine object system.
--
-- Stateless: every function takes a ZState and derives the layout from
-- its header's version. All of them read story memory, so they may
-- yield and must run inside the VM coroutine. Callers are responsible
-- for guarding object 0 before calling (the opcodes each report their
-- own "called with object 0" warning and use a defined fallback), as in
-- Frotz.
---------------------------------------------------------------------

local ZState = require("ZState.luau")

local ERR_ILL_OBJ = ZState.Errors.ILL_OBJ

type Layout = {
    entrySize: number,       -- bytes per object entry
    defaultsSize: number,    -- property defaults table preceding object 1
    propertyOffset: number,  -- offset within an entry of the property-table pointer
    maxObject: number,       -- highest legal object number
    parentOffset: number,    -- link fields within an entry
    siblingOffset: number,
    childOffset: number,
    linksAreWords: boolean,  -- V4+ links are 16-bit, V1-V3 are 8-bit
}

-- V1-V3: 9-byte entries (4 attribute bytes, 1-byte parent/sibling/child).
local V1_LAYOUT: Layout = {
    entrySize = 9, defaultsSize = 62, propertyOffset = 7, maxObject = 255,
    parentOffset = 4, siblingOffset = 5, childOffset = 6, linksAreWords = false,
}
-- V4+: 14-byte entries (6 attribute bytes, 2-byte parent/sibling/child).
local V4_LAYOUT: Layout = {
    entrySize = 14, defaultsSize = 126, propertyOffset = 12, maxObject = 65535,
    parentOffset = 6, siblingOffset = 8, childOffset = 10, linksAreWords = true,
}

local function layoutFor(state: ZState.ZState): Layout
    return if state.header.version <= 3 then V1_LAYOUT else V4_LAYOUT
end

local ZObject = {}

-- Returns the address of an object's entry. Mirrors object_address
-- (object.c): an object number above the version's maximum, or an entry
-- that would fall outside dynamic memory, is a fatal ERR_ILL_OBJ.
function ZObject.address(state: ZState.ZState, obj: number): number
    local layout = layoutFor(state)
    if obj > layout.maxObject then
        state:runtimeError(ERR_ILL_OBJ)
    end
    local addr = state.header.objects + (obj - 1) * layout.entrySize + layout.defaultsSize
    if addr + layout.entrySize >= state.header.staticMemoryBase then
        state:runtimeError(ERR_ILL_OBJ)
    end
    return addr
end

local function readLink(state: ZState.ZState, obj: number, offset: number): number
    local addr = ZObject.address(state, obj) + offset
    if layoutFor(state).linksAreWords then
        return state.memory:readU16(addr)
    end
    return state.memory:readU8(addr)
end

-- Tree links. Callers must guard object 0 first; see the module header.
function ZObject.parent(state: ZState.ZState, obj: number): number
    return readLink(state, obj, layoutFor(state).parentOffset)
end

function ZObject.sibling(state: ZState.ZState, obj: number): number
    return readLink(state, obj, layoutFor(state).siblingOffset)
end

function ZObject.child(state: ZState.ZState, obj: number): number
    return readLink(state, obj, layoutFor(state).childOffset)
end

local ERR_STORE_RANGE = ZState.Errors.STORE_RANGE

local function writeLink(state: ZState.ZState, obj: number, offset: number, value: number): ()
    local addr = ZObject.address(state, obj) + offset
    local ok = if layoutFor(state).linksAreWords
        then state.memory:writeU16(addr, value)
        else state.memory:writeU8(addr, value)
    -- ZObject.address guarantees the entry lies in dynamic memory, so a
    -- refused write should be impossible; report it rather than ignore it.
    if not ok then
        state:runtimeError(ERR_STORE_RANGE)
    end
end

function ZObject.setParent(state: ZState.ZState, obj: number, value: number): ()
    writeLink(state, obj, layoutFor(state).parentOffset, value)
end

function ZObject.setSibling(state: ZState.ZState, obj: number, value: number): ()
    writeLink(state, obj, layoutFor(state).siblingOffset, value)
end

function ZObject.setChild(state: ZState.ZState, obj: number, value: number): ()
    writeLink(state, obj, layoutFor(state).childOffset, value)
end

-- Detaches an object from its parent and siblings; its own children stay
-- with it. Mirrors unlink_object (object.c), which calls the sibling
-- link "older sibling". Callers guard object 0 first.
--
-- Deviation: if the object names a parent but is missing from that
-- parent's child chain (a corrupt tree), Frotz walks on through garbage;
-- this raises ERR_ILL_OBJ when the chain ends instead.
function ZObject.unlink(state: ZState.ZState, obj: number): ()
    local parent = ZObject.parent(state, obj)
    if parent == 0 then
        return
    end

    local nextSibling = ZObject.sibling(state, obj)
    ZObject.setParent(state, obj, 0)
    ZObject.setSibling(state, obj, 0)

    local previous = ZObject.child(state, parent)
    if previous == obj then
        ZObject.setChild(state, parent, nextSibling)
        return
    end

    -- Find the chain entry whose sibling link points at obj.
    while true do
        local following = ZObject.sibling(state, previous)
        if following == obj then
            break
        end
        if following == 0 then
            state:runtimeError(ERR_ILL_OBJ)
        end
        previous = following
    end
    ZObject.setSibling(state, previous, nextSibling)
end

-- Makes obj the first child of dest. Mirrors z_insert_obj (object.c).
-- Both objects are validated before anything changes, as in C, and
-- dest's child is read AFTER the unlink: if obj was already dest's first
-- child, the unlink is what moves that link along.
function ZObject.insert(state: ZState.ZState, obj: number, dest: number): ()
    ZObject.address(state, obj)
    ZObject.address(state, dest)

    ZObject.unlink(state, obj)
    ZObject.setParent(state, obj, dest)
    local firstChild = ZObject.child(state, dest)
    ZObject.setChild(state, dest, obj)
    ZObject.setSibling(state, obj, firstChild)
end

-- Returns the address of an object's short name, which is also the start
-- of its property table. Mirrors object_name (object.c), whose name is
-- misleading: it returns an address, not text.
function ZObject.nameAddress(state: ZState.ZState, obj: number): number
    local entry = ZObject.address(state, obj)
    return state.memory:readU16(entry + layoutFor(state).propertyOffset)
end

-- Returns the address of an object's first property: past the short
-- name's length byte and its words. Mirrors first_property (object.c).
function ZObject.firstProperty(state: ZState.ZState, obj: number): number
    local nameAddr = ZObject.nameAddress(state, obj)
    local nameWords = state.memory:readU8(nameAddr)
    return nameAddr + 1 + 2 * nameWords
end

-- Returns the address of the property following the one at propAddr
-- (which points at a size byte). Mirrors next_property (object.c),
-- including its handling of the three size encodings: V1-V3 stores
-- size - 1 in the top three bits; V4+ stores it in the top two bits
-- (bit 7 clear), or, with bit 7 set, in the low six bits of a second
-- byte where 0 means 64 (Spec 1.0).
function ZObject.nextProperty(state: ZState.ZState, propAddr: number): number
    local sizeByte = state.memory:readU8(propAddr)
    propAddr += 1

    local dataLength: number
    if state.header.version <= 3 then
        dataLength = bit32.rshift(sizeByte, 5)
    elseif bit32.band(sizeByte, 0x80) == 0 then
        dataLength = bit32.rshift(sizeByte, 6)
    else
        dataLength = bit32.band(state.memory:readU8(propAddr), 0x3F)
        if dataLength == 0 then
            dataLength = 64
        end
    end

    return propAddr + dataLength + 1
end

-- Bits of a property's size byte that hold its number.
function ZObject.propertyMask(state: ZState.ZState): number
    return if state.header.version <= 3 then 0x1F else 0x3F
end

-- Scans an object's property list, which descends by number, for the first
-- property whose number is <= id: the property itself when it exists,
-- otherwise the next lower one (or the 0 terminator). Returns that
-- property's size-byte address and the size byte. This is the scan loop
-- shared by z_get_prop, z_get_prop_addr and z_put_prop (object.c).
function ZObject.findProperty(state: ZState.ZState, obj: number, id: number): (number, number)
    local mask = ZObject.propertyMask(state)
    local addr = ZObject.firstProperty(state, obj)
    while true do
        local sizeByte = state.memory:readU8(addr)
        if bit32.band(sizeByte, mask) <= id then
            return addr, sizeByte
        end
        addr = ZObject.nextProperty(state, addr)
    end
end

-- Length in bytes of the property whose data starts at dataAddr, decoded
-- from the size byte just before it. Mirrors the length calculation in
-- z_get_prop_len (object.c).
function ZObject.dataLength(state: ZState.ZState, dataAddr: number): number
    local sizeByte = state.memory:readU8(dataAddr - 1)
    if state.header.version <= 3 then
        return bit32.rshift(sizeByte, 5) + 1
    elseif bit32.band(sizeByte, 0x80) == 0 then
        return bit32.rshift(sizeByte, 6) + 1
    end
    local length = bit32.band(sizeByte, 0x3F)
    return if length == 0 then 64 else length
end

return ZObject

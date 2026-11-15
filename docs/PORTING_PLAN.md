# Lua-Frotz Porting Plan

This document is the working plan for porting the Frotz Z-Machine interpreter into Luau, with an eye toward Second Life Lua environment constraints.

## Goal

Create a Luau-based Z-Machine interpreter inspired by the Frotz codebase, preserving the core semantics of the VM while replacing OS-specific and terminal-specific layers with a runtime adapter for Second Life.

## Scope

### In scope
- Z-machine bytecode interpreter core
- Story file header parsing
- VM memory model
- Stack and frame management
- Opcode dispatch
- Variable and branch logic
- Input/output abstraction
- Save/restore state support
- Basic screen/text output support for a UI host

### Out of scope for the first version
- Full SDL/X11/DOS frontend parity
- Full Blorb support
- Advanced sound, graphics, and window management
- Every edge-case story compatibility quirk from the original Frotz
- Exact terminal behavior from original Unix/C builds
- Z-machine V6 (pictures, pixel windows, mouse, menus). V1-V5, V7 and V8 are supported; a V6 story is refused at load by `ZMemory:readHeader`.

Measured budget (Phase 4 probe, `tests/MemoryProbe.luau`): the 128 KB limit holds about 49 KB of compiled code for the core modules at start, plus ~15 KB of tables built when they load. After the story (14.4 KB) and a `ZState` (3.9 KB) are loaded, about 48 KB is free. `step` allocates nothing. Text decoding and output stay in the core as modules (`ZText`, `ZOutput`) that take explicit arguments and never require `ZState` or `ZOpcodes`, so moving either into its own script later is cheap. Revisit the split if free memory after story and state load falls below about 20 KB; Save/Load is the likeliest first script to leave the core.

## High-level architecture

### Layer 1: VM core
This is the portable interpreter core. It should mirror the structure of the Frotz common code:

- story loading and lifecycle
- virtual memory interface
- header parsing
- opcode interpreter loop
- stack frame operations
- branch/store semantics

### Layer 2: Memory manager
This script owns all ROM and paging responsibilities. It is the page server for the VM and deals with the Second Life constraints directly.

- notecard-backed ROM storage
- Base64 page encoding/decoding
- page fault handling
- page request/response protocol
- linkset persistence for save state and metadata
- page cache and eviction policy

### Layer 3: Host adapter
This layer isolates the interpreter from the host environment.

- output text rendering
- input capture
- save/load data persistence
- timer/event integration
- optional script/logging

### Layer 4: Second Life bridge
This is the environment-specific layer that translates the host adapter into Second Life APIs:

- chat or dialog entry
- UI panels
- link messages
- event-driven updates
- persistent storage access through linkset data

## Porting strategy

### Phase 1: Understand the VM model

Study and extract the core semantics from Frotz:

- story header schema
- memory layout and access macros
- PC/SP/FP model
- stack frame calling convention
- global variable layout
- 8-bit / 16-bit arithmetic rules
- opcode families and dispatch tables

Primary files to use as references:

- `Frotz/src/common/frotz.h`
- `Frotz/src/common/setup.h`
- `Frotz/src/common/process.c`
- `Frotz/src/common/fastmem.c`
- `Frotz/src/common/variable.c`

### Phase 2: Build a core memory abstraction

Replace the C memory model with a Luau-friendly equivalent:

- byte array or buffer abstraction
- helpers for reading/writing 8-bit and 16-bit fields
- signed arithmetic for 16-bit values
- address validation and bounds checks
- story header readers

Deliverable:
- A `Memory` or `ZMemory` module with helpers like:
  - `readU8(addr)`
  - `readU16(addr)`
  - `writeU8(addr, value)`
  - `writeU16(addr, value)`
  - `readSigned16(addr)`

### Phase 3: Implement execution state

Encode the interpreter’s runtime state:

- `pc` program counter
- `sp` stack pointer
- `fp` frame pointer
- stack array
- local variables per frame
- current story header
- flags and runtime configuration

Deliverable:
- `ZMachineState` object or table containing all runtime state

### Phase 4: Port opcode dispatch

Implement the opcode execution model in Luau.

Categories:
- 0OP opcodes
- 1OP opcodes
- 2OP opcodes
- VAR opcodes
- EXT opcodes

We should start with a subset of common opcodes before trying to support the full spec.

Milestone order:
1. control flow and branching
2. stack operations
3. variable load/store
4. arithmetic
5. object/property operations
6. I/O and text output
7. extended opcodes

### Phase 5: Implement the game loop

Create a loop that:

- fetches the next opcode
- loads operands
- dispatches to the correct handler
- updates the program counter
- handles return and branching logic
- stops when the story ends or calls `quit`

This should mirror Frotz’s top-level `interpret()` loop.

### Phase 6: Add host I/O abstraction

Wrap the VM from the OS/UI boundary:

- `printString(text)`
- `readInput(prompt)`
- `clearScreen()`
- `getChar()`
- `statusLine()`
- `setWindowState()`

This layer is essential because the core VM must remain independent from Second Life UI details.

### Phase 7: Add Second Life integration

Build the runtime bridge for Second Life Luau.

- source story data from script assets or serialized bytes
- feed output into chat or UI
- accept user input from chat or a menu
- render status updates in a visible panel
- keep the game loop event-driven to fit script runtime constraints

### Phase 8: Compatibility and debugging

After the core is stable, add debugging tools:

- opcode trace mode
- memory dump helpers
- stack dump
- frame dump
- story header diagnostics
- mismatch detection between expected and observed behavior

### Phase 9: Performance and reliability

Tune the implementation for the Second Life environment:

- minimize allocations
- avoid excessive per-instruction object churn
- keep opcode handlers simple
- profile hot loops
- reduce memory fragmentation

## Recommended implementation order

### Milestone 1: Memory + header parsing
- decode story header
- load story bytes
- validate version and file size
- implement read/write helpers

### Milestone 2: Basic opcode runtime
- `z_rtrue`, `z_rfalse`
- `z_print`, `z_print_ret`, `z_new_line`
- arithmetic and variable store
- simple branching

### Milestone 3: Subroutine calls and frames
- `call`/`ret`
- stack frame layout
- local variables

### Milestone 4: Text and input
- output string handling
- dictionary and tokenization support if needed
- user input loop

### Milestone 5: Objects and properties
- object tree traversal
- attribute checks
- property reads/writes

### Milestone 6: Full-ish compatibility pass
- version-specific behavior
- edge cases for V5–V8
- save/restore behavior

## File plan for the Lua-Frotz repo

Suggested structure:

```text
Lua-Frotz/
  PORTING_PLAN.md
  docs/
    architecture.md
    opcode-reference.md
    memory-model.md
  VM/
    Memory.lua
    State.lua
    Opcode.lua
    Interpreter.lua
    Header.lua
    Stack.lua
    IO.lua
    HostAdapter.lua
    Main.lua
```

## Coding rules for the port

- Keep the core VM logic independent from the host runtime.
- Prefer table-driven dispatch and explicit state objects.
- Preserve signed 16-bit semantics exactly.
- Treat the story file as a memory image, not as a game object.
- Do not port the OS-specific C frontends directly.
- Validate behavior against known Z-machine test stories when possible.

## Phase 1: VM foundation and memory model

This is the first major milestone. The goal is to build the foundational interpreter layer without trying to run full game logic yet. Phase 1 should produce a minimal but reliable in-memory Z-machine runtime that can parse a story header and expose accurate memory access helpers.

### Phase 1 goal

Create a Luau module set that can:

- load a Z-code story file into memory
- parse the initial story header correctly
- read and write byte/word values using the same semantics as Frotz
- maintain a valid runtime state structure
- support a basic fetch/decode loop for the first opcode set

### Phase 1 deliverables

By the end of Phase 1, we should have:

- a `Memory` module
- a `Header` module
- a `State` module
- a minimal `Interpreter` loop
- a small test harness that loads a story and prints header data

### Phase 1 technical breakdown

#### Critical design note: 128K total memory budget

This project is not operating in a normal desktop memory model. The runtime will need to fit within a hard maximum of 128K for code plus heap. A flat, eager story image is not reliable for large Z-machine games, especially once we include interpreter logic and working state.

We need a paged virtual-memory design from the start, and we should keep the ROM and page servicing outside the main VM script.

Recommended approach:

- Keep only the active pages resident in the VM heap.
- Store the complete story as a ROM source in notecards or serialized persistent data.
- Treat the story as a virtual address space, not a single dense array.
- Page in only the code or data region currently needed by the interpreter.
- Maintain a small page cache with a simple eviction policy.
- Route page access through a dedicated memory manager script.

A practical first design is:

- page size: 762 bytes
- page cache: keep the memory-manager cache bounded; the current implementation uses 10 entries
- virtual address: Z-machine address mapped to a one-based `pageNumber` and one-based Lua `byteOffset`
- page table: track whether a page is loaded and whether it is dirty
- lazy load: fetch a page from storage only when the interpreter touches it
- transport format: Base64 page payloads through `llLinkMessage`

This design keeps the interpreter compatible with the original Frotz memory model while reducing the live heap footprint in a constrained environment.

#### Measured memory budget

Script memory is 131,072 bytes (128 KB) for code plus heap. Measurements from the Phase 4 runs (`tests/MemoryProbe.luau`, Adventureland, V5). The preprocessor inlines every `require`, so compiled code is already counted in the memory in use when a script starts:

| Item | Bytes |
| --- | --- |
| In use at script start (compiled code of the core modules) | ~49,500 |
| Tables and closures built when the modules load | ~15,200 |
| Story load, flat `ram` buffer (8,508 bytes of dynamic memory) plus overhead | ~14,400 |
| `ZState.new` (stack buffer and tables) | ~3,900 |
| Free after load, before the text and print code | ~48,000 |

The text and print path (`ZText`, `ZOutput` and the print opcodes) then cost about 9 KB, leaving roughly 38 KB. `ZState:step` allocates nothing in steady state.

Two earlier findings shaped the numbers: `ZMemory:initialize` used to leave the last 10 dynamic-memory pages (~7.6 KB) in the ROM cache although nothing read them again, so it now clears the cache when initialization ends; and the VM-side ROM cache is 4 pages (~3 KB) while the Memory Manager script keeps its own separate cache. `ZMemory.romCacheMisses` counts ROM page faults so the cache size can be tuned against real play.

Revisit splitting scripts if free memory after story and state load falls below about 20 KB.

#### Dynamic memory is the scaling problem

The flat `ram` buffer costs one byte per byte of dynamic memory, and dynamic memory varies enormously between stories: 8,508 bytes for Adventureland, but 32,019 bytes for `zdungeon` (`staticMemoryBase` = 0x7D13), and up to 64 KB in the worst case. With zdungeon the flat buffer alone would leave only about 15 KB free, under the 20 KB line above, so RAM is paged out to LinksetData (LSD).

#### Paging dynamic memory to LinksetData

LSD is a per-linkset key/value store with synchronous access, so a RAM page fault does not yield, unlike a ROM page fault. Findings from `tests/LsdProbe.luau`:

| Question | Result |
| --- | --- |
| Raw binary values | Not supported. Writing bytes 0-255 as a string returned status 4 and read back empty. Pages must be Base64 encoded. |
| Base64 round trip | A 256-byte page is 344 characters and returns identical. |
| Value size | Values up to 16,384 characters were accepted. |
| Key size | Keys up to 1,030 bytes were accepted. |
| Capacity accounting | 131,072 bytes per linkset. An entry costs exactly key length plus value length, with no per-entry overhead. |
| Speed, per 256-byte page | Write 55 us, read 58 us, Base64 decode 110 us, encode 109 us. |
| Events | Writes raise `linkset_data` in scripts that register a handler; about 415 writes delivered 15 events to the probe. The VM registers no handler. |

Consequences: a clean page fault (read plus decode) costs about 170 us, and a fault that must first write back a dirty page about 330 us. A story with 32,019 bytes of dynamic memory is 126 pages, about 45 KB of LSD (344 characters of Base64 plus an 11-14 character key per page); the worst case of 64 KB is about 91 KB. Every story therefore fits, but copies add up: two zdungeon copies are about 90 KB, and a third does not fit in the 128 KB store (a test run hit status 1, LINKSETDATA_EMEMORY, at 368 keys). A story under about 50 KB of dynamic memory can keep a second copy (undo or restart snapshot) in LSD; a larger one cannot.

**Implemented** in `ZMemory.luau` (validated in-world by `tests/RamPagingTests.luau` against Adventureland and zdungeon; the public API did not change and the `ram` buffer is used nowhere else):

- Dynamic memory of at most `RAM_FLAT_LIMIT` (16,384 bytes) stays in one flat buffer (`ramPaged` is false) and never touches LSD. Larger dynamic memory is paged.
- Paged RAM is divided into 256-byte pages stored in LSD as Base64 under `<prefix>_<pageIndex>` keys. The default prefix is `zr` plus the first 8 characters of the script key, which is stable across resets; `ramKeyPrefix` can be set before `initialize` (tests do this to run several instances).
- Up to `RAM_RESIDENT_PAGES` (16, about 4 KB) decoded pages are resident, in LRU order. Consecutive accesses to the same page take a shortcut (`ramLastPage`) that skips the LRU bookkeeping. `ramMaxResident` must be at least 2.
- Writes mark the page dirty; evicting a dirty page encodes it and writes it back. A write status of 0 (OK) or 5 (NOUPDATE, value unchanged) counts as success; anything else raises an error that includes the prefix, bytes available and key count.
- `seedRam()` rebuilds RAM from the pristine story image through the ROM path (it yields on ROM faults). `initialize` calls it, and `restart` will call it too.
- `releaseRam()` drops the resident pages and deletes every LSD key matching `^<prefix>_[0-9]+$` (`ll.LinksetDataFindKeys` with a 1-based start index and count 0 for all), not just the pages this instance knows about. `seedRam` calls it first, so loading a card removes pages left by an earlier story, a larger story, an aborted run or a script reset. Instances with different prefixes do not affect each other.
- `flush()` writes every dirty resident page back to LSD, for Save/Load and any code that reads the pages directly.
- Counters `ramFaults` and `ramWritebacks` (reset at the end of `initialize`) parallel `romCacheMisses`, so the page size and resident count can be tuned from real play. They have not yet been measured under play, because that needs the Phase 5 driver.

The page size, resident count and flat threshold are constants in `ZMemory`; `ramFlatLimit` and `ramMaxResident` are also fields that can be set before `initialize`. Measured with zdungeon, the script keeps about 1 KB of RAM pages resident (3 pages in the test) instead of a 32 KB flat buffer.

#### Script split for the port

The interpreter will be split into multiple scripts to honor Second Life constraints.

1. VM core script
   - owns the program flow, stack, registers, and opcode execution
   - requests pages from the memory manager when the VM touches unmapped memory
   - keeps its own working state lean and deterministic

2. Memory manager script
   - owns the ROM source, page map, and cache
   - reads page data from a notecard or persisted store
   - Base64-encodes pages for notecard storage and link messages
   - answers `PAGE_REQ` messages with `PAGE_RES`
   - tracks dirty pages and persistent metadata

3. UI adapter script (optional later)
   - owns text rendering, input capture, and chat integration
   - keeps the VM focused on the Z-machine logic

This is the architecture we will follow for all Phase 1 work.

#### Step 0: establish the ROM/RAM boundary

The Z-machine does not divide memory according to which script stores a page. It divides the story address space according to the `static memory base` field in the story header. The VM must establish this boundary before it implements general reads and writes.

Implementation steps:

1. Read the story header from the memory manager and parse the static-memory-base address from the story image.
2. Store the boundary in the VM header state as `staticMemoryBase`.
3. Store the total story size, derived from the header and ROM metadata, as `storySize`.
4. Define the address regions using Z-machine story addresses:
    - dynamic memory (RAM): `0 <= address < staticMemoryBase`
    - static memory (ROM): `staticMemoryBase <= address < storySize`
    These numeric addresses describe the story format; they are not Lua table indices.
5. Reject addresses below zero or at/above `storySize` before performing any access.
6. Route dynamic-memory reads and writes to VM-owned RAM storage.
7. Route static-memory reads to the ROM page service and its local page cache.
8. Reject writes to static memory. The interpreter should report a VM memory error or return a controlled failure according to the error policy selected for Phase 1.

The boundary is per address, not per physical page. A page may contain bytes on both sides of the boundary, so the memory abstraction must classify each byte address before reading or writing it. The page manager should remain unaware of Z-machine mutability rules; it serves serialized story pages, while the VM enforces the ROM/RAM contract.

#### Step 0.1: choose the RAM representation

Implement dynamic memory as VM-owned storage rather than as another notecard-backed cache.

1. Allocate only the dynamic-memory range required by the story, subject to the 128K total code-plus-heap budget.
2. Choose a compact representation supported by the target SLua runtime, such as a `buffer` when available. A story with little dynamic memory keeps it in one flat `buffer`; a larger one is paged out to LinksetData with a small resident set (see "Paging dynamic memory to LinksetData"). Either way the `ZMemory` API is the same and RAM access never yields.
3. Initialize RAM from the corresponding story bytes before execution begins.
4. Keep RAM separate from the read-only ROM page cache so a write can never mutate a cached ROM buffer accidentally.
5. Track the dynamic-memory range explicitly; do not infer writability from cache membership.
6. Reserve a later extension point for save/restore snapshots of RAM, stack, and execution state.

#### Step 0.2: define the memory API contract

Create `VM/MemoryAPI.luau` constants for the transport protocol and a required VM memory module at `VM/ZMemory.luau` for address operations. `ZMemory.luau` should return a module table; it should not create a singleton memory instance when it is required.

The intended dependency pattern is:

```luau
local ZMemory = require("ZMemory.luau")

local memory = ZMemory.new({
    pageSize = header.pageSize,
    staticMemoryBase = header.staticMemoryBase,
    storySize = header.storySize,
})
```

The interpreter and state modules should receive the `memory` instance explicitly. They should not require the memory manager directly or access its page cache. This keeps module loading separate from VM instance state and allows multiple VM instances to use the same implementation later.

#### Asynchronous memory-access invariant

All memory reads in the VM are asynchronous from the caller's perspective. A read may need to request a ROM page, wait for a link-message response, and resume later. The API must therefore be designed so that even a read which is currently satisfied from RAM or cache can be called from the same coroutine-based execution path as a cold ROM read.

Implementation rules:

1. Run the interpreter fetch/decode/execute loop inside a `CoroutineMgr` task.
2. Permit every `readU8`, `readU16`, `readS16`, and string-read operation to yield.
3. Do not create separate synchronous and asynchronous read APIs; that would force opcode handlers to know where the data came from.
4. Treat a RAM or cache hit as an immediately resumable asynchronous operation, not as a different public contract.
5. Keep writes non-yielding only if the target address is already locally owned RAM; ROM writes must fail before any transport operation.
6. Make page-request timeouts and malformed responses return controlled read failures to the suspended VM task.
7. Ensure the program counter and opcode state are preserved while a memory read is suspended.

This means the memory API's apparent return value is produced after the coroutine resumes. Any caller that performs a memory read must already be running inside the VM task or another coroutine capable of yielding.

The VM memory module should expose typed operations with explicit failure behavior:

```luau
readU8(address: number): number
readU16(address: number): number
readS16(address: number): number
writeU8(address: number, value: number): boolean
writeU16(address: number, value: number): boolean
```

Because all reads may yield, the API will run VM execution inside a coroutine and allow the read functions to suspend that task while a `PAGE_REQ` is outstanding. Callback-based read variants are not part of the core VM API. The existing `CoroutineMgr` is responsible for resuming the suspended task.

#### Step 0.3: handle boundary-crossing words

Implement 16-bit reads and writes as two ordered byte operations:

1. Validate both `address` and `address + 1`.
2. Classify each byte independently as RAM or ROM.
3. Read the high byte and low byte in the Z-machine's big-endian order.
4. Combine them into an unsigned 16-bit value.
5. For signed reads, convert values from `0x8000..0xFFFF` to `-32768..-1`.
6. Reject a word write if either byte is in ROM; do not partially modify RAM.

This prevents a word operation crossing the dynamic/static boundary from silently violating write protection.

#### Step 0.4: define page-request ownership

The VM-side memory module owns request correlation and local ROM-page residency. The memory manager owns notecard access and its own service-side LRU cache.

For each ROM cache miss:

1. Compute the one-based `pageNumber` and one-based Lua `byteOffset`:
    - `pageNumber = math.floor(address / pageSize) + 1`
    - `byteOffset = (address % pageSize) + 1`
    If a low-level `buffer` API requires a zero-based byte offset, convert only at that API boundary with `byteOffset - 1`.
2. Allocate a unique `requestId`.
3. Send `PAGE_REQ` on `MemoryAPI.MEMORY_CHANNEL`.
4. Yield until the matching `PAGE_RES` arrives or the timeout expires.
5. Validate `pageNumber`, `pageSize`, and the decoded buffer length.
6. Insert the page into the VM's local ROM cache.
7. Resume the pending read.

The VM must never accept a response solely because it arrived on the correct channel. It must match both `requestId` and `pageNumber` to the pending request.

#### Step 0.5: verify asynchronous reads before opcode work

Build focused tests before implementing the interpreter loop:

1. Read the first and last byte of RAM from inside the VM coroutine.
2. Write and read back RAM bytes through the same asynchronous read API.
3. Attempt a ROM write and verify that the ROM buffer is unchanged.
4. Read a ROM byte on a cold cache and verify that the VM task suspends and a page request is sent.
5. Read the same ROM byte again and verify that the task resumes without another page request.
6. Read a word entirely in RAM and verify that both byte reads follow the same contract.
7. Read a word entirely in ROM.
8. Read a word crossing the RAM/ROM boundary.
9. Attempt a word write crossing the boundary and verify that no RAM byte changes.
10. Suspend a read, resume it with a matching page response, and verify the returned value.
11. Simulate a timeout, missing response, malformed response, and mismatched response.
12. Request an invalid address and verify the selected error behavior.

Only after these cases pass should header-derived addresses be used by opcode handlers.

#### Step 1: implement `ZMemory.luau` as a required module

Create `VM/ZMemory.luau` as the required module that handles the story file as a paged virtual-memory layer and exposes safe low-level accessors.

Implementation steps:

1. Define and export the configuration and instance types needed by the module.
2. Define `ZMemory.new(config)` as the only constructor for a memory instance.
3. Keep ROM cache state, RAM storage, pending requests, and request IDs inside the returned instance.
4. Keep protocol constants imported from `MemoryAPI.luau`; do not duplicate channel or message strings.
5. Require `ZMemory.luau` from the interpreter and construct the instance during story initialization.
6. Pass the constructed instance to the interpreter, header reader, and opcode handlers that need memory access.
7. Return the module table from `ZMemory.luau`, not a preconstructed memory object.

Core requirements:

- `readU8(addr)`
- `readU16(addr)`
- `writeU8(addr, value)`
- `writeU16(addr, value)`
- `readSigned16(addr)`
- `readString(addr, maxLength)` (optional at first, useful for IDs and metadata)

Notes:

- Preserve Z-machine addresses as numeric story coordinates, but use one-based indexing for Lua tables and page arrays.
- Keep all values in numeric Lua types.
- Use bit operations for 8/16-bit masking and sign handling.
- Ensure out-of-range reads fail cleanly rather than silently returning garbage.

Implementation guidance:

```lua
local ZMemory = {}

function ZMemory.new(config)
    return {
        pageSize = config.pageSize,
        staticMemoryBase = config.staticMemoryBase,
        storySize = config.storySize,
        ram = config.ram,
        cache = {},
        pendingRequests = {},
    }
end

function ZMemory.readU8(mem, addr)
    local pageNumber = math.floor(addr / mem.pageSize) + 1
    local byteOffset = (addr % mem.pageSize) + 1
    local page = mem.cache[pageNumber]
    if not page then
        page = ZMemory.loadPage(mem, pageNumber)
    end
    return page[byteOffset]
end

function ZMemory.readU16(mem, addr)
    local hi = ZMemory.readU8(mem, addr)
    local lo = ZMemory.readU8(mem, addr + 1)
    return (hi * 256) + lo
end

function ZMemory.readSigned16(mem, addr)
    local value = ZMemory.readU16(mem, addr)
    if value >= 0x8000 then
        return value - 0x10000
    end
    return value
end

return ZMemory
```

The page manager will own the low-level ROM fetch and Base64 decode logic. The VM only sees a virtual-memory interface, and every read through that interface has the same coroutine-safe asynchronous contract.

#### Memory manager protocol

The memory manager script will process a page request message and answer with a Base64-encoded page payload.

Message contract:

```lua
-- VM -> memory manager
{
    type = "PAGE_REQ",
    pageNumber = 17,
    requestId = 42,
}

-- memory manager -> VM
{
    type = "PAGE_RES",
    pageNumber = 17,
    requestId = 42,
    pageSize = 762,
    pageB64 = "...base64 encoded page data..."
}
```

Notes:

- Raw bytes are never sent directly through `llLinkMessage`.
- The transport layer always carries Base64.
- The VM decodes `pageB64` back into raw bytes before caching it.
- The notecard itself stores the story as Base64 page lines to preserve text safety and avoid binary corruption.

#### Notecard ROM layout

Each notecard line contains one encoded page:

```text
ZROM1|1|762|pageCount|sha256-checksum
<base64 page 1>
<base64 page 2>
<base64 page 3>
```

A page should be sized so that it is a multiple of 3 and fits the notecard line limit cleanly.

Recommended Phase 1 value:

- `PAGE_SIZE = 762`
- one Base64 page is 1016 characters, which fits below the 1024-character line limit

The final page is zero-padded by the ROM conversion tool so all decoded pages have the configured size. Page numbers are one-based and inferred from the line order; no page-index prefix is stored in the notecard line.

#### Step 2: implement header parsing

The Frotz code reads the first 64 bytes from the story and extracts all of the initial header fields. We need equivalent logic in Lua.

Use the constants from Frotz as the reference set, especially in [Frotz/src/common/frotz.h](Frotz/src/common/frotz.h#L140-L177).

Required fields for Phase 1:

- version
- config
- release
- start PC
- dictionary
- objects
- globals
- dynamic size
- flags
- serial
- file size
- checksum
- interpreter number
- screen rows/cols
- default background/foreground

Phase 1 should validate at minimum:

- version is between V1 and V8
- file is non-empty
- file size is sane
- header values can be read without crashing

#### Step 3: create the runtime state object

The runtime state should mirror the state the C code maintains while running a story.

Required state:

- `memory` reference
- `pc`
- `sp`
- `fp`
- `stack`
- `localVariables`
- `frameCount`
- `header`
- `flags`
- `finished`
- `zargs`
- `zargc`

The state object should be a single place that the interpreter loop mutates.

This should replace the global-style state in the C source with a Lua table or class.

#### Step 4: define the initial execution loop

Implement a minimal VM fetch/decode loop.

Pseudo-structure:

```lua
while not state.finished do
    local opcode = Memory.readU8(state.memory, state.pc)
    state.pc = state.pc + 1

    if opcode < 0x80 then
        -- 2OP path
    elseif opcode < 0xB0 then
        -- 1OP path
    elseif opcode < 0xC0 then
        -- 0OP path
    else
        -- VAR path
    end
end
```

At this point, it does not need to support all opcodes. It only needs to be stable enough to run a tiny subset.

#### Step 5: implement the first opcode subset

The initial opcode set should be intentionally small but enough to prove the VM works.

Priority order:

1. `z_rtrue`
2. `z_rfalse`
3. `z_print`
4. `z_print_ret`
5. `z_new_line`
6. `z_jz`
7. `z_jump`
8. `z_get_sibling`
9. `z_get_child`
10. `z_store`
11. `z_inc`
12. `z_dec`

These cover the basics of:

- branch logic
- simple output
- stack flow
- variable updates

This should be enough to test a minimal story loop.

#### Step 6: build the test harness

Create a tiny script that loads a known Z-code story file and prints:

- story version
- release number
- serial number
- start PC
- file size
- global count

This proves the core memory and header parsing work correctly before we try to interpret more of the story.

Example output:

```text
Version: 5
Release: 15
Serial: 123456
Start PC: 0x1234
Story size: 245760
```

#### Step 7: validate against a tiny story

We need one or more very small story files or test games to validate the VM.

Good sources:

- built-in Z-machine test stories
- tiny handcrafted story file or opcode smoke test
- a minimal educational Z-code sample

Acceptance criteria for Phase 1:

- story loads without crash
- header is parsed without invalid values
- memory access helpers return correct values
- interpreter fetch loop runs at least one instruction
- one or more basic opcodes execute without error

### Phase 1 implementation checklist

#### Module checklist

- [ ] `Memory.lua` created
- [ ] `Header.lua` created
- [ ] `State.lua` created
- [ ] `Interpreter.lua` created
- [ ] `Main.lua` or `SmokeTest.lua` created

#### Memory checklist

- [ ] read U8 helper
- [ ] read U16 helper
- [ ] write U8 helper
- [ ] write U16 helper
- [ ] signed 16-bit helper
- [ ] address bounds guard

#### Header checklist

- [ ] parse version
- [ ] parse release
- [ ] parse start PC
- [ ] parse file size
- [ ] parse globals and object area offsets
- [ ] validate playable Z-machine version

#### Runtime state checklist

- [ ] program counter
- [ ] stack pointer
- [ ] frame pointer
- [ ] global stack array
- [ ] frame count
- [ ] current flags
- [ ] finished flag

#### Loop checklist

- [ ] fetch opcode
- [ ] decode opcode family
- [ ] load operands
- [ ] dispatch handler
- [ ] update PC
- [ ] stop on exit condition

### Phase 1 completion criteria

Phase 1 is complete when:

- a Z-code story file can be loaded into memory
- the story header is correctly parsed
- the VM state is initialized correctly
- the basic opcode fetch/decode loop executes
- the interpreter can run a minimal test sequence without crashing

### Phase 1 exit condition

We should not attempt Phase 2 until the following are true:

- memory model is stable
- header parsing is verified
- runtime state is sound
- at least a basic opcode subset executes properly

### Phase 1 follow-up tasks

After Phase 1 completes, the next natural steps are:

- implement deeper object/property opcodes
- add subroutine call/return support
- add text output and input abstraction
- add host adapter for Second Life

## Relevant Frotz references for Phase 1

- [Frotz/src/common/frotz.h](Frotz/src/common/frotz.h)
- [Frotz/src/common/setup.h](Frotz/src/common/setup.h)
- [Frotz/src/common/fastmem.c](Frotz/src/common/fastmem.c)
- [Frotz/src/common/process.c](Frotz/src/common/process.c)
- [Frotz/src/common/variable.c](Frotz/src/common/variable.c)

## Phase 1 planning note

This phase is intentionally focused on correctness before breadth. We do not need a complete emulator yet. We need a stable foundation that can honestly interpret a real Z-code story and expose the runtime state in a way that is easy to extend later.

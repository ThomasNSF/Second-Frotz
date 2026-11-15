# Memory Manager

`VM/Memory Manager.luau` is the Z-Machine ROM service for the Luau port. It reads ROM metadata and page data from the `ZMachine ROM` notecard, keeps recently used pages in a bounded in-memory cache, and communicates with the VM through Second Life link messages.

The script is designed to keep the VM independent from notecard access and from the Second Life dataserver event model.

## Architectural Read Rule

All VM memory reads are asynchronous operations. A read may be satisfied immediately from VM RAM or a resident page cache, but it must still use the same coroutine-compatible API as a cold ROM read. The VM execution loop therefore runs inside a managed coroutine, and a memory read is allowed to yield while the memory manager obtains a page.

The memory manager itself performs asynchronous notecard reads through `dataserver` events. The VM-side memory module performs asynchronous page reads through `PAGE_REQ` and `PAGE_RES` link messages. Neither layer should expose a separate synchronous read path to opcode handlers.

Consequences:

- instruction fetches can suspend while waiting for a ROM page
- operand reads can suspend in the same way
- RAM and cache hits must preserve the same caller contract, even when they resume immediately
- the VM must preserve its program counter and execution state across a suspended read
- timeouts and malformed page responses must become controlled read failures
- callers that perform memory reads must already be running inside a coroutine

This service only handles the read-only ROM, that is the static and high memory of the story. Dynamic memory (RAM) never goes through it: `ZMemory` holds it in the VM script, either as one flat buffer or, for stories with a lot of dynamic memory, paged out to the linkset's LinksetData. That access is synchronous and does not use this service or the link-message protocol. See "Paging dynamic memory to LinksetData" in [PORTING_PLAN.md](PORTING_PLAN.md).

## Responsibilities

The memory manager:

- reads the ROM header from the notecard
- reads individual Base64-encoded ROM pages on demand
- decodes page data into Luau `buffer` values
- caches recently used pages
- promotes cache hits to the front of the cache
- evicts the least-recently-used page when the cache is full
- responds to ROM header and page requests over the linkset
- waits for asynchronous notecard results through `CoroutineMgr`

It does not execute Z-machine instructions or interpret story-file data beyond parsing the ROM header and decoding page payloads.

## Dependencies

The script requires two local modules:

### `MemoryAPI.luau`

Defines the shared channel and message constants:

| Constant | Value | Purpose |
| --- | --- | --- |
| `MEMORY_CHANNEL` | `9000` | Link-message channel used by the memory service |
| `LOAD_CARD` | `"LOAD_CARD"` | Request a ROM load and header response |
| `LOAD_CARD_RES` | `"LOAD_CARD_RES"` | Response to `LOAD_CARD` |
| `PAGE_REQ` | `"PAGE_REQ"` | Request one ROM page |
| `PAGE_RES` | `"PAGE_RES"` | Response containing one ROM page |
| `HEADER_REQ` | `"HEADER_REQ"` | Request the currently loaded header |
| `HEADER_RES` | `"HEADER_RES"` | Response to `HEADER_REQ` |

### `coromgr.luau`

Provides:

- `CoroutineMgr:create_task(function)` to run an asynchronous task
- `CoroutineMgr:handle_event(name, ...)` to resume tasks waiting for an event
- `await_event(name, timeout)` to suspend the current task until an event or timeout occurs

The memory manager subscribes to `dataserver` only while an individual notecard operation is active.

## ROM Notecard Format

A story is stored on one or more notecards. Each card contains one header line followed by up to `pagesPerCard` Base64 pages, one per line.

```text
ZROM1|1|762|pageCount|sha256-checksum|part|parts|pagesPerCard
<page 1 as Base64>
<page 2 as Base64>
<page 3 as Base64>
```

### Why the story is split

A Second Life notecard holds at most 65,536 bytes. A 762-byte page is 1,016 Base64 characters plus a newline, so 64 pages and a header line come to about 65,170 bytes, just under the limit. Adventureland (58 KB, 77 pages) needs two cards; a card cut off at the limit silently loses every page beyond it, which is how the problem first showed up (page 68 failed to read).

### Card names

A split story is stored on `<name>.1`, `<name>.2`, ... `<name>.<parts>`, for example `ZMachine ROM.1` and `ZMachine ROM.2`. `LOAD_CARD` receives the base name (`ZMachine ROM`). If `<name>.1` exists in the object's inventory the story is split; otherwise the manager looks for a single unnumbered card named `<name>`, which is the original layout and still works.

### Header fields

The fields are separated by `|`:

| Position | Field | Description |
| --- | --- | --- |
| 1 | `magic` | Must be `ZROM1` |
| 2 | `version` | ROM format version; currently `1` |
| 3 | `pageSize` | Number of decoded bytes in each page |
| 4 | `pageCount` | Number of pages in the whole story, across all cards |
| 5 | `checksum` | Optional checksum string; the converter writes SHA-256 of the original story |
| 6 | `part` | Optional. Which card this is, starting at `1` |
| 7 | `parts` | Optional. How many cards the story is split across |
| 8 | `pagesPerCard` | Optional. Pages on every card except possibly the last |

The header parser requires at least four fields. Fields 6-8 are all-or-nothing: when absent the card is a complete single-card story (`part` 1, `parts` 1, `pagesPerCard` = `pageCount`), so cards written before the split was introduced still load. The converter writes all eight fields on every card, so each card knows its position and layout.

The checksum is retained as metadata and compared across cards at load; the manager does not verify it against the page data.

### Page lines

Page numbering is one-based. Line 1 of every card is its header. For a story split into cards of `pagesPerCard` pages, page `N` is

- on card `((N - 1) // pagesPerCard) + 1`
- at notecard line `((N - 1) mod pagesPerCard) + 2`

For a single card this reduces to notecard line `N + 1`, as before.

Each page line contains only Base64 text. Do not add a `PAGE_0001:` prefix because the current reader passes the complete line directly to `llbase64.decode`.

The current converter default is `762` decoded bytes per page. Since 762 is divisible by 3, its Base64 representation is exactly 1016 characters and leaves room below the 1024-character notecard line limit.

The last page is padded with zero bytes by the converter so every decoded page has the configured page size. The header's `pageCount` describes the padded pages, not the original file's unpadded length.

## Loading Lifecycle

The memory manager starts with no loaded ROM:

```text
init()
  |
  +-- pageCache = {}
  +-- ROM_HEADER = nil
```

A VM or host script loads the card by sending `LOAD_CARD`.

```text
1. Receive LOAD_CARD
2. Clear the current state
3. Start a coroutine
4. Check whether "<name>.1" exists to decide between split and single-card layouts
5. Request the first card's line count and await the dataserver result
6. Read notecard line 1 of that card and parse the ROM header
7. For a split story, repeat steps 5-6 for every other card and check that each
   belongs to the same story (magic, page size, page count, checksum, part
   numbers) and has at least as many lines as its pages require
8. Store ROM_HEADER
9. Send LOAD_CARD_RES
```

Any failure in steps 4-7 sends `LOAD_CARD_RES` with `loaded: false` and prints the reason, so a missing, mismatched or truncated card is reported when the story is loaded.

The memory manager does not preload every page. Page data is fetched only after a `PAGE_REQ` cache miss.

The manager does not make reads synchronous for the VM. It answers page requests asynchronously after notecard access completes; the VM-side `ZMemory` module is responsible for suspending and resuming the interpreter task.

## Asynchronous Notecard Reads

Second Life notecard access is event-driven. The manager uses the following sequence for each read:

```text
GetNumberOfNotecardLines or GetNotecardLine
  |
  +-- receive a request UUID
  |
  +-- await_event("ds" .. request UUID, 30)
  |
  +-- dataserver event calls onDataserver
  |
  +-- onDataserver calls CoroutineMgr:handle_event(...)
  |
  +-- waiting coroutine resumes with event name and response text
```

The timeout for each awaited operation is 30 seconds. The temporary dataserver handler is removed after the operation completes or times out.

`onDataserver` forwards the response using an event name derived from the request UUID:

```text
"ds" .. request_id
```

The request and response must use the same UUID formatting for the waiting coroutine to resume.

## Link-Message Protocol

All protocol messages are JSON strings sent on `MEMORY_CHANNEL`.

### Load request

```json
{
  "type": "LOAD_CARD"
}
```

### Load response

```json
{
  "type": "LOAD_CARD_RES",
  "loaded": true,
  "magic": "ZROM1",
  "version": 1,
  "pageSize": 762,
  "pageCount": 12,
  "checksum": "..."
}
```

If loading fails, `loaded` is `false` and the metadata fields are `nil` before JSON encoding.

### Header request

```json
{
  "type": "HEADER_REQ"
}
```

The response uses `HEADER_RES` and contains the currently loaded header, or `loaded: false` when no ROM is loaded.

### Page request

```json
{
  "type": "PAGE_REQ",
  "pageNumber": 1,
  "requestId": 42
}
```

`pageNumber` is one-based and `requestId` is supplied by the requesting VM so it can match the response to its request.

### Page response

```json
{
  "type": "PAGE_RES",
  "pageNumber": 1,
  "requestId": 42,
  "pageSize": 762,
  "pageB64": "..."
}
```

`pageB64` contains the page encoded for safe JSON and link-message transport. When the page cannot be read, the response contains a `nil` page payload after JSON encoding.

## Page Cache

The cache is an array of `PageCacheEntry` values:

```luau
type PageCacheEntry = {
    index: number,
    buffer: buffer,
}
```

The cache has a maximum size of `10` entries.

### Ordering

The array is ordered from most recently used to least recently used:

```text
pageCache[1]       most recently used
pageCache[2]
...
pageCache[10]      least recently used
```

### Cache hit

`findCachedPage(pageNumber)` scans the array. When it finds a matching entry, it:

1. removes the entry from its previous position
2. inserts it at index `1`
3. returns its buffer

This is an LRU promotion operation.

### Cache insertion

`addCachedPage(pageNumber, pageData)`:

- replaces the buffer if the page is already present
- removes the last entry when the cache has reached capacity
- inserts a new page at index `1`

A cache miss therefore reads the page from the notecard, adds it to the front of the cache, and sends it to the VM.

## Page Request Flow

```text
PAGE_REQ
  |
  +-- Is ROM_HEADER loaded?
        |
        +-- no: log and stop
        |
        +-- yes
              |
              +-- findCachedPage(pageNumber)
                    |
                    +-- hit: promote and send PAGE_RES
                    |
                    +-- miss: readNotecardPage(pageNumber)
                              |
                              +-- failure: send empty PAGE_RES
                              |
                              +-- success: cache page and send PAGE_RES
```

## Function Reference

### `parseRomHeader(rawHeader)`

Parses the pipe-delimited first line of the notecard and returns a `RomHeader`, or `nil` when the magic value or numeric fields are invalid.

### `sendPageResponse(pageNumber, requestId, pageData)`

Builds and sends a `PAGE_RES` JSON message. A supplied string or buffer is Base64-encoded before transmission.

### `onDataserver(request_id, data)`

Receives a dataserver result, logs it, and resumes the coroutine waiting on the matching `ds<UUID>` event.

### `readCardHeader(name)`

Requests one card's line count, waits for the asynchronous result, reads its first line, and parses the ROM header. Returns the header and line count, or `nil` after printing the reason.

### `readNotecardHeader(notecardName)`

Decides between the split and single-card layouts, reads the first card's header, and for a split story checks every other card against it (same story, expected part number, enough lines).

### `cardName(part)`

The notecard that holds a part of the story: `<name>.<part>` for a split story, `<name>` for a single card.

### `readNotecardPage(pageNumber)`

Works out the card and line for a page, reads the Base64 line asynchronously, and decodes it into a `buffer`.

### `findCachedPage(pageNumber)`

Looks up a page in the LRU cache. A hit is promoted to the front of `pageCache`.

### `addCachedPage(pageNumber, pageData)`

Updates or inserts a page in the LRU cache and evicts the oldest entry when necessary.

### `requestPage(pageNumber, requestId)`

Serves a page from cache or starts a notecard read on a cache miss.

### `sendHeaderResponse(header, fromLoadCard)`

Sends either `LOAD_CARD_RES` or `HEADER_RES`, depending on the request that produced the response.

### `init()`

Clears the cache and unloads the current ROM header.

### `onLinkMessage(sender, channel, message, id)`

Filters messages by channel, decodes JSON, and dispatches load, header, and page requests.

## Converter

The companion tool [tools/zmachine_to_notecard.py](../tools/zmachine_to_notecard.py) converts a binary story file into this format:

```powershell
python tools/zmachine_to_notecard.py story.z5 "ZMachine ROM"
```

This writes `ZMachine ROM.1`, `ZMachine ROM.2`, ... and prints each card's size. Create one notecard in the object from each file, using the file names as the notecard names. `--pages-per-card` (default 64) sets the split, and the tool refuses to write any card of 65,536 bytes or more.

Every card gets a header with the story's page size, page count, SHA-256 checksum of the original story bytes, and its own part number. The final page of the story is zero-padded to the page size.

## Operational Notes

- The base notecard name is the one sent in `LOAD_CARD` (the tests use `ZMachine ROM`); a split story's cards are that name plus `.1`, `.2`, and so on.
- Do not leave an old unnumbered card with the same base name in the object; the numbered cards take precedence, but the duplicate is confusing.
- The VM should send `LOAD_CARD` before requesting pages.
- Page numbers are one-based throughout the protocol.
- Raw binary data must not be placed directly in link messages or notecard lines.
- The configured page size in the header must match the converter's page size and the VM's expectations.
- The current checksum is descriptive metadata; checksum validation is not yet implemented.
- Loading a new card clears the existing page cache and header state.
- Page reads are serialized through the coroutine task that handles the request.

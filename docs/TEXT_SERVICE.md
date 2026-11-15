# Text Service

Status: **proposal, not built.** This document describes moving everything the player sees and types out of the core VM script into a second script, the Text Service, which talks to the core only by link messages. It replaces the single-script assumption in [PHASE5_PLAN.md](PHASE5_PLAN.md) for steps 5.4 onward (the host, `ZInput` and `ZText` code already written moves over unchanged).

## Why

The compiled core no longer fits in one script. Measured: a test script carrying every VM module except `ChatHost`, `ChatText` and the run loop starts with 13.9 KB free of 131,072 bytes, and the real VM script would start with roughly 15 KB free before loading a story (about 8-10 KB with paged RAM), `ZState` (4 KB) and the garbage from ROM page decoding. Memory costs about 0.5 bytes per source byte (comments are removed at compile time, so they cost nothing).

The text and input code is a clean cut. It is large, it is not needed to fetch, decode or execute instructions, and it is the part that varies by front end.

| Module | Source | Compiled (est.) | Goes to |
| --- | --- | --- | --- |
| `ZText` | 9.2 KB | 4.6 KB | Text Service |
| `ZOutput` | 5.4 KB | 2.7 KB | Text Service |
| `ZInput` | 11.4 KB | 5.7 KB | Text Service |
| `ZIoOpcodes` (handler logic, screen model) | 13.4 KB | 6.7 KB | Text Service |
| `ChatHost`, `ChatText`, `ZHost` | 10.9 KB | 5.5 KB | Text Service |
| **Total moved** | | **about 25 KB** | |

Expected result: the core gains about 25 KB and keeps roughly 25 KB free during play (against about 3 KB now). The Text Service uses about 35 KB of its own 128 KB, so it has room for transcripts, a richer status line, or word completion later.

## What stays in the core

`ZMemory`, `ZState`, `ZObject`, the opcode tables and all non-text opcodes, the run loop, `coromgr`, and a small **text client** (`ZTextClient`) that the print and input opcode handlers call. The handlers become thin: decode operands, hand the client a request, store the reply.

## Shared state: dynamic memory lives in LinksetData

Dynamic memory is already paged out to LinksetData (see [PORTING_PLAN.md](PORTING_PLAN.md), "Paging dynamic memory to LinksetData"), and LinksetData is shared by every script in the linkset. The Text Service therefore reads and writes the story's dynamic memory through the same keys as the core, with no per-byte messages. A `read` can fill the story's text and parse buffers directly.

This only works if RAM is always paged, so production runs set `ramFlatLimit = 0` (no flat buffer, even for small stories). Cost: about 12 KB of the 128 KB LinksetData store for Adventureland, and a little speed.

### Coherence rules

Both scripts cache pages, so ownership passes back and forth with each request:

1. **R1.** Before sending a request that may read RAM, the core calls `memory:flush()` so LinksetData holds its latest writes.
2. **R2.** The Text Service reads fresh from LinksetData at the start of each request (it drops its resident pages first) and writes through at the end (`flush()`).
3. **R3.** After a reply that says it wrote RAM (`wroteRam = true`), the core drops its resident pages (new `ZMemory:invalidateRam()`, which discards without writing back). The next access reloads from LinksetData.
4. **R4.** A string that lives in dynamic memory (`print_addr` or `print_paddr` into RAM, an object's name, an embedded `print` in RAM) is **copied by the core when it is printed** and sent inside the entry as its words (`z`), so it prints as it was at that moment even though the printing happens later, and no round trip is needed. The core finds the end of the string by scanning for the end bit; it does not decode. Only requests that make the Text Service read RAM (`read`, `tokenise`, `encode_text`, `print_table`) are synchronous, and the core waits for the reply before executing the next instruction.
5. **R5.** Entries that refer to ROM by address (`s`) or carry their data (`z`, `t`, `c`, `u`, `n`, `nl`, `w`, `o`, `st`) are asynchronous.

6. **R6 (table writes).** The Text Service decodes strings using three tables that live in the story's memory: the alphabet table, the abbreviations table and the Unicode translation table. If the story writes to any of them, text printed before the write must still use the old contents and text printed after it the new. The core keeps the three address ranges (from the header, recomputed after a restart) in the text client. A story write (`storeb`, `storew`, `copy_table`, and any other opcode that goes through the checked store) that lands in one of those ranges does this:
   1. send the pending batch with a `barrier` request and wait for the reply, so every earlier print has been decoded with the old tables;
   2. perform the write;
   3. call `memory:flush()`, so the next message the Text Service handles (it drops its resident pages at the start of every message, R2) reads the new table contents.

   The cost is two range comparisons on each checked story write, and a short synchronous exchange on the very rare write that hits a table. The table contents themselves are read from LinksetData on demand, so the Text Service keeps nothing that can go stale; only the table *addresses* come from the header (which stories may not change) and are refreshed by `TS_RESET` and `TS_CONFIG`.

   Not covered: an abbreviation *string* held in dynamic memory and rewritten at run time. Abbreviation strings live in ROM in practice.
7. **R7 (stream 3).** While a stream 3 redirect is open the Text Service writes the printed text into a table in RAM. If that happened asynchronously, the core could write another variable on the same 256-byte page, and when it later saved its cached page it would overwrite the Text Service's table bytes with stale ones (the two scripts share pages, not bytes). So while a redirect is open, every output entry is sent as a synchronous `flush` request, and the core drops its cached pages after each (R3). Redirected output costs a round trip per entry; the redirect itself is rare and short.

## Transport

- **One prim.** The core, the Text Service and the Memory Manager are scripts in the same prim, so link messages go to the prim itself (`LINK_THIS`) rather than the whole linkset. The Memory Manager's replies still reach every script in the prim, which is why the next bullet matters.
- **Channels:** `TEXT_CHANNEL = 9001` carries the core's messages to the service and `TEXT_REPLY_CHANNEL = 9002` carries the service's answers (the Memory Manager uses 9000). A link message sent to `LINK_THIS` is delivered to the sender too; with one channel per direction, neither script ever has to look at (or decode) its own messages. `TextAPI.luau` holds the constants, like `MemoryAPI.luau`.
- **Matching replies.** The core keeps a table of open handles keyed by the message `id`; a reply that arrives before anyone waits for it is stored in its handle. Handling is serial on the service side: messages are queued and processed one at a time, because handling may yield (a ROM page fault, or waiting for the player to type) and a second message must not start meanwhile.
- **Check before decoding.** Every `link_message` handler first checks whether a coroutine is waiting for the correlation `id` (a table lookup) and returns immediately if not. Only then does it decode the JSON. Without this, each ROM page reply (about 1 KB of JSON) requested by one script would be decoded, and thrown away, by the other. This changes `ZMemory`'s current handler, which decodes first.
- **Envelope:** the link message `str` is JSON with a `type` field; the `id` argument is a fresh `ll.GenerateKey()` for every message that expects a reply, used to match the reply to the waiting coroutine exactly as `MemoryAPI` does (event name `tapi<id>`).
- **Filtering:** a script only handles request types addressed to it and only wakes a waiter for genuine reply types. A message the script sent itself loops back through `link_message`; the existing `RESPONSE_MESSAGE_TYPES` guard in `ZMemory` is reused for this.
- **Size:** measured in T0: messages up to 8,192 characters arrive intact. Batches are capped at 2,000 bytes of JSON (a limit chosen for memory, since the core builds and encodes each batch, not for the transport) and are split before that.
- **Order:** measured in T0: messages from one script to another arrive in the order sent. The protocol relies on this; sequence numbers are kept only to detect loss.
- **Queue:** measured in T0: a script's link-message queue holds 64 events; beyond that the newest arrivals are dropped silently. The flow control below keeps the number outstanding far below that.
- **Latency:** measured in T0: a request and reply take 44 ms on average (41 to 45 ms), about one simulator frame each way.

## Messages

All field names below are the JSON keys.

### Core to Text Service

| `type` | When | Fields |
| --- | --- | --- |
| `TS_CONFIG` | startup, after the story is loaded, and again whenever the Text Service says `TS_HELLO` | `version`, `pageSize`, `storySize`, `staticBase`, `ramPrefix`, `romName` |
| `TS_OUT` | asynchronous output batch | `seq`, `e`: list of entries (below) |
| `TS_REQ` | synchronous request | `op`, `args`, optional `pre`: entries to process first |
| `TS_RESET` | after `restart` | none |
| `TS_END` | story quit or fatal error | `reason`: `"quit"` or `"fatal"`, `error` (fatal only) |

### Text Service to Core

| `type` | In reply to | Fields |
| --- | --- | --- |
| `TS_HELLO` | none (sent when the Text Service script starts or resets) | `version` of the protocol |
| `TS_CONFIG_RES` | `TS_CONFIG` | `ok`, `screenRows`, `screenCols` (for the header) |
| `TS_ACK` | `TS_OUT` | `seq` |
| `TS_RES` | `TS_REQ` | `ok`, `value` (a result number), `wroteRam`, op-specific fields, or `error` (a Z-machine error code) |

### Output entries (inside `TS_OUT.e` and `TS_REQ.pre`)

Each entry is a small list so a batch stays compact: `{kind, a, b, c, d}`.

| Kind | Meaning | Async? |
| --- | --- | --- |
| `s` | print the Z-string at ROM byte address `a` (embedded `print` in ROM, `print_addr`, `print_paddr`). The core checks only that the start address is inside the story; a string that runs off the end is reported by the service in its acknowledgement | yes |
| `z` | print the Z-string whose words `a` (a list) the core copied out of dynamic memory (R4): `print_obj` names, and strings in RAM | yes |
| `t` | print the literal text `a` (for example `object#5`) | yes |
| `st` | V1-V3 status line: `a` is `{words, first, second, isTime}` (the location name's words and the two numbers); the service decodes the name and gives it to the host if the host has a status line | yes |
| `c` | print one ZSCII character `a` | yes |
| `u` | print one Unicode code point `a` | yes |
| `n` | print the signed number `a` | yes |
| `nl` | new line | yes |
| `w` | window operation `a`: `split` (b = height), `set` (b = window), `erase` (b = window or -1/-2), `eraseline` (b), `cursor` (b = row, c = column), `style` (b), `colour` (b, c), `buffer` (b) | yes |
| `o` | select an output stream: `a` = 1 or -1 (screen on or off), 2 or -2 (transcript; ignored for now). Streams 3 and -3 are synchronous requests (below) | yes |

The core finds where an embedded `print` string ends by scanning words until the end bit (no decoding), so it can advance the PC without the Text Service.

### Synchronous operations (`TS_REQ.op`)

| `op` | `args` | Reply |
| --- | --- | --- |
| `check_unicode` | `c` (a code point) | `{value}`: 3 if it can be printed and read, 1 if only printed, 0 for control codes and invalid code points |
| `read` | `text`, `parse`, `timeout`, and for V1-3 `status` (`words`, `first`, `second`, `isTime`, as in the `st` entry) | `{status = "line", key = 13}` or `{status = "timeout"}`; on `"line"` the text and parse buffers are already written (`wroteRam`) |
| `read_end` | `text` | stores an empty text buffer after a timeout the routine ended; reply `{key = 0}` |
| `read_char` | `timeout` | `{status = "key", value = zscii}` or `{status = "timeout"}` |
| `tokenise` | `text`, `parse`, `dict`, `skip` | `wroteRam` |
| `encode_text` | `text`, `length`, `offset`, `dest` | `wroteRam` |
| `print_table` | `addr`, `width`, `height`, `skip` | none |
| `get_cursor` | none | `{row, column}` (the core stores them) |
| `set_font` | `font` | `{value = previous font or 0}` |
| `stream` | `n` (3 or -3) and `table` | `{error = ERR_STR3_NESTING}` or `wroteRam` when closing |
| `flush` | none | acknowledged once all earlier entries are processed (used before `quit`, and when the core needs the output order guaranteed) |
| `barrier` | none | the same exchange as `flush`; used by R6 before a story write to one of the string tables |

Any synchronous request first flushes the core's pending entries in `pre` (saving a message), then the Text Service handles the request in order.

## Flow control

At most two `TS_OUT` batches are unacknowledged. The core sends a batch when: a synchronous request is issued (as `pre`), the pending list reaches the size cap, the instruction counter yields (every 10,000 instructions, so output appears while a long computation runs), or the story ends. If two batches are already outstanding, the core waits for the oldest `TS_ACK` before sending another, so it cannot outrun the Text Service or overflow its link-message queue.

## Reading input and timeouts

```
core                                   Text Service
 |-- TS_REQ read {text, parse, ... } --> |  (flush pending entries; show status line;
 |                                       |   ask the host to read a line)
 |                                       |  host timeout expires
 | <-- TS_RES {status = "timeout"} ----- |
 |  call the story's routine (directCall)
 |  routine returned 0:
 |-- TS_REQ read {same} ---------------> |  (waits again with a fresh timeout)
 | <-- TS_RES {status = "line"} -------- |  (buffers written to RAM through LinksetData)
 |  drop cached RAM pages (R3), store key 13
```

If the routine returns non-zero, the core sends `read_end`, which writes an empty text buffer, then stores key 0. Reads wait with no core-side timeout, because they wait for a person. `read_char` follows the same shape.

## Start up, restart and shutdown

1. The core loads the story (`ZMemory:initialize`) with RAM paged, then sends `TS_CONFIG`. The Text Service builds its own `ZMemory` from the config (`ZMemory:attach(config)`: no `initialize`, no seeding; the ROM cache fetches pages from the Memory Manager like the core does), reads the header, and builds `ZText` and `ZInput`. It replies with the screen size so the core can write it into the header.
2. `restart`: the core runs `ZState:restart` (which re-seeds RAM), then sends `TS_RESET`. The Text Service clears its screen model and stream state and refreshes `ZText` (the alphabet and Unicode table pointers).
3. `quit`: the core sends `TS_END` after a `flush`; the Text Service says the closing line and stays idle. A fatal error is sent as `TS_END` with the error table, and the Text Service reports it in chat.
4. If the Text Service does not answer a non-input request within 30 seconds, the core raises a fatal error naming the request. Input waits are unbounded.
5. **Resets.** When the Text Service script starts or resets it sends `TS_HELLO`. A core that has not loaded a story ignores it (the core sends `TS_CONFIG` when the story is ready). A core in the middle of a game answers with `TS_CONFIG`; the Text Service has lost its screen state, so the core also sends `TS_RESET` and tells the player in chat that the display was reset. If the core script resets, it reloads the story and the sequence starts over; the Text Service accepts a new `TS_CONFIG` at any time.
6. **Idle output.** The Text Service sends the text it has accumulated when it is asked for input, ends, or has received nothing new for one second, so a long-running turn does not hold output back indefinitely.

## Script layout

```
Core VM script                          Text Service script
  ZMemory (RAM paged, ROM fetch)          ZMemory (attach: RAM through LinksetData, ROM fetch)
  ZState, ZObject                         ZText, ZOutput, ZInput
  ZOpcodes (all tables)                   TextHandlers (read, tokenise, windows, ...)
  ZTextClient (batching, requests)        ChatHost + ChatText (behind ZHost)
  ZTextLink (link-message transport)      TextService + TextServiceLink (serial dispatcher)
  run loop                                "Text Service" script (VM/Text Service.luau)
```

Both scripts run the same shared modules where they overlap (`ZMemory`, `coromgr`, `TextAPI`). The `ZIoOpcodes` handlers lose their dependence on `ZState` (operand loading, `state:store`): they receive a request context holding the arguments, and return the values the core stores.

## Testing and the in-process mode

`ZTextClient` talks to its peer through a transport interface with two implementations: link messages (production), and a direct call into the Text Service dispatcher in the same script (tests and development). Existing tests keep running in one script; the service code is exercised the same way in both. Only the transport and the coherence rules (R1-R3) differ, and those get their own tests.

## Migration

| Step | Work | Test that guards it |
| --- | --- | --- |
| T0 | Probe the two-script facts the design relies on: `tests/LinkProbeA.luau` and `LinkProbeB.luau` measure link-message round trip, burst loss, maximum message size and ordering, and whether one script sees the other's LinksetData writes immediately | **Done.** Round trip 44 ms; 64-event queue, newest dropped on overflow; 8 KB messages intact; order preserved; LinksetData visible immediately in both directions |
| T1 | `TextAPI.luau`; the check-before-decode change to `ZMemory`'s message handler; `ZMemory:invalidateRam()` and `ZMemory:attach(config)`; `ZMemory` option to force paged RAM | `RamPagingTests` plus new tests for invalidate and attach (a second `ZMemory` reads what the first wrote, after a flush) |
| T2 | `TextService.luau`: the service as a plain object with no transport (`config`, `out`, `request`, `reset`, `finish`), holding the story memory, `ZText`, `ZOutput`, `ZInput`, the host and the screen model. Its logic comes from the current `ZIoOpcodes` handlers and the print handlers in `ZOpcodes`, reading arguments from tables and returning the values the core will store | `TextServiceTests`: the current `IoOpcodeTests` and print tests rewritten against `service:out` and `service:request` with a scripted host. No `ZState` or `ZOpcodes` in the script, so it has plenty of memory |
| T3 | `ZTextClient` with the batching rules and a loopback transport that calls the service directly; the print and input opcodes in `ZOpcodes` become thin wrappers over the client; `ZIoOpcodes` is deleted; `z`, `st` and `check_unicode` added to the service | `TextClientTests` (batching, flow control, R1/R3/R7, errors); `TextOpcodeTests` and `IoOpcodeTests` rewritten to check the entries and requests the opcodes send to a recording transport, so those scripts do not carry the Text Service; `TextServiceTests` for the additions |
| T4 | `ZTextLink` (the core's transport: handles by message key, 30 s timeouts that become fault replies, none for reads, `TS_HELLO` recovery), `TextServiceLink` (the service's serial message loop, fault replies, idle flush after 1 s), the `Text Service` script, and the reply channel in `TextAPI` | `TextLinkTests` (both ends driven by an injected `post`, no second script); `TextLinkSmoke`, a two-script run in-world that prints, reads a chat line, times out a read, and measures the request round trip |
| T5 | Measure the core script (`tests/CoreMemoryProbe.luau`); the moved modules were already out of the core's requires after T3 | **Done.** Core starts with 19,966 bytes free with the story loaded (paged RAM), `ZState` built and the text client attached (code alone is about 76 KB of the 128 KB; story load 6.1 KB, `ZState.new` 4.2 KB). After reading every ROM page and touching every RAM page (both caches full) free memory is 12,448 bytes, so about 12 KB remains for the run loop, Quetzal and transient garbage. Compare the 13.9 KB before the split, which also had no story loaded |
| T6 | Then the run loop (`ZMachine`, `directCall`) and play Adventureland end to end (PHASE5_PLAN step 5.6-5.7); measure latency of synchronous requests | In-world play |

T1-T3 change no behavior from the player's point of view and keep every test passing, so the risky part (two scripts) is confined to T4.

## Risks

- **Latency.** Each synchronous request costs one link-message round trip, measured at 44 ms. Most prints are asynchronous, so a typical turn needs one request: the `read`. If a particular opcode proves too chatty in play it can be made asynchronous or moved back.
- **Coherence bugs.** Stale RAM reads would be subtle. The rules are simple and the dropping of pages is cheap, so the default is to flush and drop at every synchronous request. Tests check the common cases: a read changes the text buffer, stream 3 changes a table, the story writes then prints.
- **Queue overflow.** Link-message events queue up in a script and excess events are dropped. The flow control above bounds the number outstanding.
- **Message size.** Batches are capped at 2,000 bytes. A long print loop produces several batches rather than one very large message.
- **Header contents.** The core still writes the screen size and interpreter fields into the header (`restartHeader`). Today these are fixed defaults; with the service they come from `TS_CONFIG_RES`.

## Open questions

1. **Host placement (settled).** `ChatHost` is in the Text Service, behind `ZHost`, so a different front end replaces only that module. A third script (a HUD or web adapter talking to the Text Service) is a later change that this layout allows; it is not planned now.
2. **Memory limit (settled).** `ll.SetMemoryLimit` cannot raise a script above 128 KB (131,072 bytes), so the split is required, not optional.
3. **`print_table` and other RAM readers** could be moved back to the core if the round trip proves too costly; their code is small.

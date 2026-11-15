# Phase 5: Host interface, input opcodes and run loop

Phase 4 finished the opcode set that does not need a host. Phase 5 adds what is needed to play a story: reading input, the screen opcodes, and the loop that drives the VM. The first host talks over public chat (channel 0), but the VM must not depend on it, so a HUD or web front end can replace it later.

Status: steps 5.1-5.3 and the host and input modules are built and tested (`ChatText`, `ZHost`, `ChatHost`, `ZInput`); the opcode wiring (5.4-5.5) is written (`ZIoOpcodes`, `ZOpcodes.attach`, `IoOpcodeTests`) but untested because the combined script no longer fits in script memory. The text and input code is therefore moving to a separate script, described in [TEXT_SERVICE.md](TEXT_SERVICE.md), which supersedes the single-script layout in this plan. The run loop (5.6) and play (5.7) follow that migration.

## Goals

- Play Adventureland end to end in Second Life: the story's text appears in chat, and the owner's chat lines are the game's input.
- Keep the VM independent of how input and output reach the player. Everything host-specific sits behind one interface.
- Stay inside the script memory budget (about 38 KB free after story, state and text work; revisit a script split below about 20 KB).

## Decisions

1. **One host interface, many implementations.** The driver calls a small table of functions (`ZHost`). `ChatHost` is the first implementation. Optional screen capabilities are looked up by name; a host without one gets the plain-text default that Frotz's dumb interface uses.
2. **Output is collected and sent when input is requested.** Text is gathered as it is flushed by `ZOutput` and sent with `ll.Say(0, ...)` when the game asks for input or ends. Fewer, larger messages also stay well inside the channel-0 rate limit (200 messages per 10 seconds per region, dropped messages still count).
3. **Chat chunk size is a setting, not a constant.** See "The chat line limit" below.
4. **Input is the owner's channel-0 chat only.** The listener is filtered to the owner and is open only while a read is waiting; chat said at any other time is not heard (no type-ahead).
5. **Timed input is supported.** V4+ `read` and `read_char` accept a timeout (in tenths of a second) and a routine to call when it expires. The host's `readLine(maxLength, timeout)` and `readChar(timeout)` return `(text, timedOut)`; `ChatHost` passes the timeout to `await_event`. When a read times out, the opcode calls the routine through `state.directCall(addr)`, which the run loop provides (it calls the routine and runs `step` until that frame returns, then pops the result, as Frotz's `direct_call` does). A result of 0 continues the input with a fresh timeout; non-zero ends it, storing the text so far without lowercasing or tokenising and storing 0 as the terminating key. On a chat host nothing is ever half-typed, so a timeout always ends with an empty buffer; Frotz keeps partial input.
6. **Text input logic is a separate module that takes explicit arguments**, like `ZText` and `ZOutput`: `ZInput.luau` does not require `ZState` or `ZOpcodes`, so it can be tested alone and moved to another script if memory requires.
7. **Save and restore stay out of this phase.** They remain `unsupported` stubs until the Save/Load phase (Quetzal).

## The chat line limit

What the documentation says:

- `llSay` messages are limited to **1024 bytes**. That is 1024 ASCII characters, or 256-512 multibyte UTF-8 characters. A multibyte character that falls on the boundary is dropped whole, not split.
- Chat typed in the viewer on negative channels is limited to 254 bytes. Instant messages are limited to 1023 bytes.
- Older sources describe a 255-byte chat limit, and some forum posts report that the viewer displayed truncated text while scripts received all of it.

No current source documents a display cutoff at 256 characters in the chat window, and it cannot be seen from the documentation alone. So:

- The chunk size is configurable: `ChatHost.new({ maxBytes = ... })`.
- **Step 5.1 writes `tests/ChatProbe.luau`**, which says numbered lines of 100, 200, 255, 256, 257, 400, 1000 and 1024 characters, each ending in a marker, so the owner can see where the viewer cuts them. The result sets the default.
- The chunker never exceeds the limit, cuts at the last newline or space before it, and never splits a UTF-8 character. Only if a single word is longer than the limit does it cut mid-word.

## Design

### `ZHost` (interface)

```
write(text: string)                         -- sink for ZOutput chunks
readLine(maxLength, timeout?): (string, boolean)  -- yields until a line is entered; timeout in tenths of a second; second result is "timed out"
readChar(timeout?): (string, boolean)             -- the same for one character
fatal(err)                                  -- a fatal VM error table (code, message, pc, opcode)
quit()                                      -- the story finished
capabilities (all optional):
  splitWindow, setWindow, eraseWindow, eraseLine,
  setCursor, getCursor, setTextStyle, setColour,
  setFont, statusLine
```

`readLine` and `readChar` run in the VM coroutine and use the existing `await_event` mechanism, so no new scheduling is needed.

### `ChatHost`

- **Output:** `write` appends to a buffer. The buffer is sent, in pieces of at most `maxBytes`, before every read request and on `quit`/`fatal`. Pieces are cut at a newline or space and never inside a UTF-8 character.
- **Input:** `ll.Listen(0, "", owner, "")` plus the `listen` event. The listener is opened when a read starts and removed when it ends; a pending read takes the next line the owner says. `readChar` takes the first character of the next line (a chat host has no key events; this is documented, not hidden).
- **Echo:** none; the player's own chat line is already visible.
- **Capabilities:** none provided, so every screen opcode takes its plain-text default.

### `ZInput` (text input logic)

Mirrors `input.c`, `text.c` and `fastmem.c` in Frotz:

- Reading a line into the text buffer: V1-4 layout (buffer size in byte 0, text from byte 1 and zero-terminated) and V5+ layout (maximum length in byte 0, length stored in byte 1, no terminator). Input is lowercased.
- `tokenise_line`: splitting into words with the dictionary separators, looking each word up (`lookup_text`), and filling the parse buffer, including the user dictionary form of `tokenise` and its skip-unknown-words flag.
- `encode_text`: the Z-string encoder (resolution 6 for V1-3, 9 for V4+).
- Terminating characters: the chat host only produces newline-terminated lines (13). The header's terminating-characters table is ignored.
- Deviations from Frotz (also listed at the top of `ZInput.luau`): the `-x` abbreviation expansion (`g`, `x`, `z`) is omitted, as it is off by default; the trailing-`?` removal Frotz applies for a list of Infocom stories (Zork, Planetfall and others) is omitted because it needs Frotz's story identification table, so in those stories a question typed with a final `?` reaches the parser with the `?` attached to the last word; text already in a V5 input buffer is not pre-filled; lowercasing covers ASCII and Latin-1; word completion is not provided.

### Opcodes this phase fills in

| Opcodes | Behaviour |
| --- | --- |
| `read` (VAR 0x04), `tokenise`, `encode_text` | Real implementations through `ZInput`. V1-3 `read` also redraws the status line via `statusLine` if the host has it. |
| `read_char` | Through `host.readChar`; returns the ZSCII code. |
| `restart` | Re-seeds RAM from the story image (`ZMemory:seedRam`), resets the state, re-applies header settings. |
| `show_status` | Through `statusLine` if available, otherwise nothing. |
| `print_table` | Real implementation (text only; needs the cursor column and line count from the host, default to simple lines). |
| `split_window`, `set_window`, `erase_window`, `erase_line`, `set_cursor`, `get_cursor`, `set_text_style`, `set_colour`, `set_true_colour` | Through the matching capability if present; otherwise ignored, and `get_cursor` stores 1,1. |
| `set_font` | Stores 0 (font not available) unless the host supports the font. |
| `buffer_mode`, `sound_effect`, `input_stream` | Ignored. |

Every opcode implemented here is removed from `EXPECTED_UNSUPPORTED` in `tests/OpcodeTableTests.luau`. `save`/`restore` and the V6-only opcodes stay as `unsupported` stubs.

### `ZMachine` (run loop)

- **Start up:** `ZMemory:initialize`, then read the header, build the state, call `applyVersionPatches(version)`, and create the output (`ZOutput.new(host.write, makeRam(state))`) and text (`makeText(state)`) objects. This is also where `output.toZscii` is connected to `state.text:toZscii`; today nothing does that, and the tests wire it by hand.
- **Running:** call `step` until `state.finished` is set. `ZState:tick` already yields every 10,000 instructions. Flush output before every blocking host call.
- **Errors:** the whole loop runs under `pcall`. A fatal error table goes to `host.fatal`. A Luau error that is not a fatal table is reported as an interpreter fault.
- **Restart:** handled by the loop, because it must rebuild the state while keeping the host and the loaded ROM.

## Steps

| Step | Work |
| --- | --- |
| 5.1 | `tests/ChatProbe.luau`: lines of increasing length to find where the viewer cuts chat. Owner runs it; the result sets the default `maxBytes`. |
| 5.2 | `ZHost.luau` (type and defaults) and `ChatHost.luau`. The chunker is a pure function with tests: size limit, word and newline boundaries, UTF-8 safety, one word longer than the limit, empty text, trailing newline. The listener lifecycle is tested with injected listen and unlisten functions. |
| 5.3 | `ZInput.luau`: line reading, tokenising, `lookup_text` and `encode_text`, tested against Adventureland's dictionary (known words, unknown words, separators, abbreviation-length truncation). |
| 5.4 | The input opcodes: `read`, `tokenise`, `encode_text`, `read_char`, `print_table`, `restart`, `show_status`. Opcode tests drive them with a scripted fake host. |
| 5.5 | Screen opcodes with plain-text defaults; update the table audit. |
| 5.6 | `ZMachine.luau` run loop; tests with a scripted fake host (a short transcript of commands and expected output). |
| 5.7 | In-world: play Adventureland through chat. Measure free memory, `romCacheMisses`, and the RAM counters; revisit the cache size and the script split if free memory falls below about 20 KB. |

## Deferred

- Interrupt routines other than the input timeout (sound-finished and newline-countdown calls), which would reuse `state.directCall`.
- Save/restore (Quetzal) and undo.
- Other hosts (HUD, web page) and the windows, styles and colours they would provide.
- Output to a transcript or command file (streams 2 and 4).
- Sound.

## Open items carried over from Phase 4

- `ZOutput.toZscii` is not connected to `state.text:toZscii` by `makeRam`/`makeText` (see "Start up").
- Chat output is limited to 1024 bytes per message: the chunker must work in bytes, not characters.
- `verify` takes about a minute on Adventureland because it reads every page through the ROM service. Acceptable for a rarely used opcode.
- Stories with more than about 45 KB of dynamic memory cannot keep a second RAM copy in LinksetData. This matters only for undo.

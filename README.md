# Second-Frotz

Second-Frotz is a Luau implementation of a Z-machine interpreter designed to
run in Second Life. It is a separate port inspired by Frotz; it is not the
original C interpreter or a general-purpose desktop interpreter.

The project is organized around Second Life's script and memory constraints:

- The VM executes story instructions and keeps dynamic memory in bounded RAM.
- A Memory Manager loads read-only story data from notecards a page at a time.
- A Text Service handles player input and output separately from the VM. The
  included chat host displays output in chat and reads the owner's chat as game
  input.

## Status

The repository contains the interpreter core, notecard Memory Manager, Text
Service, chat host, story converter, and a collection of in-runtime tests.
The deployment instructions below describe the current three-script layout.

The implementation targets Z-machine versions 1-5, 7, and 8. Version 6 is
refused by the current memory/header loader. Save/restore, undo, sound, and
full graphics/window support are not provided; see the design documents for
details and current development notes.

## Requirements

- A Second Life environment that runs the project's Luau scripts and provides
  the `ll` APIs used by the code.
- Python 3 to convert a story file into notecard data.

This project is not intended to run unchanged under standard Lua or standalone
Luau: the runtime scripts depend on Second Life APIs, link messages, notecards,
and LinksetData.

## Prepare a story

Convert a Z-machine story file into one or more ROM notecard text files:

```powershell
python tools/zmachine_to_notecard.py path\to\story.z5 "ZMachine ROM"
```

The converter writes `ZMachine ROM.1`, `ZMachine ROM.2`, and so on. The default
page size is 762 bytes and each card holds at most 64 pages. The output includes
a format header, Base64-encoded pages, and a SHA-256 checksum. The final page is
zero-padded. Options are available for page size and pages per card; see:

```powershell
python tools/zmachine_to_notecard.py --help
```

Create one notecard in Second Life for each generated file, using the filename
as its notecard name. Add all numbered cards to the prim that will run the
interpreter. The Memory Manager expects the base name `ZMachine ROM`, as set in
[`VM/ZMachine.luau`](VM/ZMachine.luau); change `STORY_NAME` there if you use a
different base name.

The `data/` directory contains sample story files and already converted
notecard data for development and testing.

## Run in Second Life

1. Put the Memory Manager, Text Service, and core VM scripts in the same prim.
   Their source files are [`VM/Memory Manager.luau`](VM/Memory%20Manager.luau),
   [`VM/Text Service.luau`](VM/Text%20Service.luau), and
   [`VM/ZMachine.luau`](VM/ZMachine.luau).
2. Add the numbered story notecards to that prim.
3. Reset the scripts in this order: Memory Manager, Text Service, then core VM.
4. The story output appears in chat. Enter commands in the owner's public chat
   while the game is waiting for input.
5. To start the story again after it ends, reset the core VM script.

The VM and Text Service share story RAM through LinksetData and communicate
using link messages. The notecard Memory Manager serves the read-only ROM
pages. See [`docs/MEMORY_MANAGER.md`](docs/MEMORY_MANAGER.md) and
[`docs/TEXT_SERVICE.md`](docs/TEXT_SERVICE.md) for the formats, protocol, and
runtime behavior.

## Tests

Tests in `tests/` are Luau scripts intended to run in the target runtime, not
through a local Lua test runner. They cover memory, state, opcode, object,
text, chat-host, coroutine, link-message, and text-service behavior. Test
scripts that load stories require the relevant fixture notecards to be present
in the test prim. The `*Probe*` scripts measure or demonstrate runtime behavior
in-world.

## Project layout

| Path | Contents |
| --- | --- |
| `VM/` | Interpreter modules and the three runtime scripts |
| `data/` | Sample stories and generated ROM notecard data |
| `docs/` | Architecture, memory, text-service, and development notes |
| `tests/` | In-runtime tests and Second Life probes |
| `tools/zmachine_to_notecard.py` | Story-to-notecard converter |

## Documentation

- [`docs/PORTING_PLAN.md`](docs/PORTING_PLAN.md) — overall port architecture
  and constraints
- [`docs/MEMORY_MANAGER.md`](docs/MEMORY_MANAGER.md) — ROM format, paging, and
  Memory Manager protocol
- [`docs/TEXT_SERVICE.md`](docs/TEXT_SERVICE.md) — VM/Text Service split and
  link-message protocol
- [`docs/PHASE3_PLAN.md`](docs/PHASE3_PLAN.md) and
  [`docs/PHASE4_PLAN.md`](docs/PHASE4_PLAN.md) — state and opcode design notes
- [`docs/PHASE5_PLAN.md`](docs/PHASE5_PLAN.md) — host, input, and run-loop
  development history

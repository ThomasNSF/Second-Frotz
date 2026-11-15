# Phase 4 Plan: Opcode Dispatch

This document plans Phase 4 from [PORTING_PLAN.md](PORTING_PLAN.md): the opcode execution model. Phase 3 ([PHASE3_PLAN.md](PHASE3_PLAN.md)) delivered `ZState` — stack, frames, variables, `call`/`ret`/`branch` — and is validated in-world. Phase 4 builds the layer that turns story bytes into calls against those primitives.

## Scope

### In scope

- Instruction decoding: opcode form classification and operand loading
- The opcode dispatch tables and their version-dependent patching
- A `step(state)` entry point that decodes and executes exactly one instruction
- Opcode handlers for control flow, stack, variables, arithmetic, comparison, and memory tables
- A new object-table module and its opcodes
- A new text-decoding module, a minimal output seam, and the print opcodes
- Explicit stubs for opcodes deferred to later phases

### Out of scope

- The fetch/execute **loop** (`while not finished`) and `direct_call` re-entry — Phase 5
- Real screen/window management, colour, fonts, sound — host-adapter phase
- Input (`z_read`, `z_read_char`, `z_tokenise`) and the dictionary — needs a host input path
- Save/restore (Quetzal), undo
- V6 graphics and the EXT opcodes that depend on pictures or windows

The split against Phase 5 is deliberate: Phase 4 ends with "execute one instruction correctly," which is testable without a loop, an input path, or a screen.

## Source material

| Concern | Reference |
| --- | --- |
| Dispatch tables, operand loading, form classification | [Frotz/src/common/process.c](Frotz/src/common/process.c#L35-L305) |
| Arithmetic, comparison, shifts | [Frotz/src/common/math.c](Frotz/src/common/math.c) |
| Memory tables | [Frotz/src/common/table.c](Frotz/src/common/table.c) |
| Object tree, attributes, properties | [Frotz/src/common/object.c](Frotz/src/common/object.c) |
| Text decoding, ZSCII, print opcodes | [Frotz/src/common/text.c](Frotz/src/common/text.c) |
| Random number generator | [Frotz/src/common/random.c](Frotz/src/common/random.c) |
| Version-dependent table patching | [Frotz/src/common/fastmem.c](Frotz/src/common/fastmem.c#L552-L559) |

## Module layout

**Decision: one module for decode, tables, and all handlers. Separate modules only for genuine subsystems.**

```text
VM/
  ZOpcodes.luau   -- operand decoding, step(), the opcode tables, and all ~90 handlers
  ZObject.luau    -- object-table addressing (new subsystem)
  ZText.luau      -- ZSCII and string decoding (new subsystem)
  ZOutput.luau    -- minimal output sink (host adapter replaces later)
```

Splitting the handlers by category was considered and rejected. Most handlers are tiny — `z_add` is one line, most are under five — so decode plus tables plus ninety handlers lands around 700-900 lines: large, but overwhelmingly a flat list of small functions with no deep interdependency. Against that:

- **Deployment friction.** Every required module is a separate script asset in the prim's inventory. Each extra file is another asset to upload and keep in sync on every deploy.
- **Memory moves the wrong way.** Splitting saves nothing (all modules load into the same script) and each one adds its own chunk and export-table overhead against the 128K budget.
- **Review granularity does not come from file boundaries.** Phase 3 built `ZState.luau` to roughly 580 lines across six reviewed slices. Handlers can land the same way: a category at a time, appended to one file.
- **Category boundaries are arbitrary here.** Frotz's file split partly reflects C compilation units, which do not apply. Any "control flow plus stack plus variables" grouping is a grab-bag.

`ZObject`, `ZText`, and `ZOutput` stay separate for a different reason: they are subsystems with their own APIs that other code calls, not collections of dispatch targets. `ZText` gets reused by the dictionary and input path later, `ZObject` is a data-structure accessor, and `ZOutput` gets swapped wholesale by the host adapter — the same reason `ZMemory` and `ZState` are separate from each other.

No dependency cycles: `ZOpcodes` depends on `ZState`, `ZObject`, `ZText`, and `ZOutput`; none of them depend on it.

Script length is not a constraint here — SLua scripts can run well past 900 lines — so the single-module decision stands on its own merits rather than being forced either way.

## Architecture notes

### Handler signature

C handlers are `void (*)(void)` reading the `zargs`/`zargc` globals. The port passes state explicitly:

```luau
type Handler = (ZState.ZState) -> ()
```

Handlers read `state.zargs` (1-indexed, preallocated, length 8) and `state.zargc`. **The C source is 0-indexed**: every `zargs[0]` in the reference becomes `state.zargs[1]`. This off-by-one is the single most likely source of transcription bugs in Phase 4 and is worth a consistent mental rule rather than case-by-case translation.

### Tables are 0-based

Z-machine opcode numbers are 0-based and the C tables are plain arrays. Luau arrays are conventionally 1-based, so either offset at every lookup or use an explicit `{[0] = ..., [1] = ...}` map. **Recommendation: `{[0] = handler, ...}` keyed maps**, so the table literal reads in the same order as the C source and no arithmetic sits between an opcode number and its handler.

### 2OP and VAR share one table

[process.c:272-294](Frotz/src/common/process.c#L272-L294) dispatches 2OP through `var_opcodes[opcode & 0x1f]` and VAR through `var_opcodes[opcode - 0xc0]`. This is not a coincidence to be tidied away: 2OP opcodes 0-31 *are* VAR opcodes 0xC0-0xDF, same operations with different operand encodings. Keep one table.

### Everything can yield

Every handler that touches memory inherits `ZMemory`'s contract: it may suspend while a ROM page is fetched. That includes operand loading (variable operands read globals), `store` (reads a byte from the PC stream), `branch`, and every object and text operation. There is no synchronous path and no handler may assume one.

### Allocation discipline

`zargs` is already preallocated and reused. The same rule applies to anything Phase 4 adds in the hot path — particularly the text decoder, which must not build a table per character. Use a reused buffer plus `table.concat`, or accumulate into a `buffer`.

## Cross-cutting correctness notes

These are the details most likely to be ported wrong. Each is a real behavior in the reference, not a style preference.

### Store-then-branch order is load-bearing

Several opcodes both store a result and branch: `z_get_child`, `z_get_sibling`, `z_scan_table`. Both `store()` and `branch()` consume bytes from the PC stream, so the instruction encoding is `[opcode][operands][store byte][branch bytes]` and the handler **must** call store before branch. Reversing them does not produce a wrong value — it desynchronises the PC, which fails far away from the cause.

### Object-0 errors are the non-fatal class

[object.c](Frotz/src/common/object.c) calls `runtime_error(ERR_GET_CHILD_0)` and friends, then *continues* with a defined fallback (`store(0); branch(FALSE); return;`). Those codes are 19-35, which [err.c](Frotz/src/common/err.c#L118-L132) reports and returns from. Using `ZState:runtimeError` (which raises) instead of `ZState:runtimeWarning` would abort stories that Frotz plays fine. Phase 4.4 is where the minor-code message table finally gets populated.

### The random LCG overflows float64

[random.c:77](Frotz/src/common/random.c#L77) is `A = 0x015a4e35L * A + 1` in 32-bit wraparound arithmetic. In Luau, `0x015a4e35 * A` with `A` near 2^32 reaches about 9.7e16, well past 2^53, so the product is no longer an exact integer and `(A >> 16) & 0x7fff` yields the wrong stream. The multiply must be split into 16-bit halves (or done with `bit32` piecewise) and reduced mod 2^32 at each step. A story seeded identically must produce an identical sequence, so this is directly testable.

### `z_je` is variadic

[math.c:123-129](Frotz/src/common/math.c#L123-L129) compares operand 1 against up to three others, short-circuiting on `zargc`. It is a 2OP opcode that can also appear in VAR form with up to four operands.

### `z_scan_table` supplies a default operand

[table.c:144-145](Frotz/src/common/table.c#L144-L145): when `zargc < 4`, `zargs[3]` defaults to `0x82` — word array, step 2. Bit 7 selects word vs byte; the low seven bits are the address step. It stores the found address (or 0) *and* branches on it.

### `z_copy_table` direction

[table.c:60-78](Frotz/src/common/table.c#L60-L78): destination 0 means zero-fill. A **negative** size forces a forward copy even when the ranges overlap; otherwise the direction depends on whether source is above destination. Getting this backwards corrupts overlapping copies only — it will pass naive tests.

### `z_get_prop_len` takes a property address

[object.c:609-635](Frotz/src/common/object.c#L609-L635) is the one property opcode whose operand is not an object. It backs up one byte from the given address to read the size byte, and returns 0 for address 0 (Spec 1.1).

### Property lists are scanned by descending ID

`z_get_prop`, `z_get_prop_addr`, `z_put_prop`, and `z_get_next_prop` all walk the list until `(value & mask) <= target`, relying on properties being stored in descending ID order. The size-byte format differs between V1-V3 (`value >> 5`) and V4+ (two-byte form when bit 7 is set, with `0` meaning 64 per Spec 1.0) — see `next_property` at [object.c:149-171](Frotz/src/common/object.c#L149-L171).

### Text decode addresses can exceed 64K

[text.c:402-436](Frotz/src/common/text.c#L402-L436) widens the address to a `zlong` specifically because packed high strings in V8 exceed 16 bits, and raises `ERR_ILL_PRINT_ADDR` past `story_size` or when a low address passes `0xffff`.

## Phase 4.1: Dispatch skeleton

Delivers a working decoder that dispatches to stub handlers. No real opcodes yet.

| Step | Work |
| --- | --- |
| 4.1.1 | Add `ZState:store(value)` (`storeResult(codeByte(), value)` — the C `store()` helper; ~40 opcodes need it) and value-level `toS16`/`toU16` helpers. Add `ERR_DIV_ZERO` (3) and `ERR_ILL_OPCODE` (11) to `ZState.Errors`. |
| 4.1.2 | `ZOpcodes.luau`: the four backing tables (`op0`, `op1`, `var` — shared by 2OP and VAR — and `ext`) as `{[0] = ...}` maps, populated with `illegal` placeholders; `illegal` raises `ERR_ILL_OPCODE`. |
| 4.1.3 | Version patching at init: V1-V4 sets `op0[0x09] = z_pop`, `op1[0x0f] = z_not`; V5+ sets `z_catch` / `z_call_n` ([fastmem.c:552-559](Frotz/src/common/fastmem.c#L552-L559)). |
| 4.1.4 | Operand decoding: `loadOperand(state, type)` and `loadAllOperands(state, specifier)` filling `state.zargs`/`zargc`. Operand types: 0 large constant, 1 small constant, 2 variable, 3 omitted. |
| 4.1.5 | `ZOpcodes.step(state)`: fetch opcode, classify form (`<0x80` 2OP, `<0xB0` 1OP, `<0xC0` 0OP, else VAR), handle the 0xBE extended escape and the two-specifier call opcodes 0xEC/0xFA, dispatch. |
| 4.1.6 | Tests: synthetic bytecode in scratch RAM, stub handlers recording what they received. Cover all four forms, both 2OP operand-type bits, omitted-operand termination, 8-operand calls, and `illegal`. |

## Phase 4.2: Control flow, stack, variables

Everything here needs only `ZState` — no new subsystems.

| Step | Work |
| --- | --- |
| 4.2.1 | Returns and jumps: `z_rtrue`, `z_rfalse`, `z_ret`, `z_ret_popped`, `z_jump` (with `ERR_ILL_JUMP_ADDR` bounds check), `z_nop`, `z_quit`. |
| 4.2.2 | Calls: `z_call_s`, `z_call_n` in all encodings, including the 8-argument 0xEC/0xFA forms. Routine address 0 stores 0 (for `call_s`) or does nothing (`call_n`). |
| 4.2.3 | Frame introspection: `z_check_arg_count`, `z_catch`, `z_throw` — thin wrappers over the Phase 3 primitives. |
| 4.2.4 | Stack: `z_push`, `z_pop`, `z_pull` including the V6 user-stack path ([variable.c:319-348](Frotz/src/common/variable.c#L319-L348) — note V6 `pull` consumes a store byte and non-V6 does not), `z_pop_stack`, `z_push_stack`. |
| 4.2.5 | Variables: `z_load`, `z_store`, `z_inc`, `z_dec`, `z_inc_chk`, `z_dec_chk` — all using the in-place variable path, not `storeResult`. |
| 4.2.6 | Tests, including a `call_s` → `ret` round trip driven entirely through `step()` on synthetic bytecode. |

## Phase 4.3: Arithmetic, comparison, tables

| Step | Work |
| --- | --- |
| 4.3.1 | Arithmetic: `z_add`, `z_sub`, `z_mul`, `z_div`, `z_mod`. Signed 16-bit semantics throughout; division and modulo by zero raise `ERR_DIV_ZERO`. Results wrap mod 65536. |
| 4.3.2 | Bitwise and shifts: `z_and`, `z_or`, `z_not`, `z_log_shift` (logical, zero-fill), `z_art_shift` (arithmetic, sign-propagating). Negative shift counts shift right. |
| 4.3.3 | Comparison: `z_je` (variadic), `z_jl`, `z_jg`, `z_jz`, `z_test`. Signed comparisons for `jl`/`jg`/`jz`, unsigned for `je`/`test`. |
| 4.3.4 | `z_random` plus the LCG, with the split-multiply fix for float64 precision. Includes the "special mode" cycle for seeds below 1000 and reseeding on non-positive operands. |
| 4.3.5 | Memory tables: `z_loadw`, `z_loadb`, `z_storew`, `z_storeb`. |
| 4.3.6 | `z_copy_table` (three directions) and `z_scan_table` (default operand, store-then-branch). |
| 4.3.7 | Tests, including a fixed-seed random sequence compared against values captured from the reference C build. |

## Phase 4.4: Object system

The first new subsystem. All reads go through `ZMemory` and can yield.

| Step | Work |
| --- | --- |
| 4.4.1 | Populate `ZState`'s minor-error message table (codes 19-35) and confirm `runtimeWarning` reports and returns without raising. |
| 4.4.2 | `ZObject.luau`: version constants (V1-V3: 9-byte entries, 31 defaults, 62-byte offset; V4+: 14-byte entries, 63 defaults, 126-byte offset), `objectAddress`, `objectName`, `firstProperty`, `nextProperty`. Skip Frotz's Beyond Zork special case, consistent with the Phase 3 decision to omit per-story quirks. |
| 4.4.3 | Tree reads: `z_get_parent`, `z_get_child`, `z_get_sibling`, `z_jin` — each with its object-0 warning path and defined fallback, and store-before-branch where both apply. |
| 4.4.4 | Tree mutation: `unlinkObject`, `z_remove_obj`, `z_insert_obj`. The sibling-chain walk in `unlink_object` ([object.c:180-264](Frotz/src/common/object.c#L180-L264)) is the subtlest code in the object file. |
| 4.4.5 | Attributes: `z_test_attr`, `z_set_attr`, `z_clear_attr`. Attribute `n` lives at bit `0x80 >> (n & 7)` of byte `n / 8`; range check is 31 for V1-V3 and 47 for V4+. |
| 4.4.6 | Properties: `z_get_prop`, `z_put_prop`, `z_get_prop_addr`, `z_get_prop_len`, `z_get_next_prop`, including the property-defaults fallback for a missing property. |
| 4.4.7 | Tests against Adventureland's real object table: traverse the tree from the root, verify parent/child/sibling consistency, round-trip attributes and properties, and confirm a removed object is unreachable from its former parent's child chain. |

## Phase 4.5: Text decoding and output

The second new subsystem, and the first point where the interpreter produces visible output.

| Step | Work |
| --- | --- |
| 4.5.1 | `ZOutput.luau`: `putChar`/`putString` accumulate into a reused buffer; `flush` emits the accumulated text as one chunk. **The chunk is the unit delivered to the host** — not the character, not the line. This matters in Second Life, where chat calls are expensive and rate-limited, so per-character delivery would be unusable. Phase 4 supplies a test-readable backend; the host adapter swaps it later. `z_new_line` flushes; the input path will flush before reading once it exists. |
| 4.5.2 | `ZText.luau` part one: the three alphabet tables, the V5+ custom alphabet-table override, and ZSCII↔Unicode translation including the story's own Unicode table when present. |
| 4.5.3 | `ZText.luau` part two: `decodeText` — the three-Z-characters-per-word unpacking, shift states and locks (V1-V2 lock semantics differ from V3+), abbreviations, and the two-part ZSCII escape. Must handle all string types (embedded in code, low string, high packed string, abbreviation, vocabulary-into-buffer). |
| 4.5.4 | Print opcodes: `z_print`, `z_print_ret`, `z_new_line`, `z_print_char`, `z_print_num`, `z_print_addr`, `z_print_paddr`, `z_print_obj`. |
| 4.5.5 | Tests: decode known strings out of Adventureland and compare against expected text; the bundled [data/Adventureland.text](../data/Adventureland.text) transcript gives real strings to check against. Include an abbreviation-expanding string and a string containing a ZSCII escape. |

## Phase 4.6: Gating and deferrals

| Step | Work |
| --- | --- |
| 4.6.1 | **Done.** `print_unicode`, `check_unicode`, `piracy` and `verify`. Code points that are control codes (below 0x20, 0x7F-0x9F), surrogates, or 0xFFFE/0xFFFF print as `?` and report 0 from `check_unicode`, because the Z-machine standard forbids control characters and they are not valid UTF-8 scalars; `check_unicode` otherwise assumes the host can print anything and reports readable only if ZSCII can represent the character. `piracy` always branches. `verify` sums the pristine story image, yielding via `tick()`. |
| 4.6.2 | Explicit stubs for every deferred opcode — screen, window, colour, font, sound, mouse, save/restore/undo, input, V6 graphics. **Stubs raise**, halting the story rather than warning and continuing: a story that reaches an unimplemented opcode is running outside what the port supports, and letting it stagger on produces misleading downstream failures. Use an error code distinct from `ERR_ILL_OPCODE` so "we haven't built this yet" is diagnosable apart from "this story file is corrupt or incompatible" — they call for opposite responses. |
| 4.6.2a | **Done.** `ZState.Errors.UNSUPPORTED` (100, outside Frotz's numbering) and `ZState:unsupportedOpcode(name)` raise a fatal error carrying `opcode = name`. `ZOpcodes` builds stubs with `unsupported(name)`: 39 slots (15 V6-only EXT opcodes; save/restore in both forms; restart, show_status, and the screen, sound, font, colour and input opcodes still to come). `illegal` is now only for slots no version defines (2OP/VAR 0, VAR 0x1D-0x1F, EXT 0x0E-0x0F). `save_undo` stores -1 and `restore_undo` stores 0, the spec's "undo unavailable" answers. |
| 4.6.3 | **Done.** `tests/OpcodeTableTests.luau` (11 tests): for V3 and V5, every slot of all four tables is a real handler, a listed `illegal` slot, or an expected stub; table sizes are 16/16/64/29. When an opcode is implemented, remove it from `EXPECTED_UNSUPPORTED` in that test. |
| 4.6.4 | Full regression run of every Phase 4 test file plus the Phase 3 suite. |

## Testing approach

Each sub-phase gets its own file under `tests/`, following the pattern `StateTests.luau` established: one `ZMemory` load, a fresh `ZState` per test, synthetic bytecode written into the scratch region near the top of dynamic memory, and a printed pass/fail summary.

Phase 4 adds one capability the Phase 3 tests lacked: **executing real story bytecode**. From 4.2 onward, tests can point the PC at Adventureland's actual start address and single-step through real instructions, checking that the PC advances sensibly and that nothing raises. That is a much stronger signal than synthetic bytecode alone, and it is the natural smoke test at the end of each sub-phase.

Two constraints carry over from Phase 3: tests mutate dynamic memory and must not be followed by real gameplay on the same state, and everything runs inside a `CoroutineMgr` task.

## Completion criteria

Phase 4 is complete when:

- every opcode form decodes correctly, including extended and 8-argument calls
- all four opcode tables are fully populated with handlers, deliberate stubs, or `illegal`
- control flow, stack, variable, arithmetic, comparison, table, object, and print opcodes are implemented and tested
- the random generator reproduces the reference sequence for a fixed seed
- text decoding reproduces known strings from the bundled story
- `step(state)` can single-step through real Adventureland bytecode from the story's start PC without raising
- every Phase 4 test file passes in-world, and the Phase 3 suite still passes

## Decisions

1. **Output granularity.** The host receives flush-delimited chunks, not characters or lines. See step 4.5.1.
2. **Stubs raise.** Deferred opcodes halt the story, with an error code distinct from `ERR_ILL_OPCODE`. See step 4.6.2.
3. **Module layout.** One `ZOpcodes.luau` for decode, tables, and handlers; separate modules only for the three subsystems. Script length is not a limiting factor.
4. **V6 is out of scope.** `ZMemory:readHeader` refuses V6 stories. The V6-only EXT slots (0x05-0x08, 0x10-0x14, 0x16, 0x17, 0x19-0x1C) stay unimplemented and get a distinct "unsupported" error in 4.6.2. V7 and V8 add no opcodes, only different packed-address scaling, which `ZState` already handles. `push_stack`/`pop_stack` (0x18/0x15) stay.
5. **Text and output stay in the core, for now.** `ZText` and `ZOutput` are modules that take explicit arguments (memory, header, sink) and do not require `ZState` or `ZOpcodes`, so extracting either into its own script later is mechanical. Measured headroom after story and state load is 48 KB; revisit if it falls below ~20 KB or text decoding costs far more than the ~20 KB estimate. Save/Load is the likeliest first script to leave.
6. **Dynamic memory is paged to LinksetData for larger stories.** A flat `ram` buffer leaves too little room for a story like `zdungeon` (32 KB of dynamic memory), so `ZMemory` keeps a small resident set of 256-byte pages and stores the rest in LSD as Base64, falling back to one flat buffer when dynamic memory is small. The `ZMemory` API and the opcode code are unaffected. Implemented and validated in-world (`tests/RamPagingTests.luau`, Adventureland and zdungeon). Measured LSD behaviour and the design are in PORTING_PLAN.md ("Paging dynamic memory to LinksetData").

### Deferred to Phase 5 planning

**Where the execution driver lives.** `step` is exported from `ZOpcodes.luau`, which is all Phase 4 needs — a driver can sit anywhere without changing Phase 4 work. What Phase 5 has to settle is how `direct_call` re-entry is wired, because the C structure is circular: `interpret()` dispatches into a handler, the handler calls `call()`, and `call()` with `ct == 2` re-enters `interpret()` ([process.c:368-369](Frotz/src/common/process.c#L368-L369)). A direct `require` cycle cannot express that, since `ZOpcodes` already requires `ZState`.

Two ways out:

- **Caller drives** (what Phase 3 chose): `ZState:call` sets up the `CT_DIRECT` frame and returns; whoever initiated the direct call runs the loop itself and reads the result off the stack. No cycle, because `ZState` never learns the loop exists.
- **Hook injection**: `ZState` carries an `interpretHook` field that Phase 5 populates, and `call` invokes it for `CT_DIRECT`. Preserves Frotz's control flow exactly, at the cost of a runtime-injected dependency.

The related question is whether `run` joins `step` in `ZOpcodes` or gets its own module. It is one small function today, but by the end of Phase 5 the driver also owns the `finished` counter semantics, the top-level `pcall` boundary from the Phase 3 error strategy, and `direct_call` — and it is the surface the host adapter talks to, which argues for not making the host require a 900-line opcode module to reach it. Neither choice constrains Phase 4.

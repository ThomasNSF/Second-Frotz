# Phase 3 Plan: Execution State

This document plans the Phase 3 deliverable from [PORTING_PLAN.md](PORTING_PLAN.md): the Z-machine runtime state object and the state-manipulation primitives that opcode handlers will call.

Phase 2 (the memory abstraction) is complete: `VM/zmemory.luau` provides an async, coroutine-safe paged view of the story image with an enforced RAM/ROM boundary. Phase 3 builds the execution state that sits on top of it.

## Scope

### In scope

- The `ZState` object holding all mutable interpreter state
- Stack and call-frame representation
- `call` / `ret` frame mechanics
- Variable read/write (stack, locals, globals)
- PC-stream read helpers (`codeByte`, `codeWord`)
- The `store` and `branch` primitives
- `catch` / `throw` frame bookkeeping
- Packed-address unpacking by story version
- Startup and restart sequencing
- Runtime error taxonomy

### Out of scope

- Opcode handler implementations (Phase 4)
- The opcode dispatch tables and operand decoding (Phase 4)
- The `interpret()` fetch/decode/execute loop (Phase 5)
- Text decoding, object tree, dictionary (later phases)
- Save/restore serialization (the frame format is designed to permit it, but Quetzal itself is deferred)

Phase 3 is done when a Phase 4 opcode handler can be written against a stable, tested state API without needing to know how the stack is stored.

## Version coverage

**Decision: the state layer targets the full V1-V8 range, V6 included.**

The versions are not equally expensive, and it is worth being explicit about where the cost actually lands:

- **V7 and V8 are nearly free.** V8 is effectively V5 with a larger address space (8x packing); V7 is rare and differs mainly in routing routine and string unpacking through `functionsOffset` and `stringsOffset`. Both fall out of the unpacking table below at no extra cost.
- **V6 is the outlier**, but almost none of its cost is in Phase 3. What Phase 3 owes V6 is three small things: `startPc` is a packed *routine* address rather than a byte address, unpacking uses `functionsOffset`, and `pull` switches to user-stack semantics. All three are specified in this document.
- **V6's real bill arrives in the host-adapter phase**: eight windows, pixel-accurate positioning, `draw_picture` / `picture_data` / `move_window` / `window_size` / `set_margins`, and Blorb resources for the images themselves — which [PORTING_PLAN.md](PORTING_PLAN.md) currently lists as out of scope.

Supporting all versions in the state layer therefore costs very little and keeps the option open. Whether V6 stories eventually run with graphics or text-only is a separate decision that can wait for the screen phase.

## Source material

All behavior below was read from the reference C implementation:

| Concern | Reference |
| --- | --- |
| State globals, macros, `STACK_SIZE`, error codes | [Frotz/src/common/frotz.h](Frotz/src/common/frotz.h) |
| `z_header_t` struct | [Frotz/src/common/setup.h](Frotz/src/common/setup.h#L63-L107) |
| `call`, `ret`, `branch`, `store`, `direct_call`, `catch`/`throw` | [Frotz/src/common/process.c](Frotz/src/common/process.c) |
| Variable access and the indirect-reference rules | [Frotz/src/common/variable.c](Frotz/src/common/variable.c) |
| `z_restart`, `restart_header`, `storeb` header hook, `story_size` | [Frotz/src/common/fastmem.c](Frotz/src/common/fastmem.c) |

## The C state model

Frotz keeps interpreter state in file-scope globals ([frotz.h](Frotz/src/common/frotz.h#L613-L624)):

```c
extern zword stack[STACK_SIZE];   /* STACK_SIZE defaults to 1024 */
extern zword *sp;                 /* stack pointer  */
extern zword *fp;                 /* frame pointer  */
extern zword frame_count;         /* for catch/throw */
extern zword zargs[8];            /* current instruction operands */
extern int   zargc;               /* operand count */
extern long  story_size;
static int   finished;            /* process.c, loop-exit counter */
```

The program counter is not a variable but a pointer, `zbyte *pcp`, walked by macros:

```c
#define CODE_BYTE(v) { v = *pcp++; }
#define CODE_WORD(v) { v = ((zword) pcp[0] << 8) | pcp[1]; pcp += 2; }
#define GET_PC(v)    { v = pcp - zmp; }
#define SET_PC(v)    { pcp = zmp + v; }
```

Because our memory is paged and every read may yield, `pcp` cannot be a pointer. **The PC becomes an explicit numeric field on the state object**, and `CODE_BYTE`/`CODE_WORD` become yielding functions that read through `ZMemory` and advance `state.pc`.

Frotz also keeps a *parsed shadow copy* of the header in `z_header` alongside the live memory image. `ZMemory.readHeader()` already produces the equivalent `StoryHeader` table; `ZState` will own one.

### Header field naming map

Frotz and `zmemory.luau` use different names for the same two header fields. The port must not confuse them:

| Header offset | Frotz name | `zmemory.luau` name | Meaning |
| --- | --- | --- | --- |
| 0x04 | `resident_size` | `highMemoryBase` | Base of high memory |
| 0x0E | `dynamic_size` | `staticMemoryBase` | Base of static memory == size of dynamic memory |

`storeb`'s range check `addr >= z_header.dynamic_size -> ERR_STORE_RANGE` ([fastmem.c:712](Frotz/src/common/fastmem.c#L712)) is already enforced by `ZMemory.writeU8` returning `false`. Phase 3 must translate that `false` into `ERR_STORE_RANGE`.

## Stack and frame layout

This is the highest-risk part of the port; it is specified here byte for byte.

### Growth direction

In C the stack grows **downward**. `z_restart` sets `sp = fp = stack + STACK_SIZE` ([fastmem.c:774](Frotz/src/common/fastmem.c#L774)); a push is `*--sp = v` and a pop is `v = *sp++`. So `sp` is the word index of the current top element, the occupied region is `[sp, STACK_SIZE)`, and the number of free slots is exactly `sp`.

**Decision: mirror the downward direction in Luau.** The port has roughly ninety opcode handlers still to translate, and several of them do raw frame arithmetic (`*(fp - zargs[0])`, `fp = stack + 1 + fp[1]`). Keeping the direction identical lets every one of those expressions translate literally instead of being mentally inverted, which is where off-by-one bugs come from. The cost is that the layout reads unusually to a Lua developer; that is worth one explanatory comment.

### Storage

**Decision: a `buffer` of `STACK_SIZE * 2` bytes, addressed by word index.**

A Lua array of 1024 numbers costs roughly 16 KB; the same stack as a buffer costs 2048 bytes. Under a 128 K code-plus-heap budget that difference matters.

```luau
-- push
state.sp -= 1
buffer.writeu16(state.stack, state.sp * 2, value)

-- pop
local value = buffer.readu16(state.stack, state.sp * 2)
state.sp += 1
```

Luau's `buffer.readu16`/`writeu16` are little-endian. That is irrelevant here: the stack is private interpreter storage and is never addressed by the story. Big-endian story layout is `ZMemory`'s concern and is already handled there. Do not conflate the two.

### Frame layout

`call()` pushes a four-word frame header ([process.c:317-370](Frotz/src/common/process.c#L317-L370)):

```c
GET_PC(pc)
*--sp = (zword) (pc >> 9);            /* return PC, high part */
*--sp = (zword) (pc & 0x1ff);         /* return PC, low 9 bits */
*--sp = (zword) (fp - stack - 1);     /* previous frame pointer */
*--sp = (zword) (argc | (ct << 12));  /* arg count and call type */
fp = sp;
frame_count++;
```

Locals are then pushed below it, so local `n` lives at `fp - n`. Resulting layout, low index to high:

```text
  fp - count   local[count]
  ...
  fp - 1       local[1]
  fp + 0       frame word    <- fp
  fp + 1       previous fp, encoded as (oldFp - 1)
  fp + 2       return PC bits 0..8
  fp + 3       return PC bits 9..
  ...          caller's working stack
```

The frame word packs three fields:

| Bits | Field | Range | Set by |
| --- | --- | --- | --- |
| 0-7 | `argc`, arguments actually supplied | 0-7 | `call` |
| 8-11 | `count`, number of locals | 0-15 | `fp[0] \|= count << 8` after reading the routine header |
| 12-15 | `ct`, call type | 0-2 | `call` |

Call types: `0` store the result, `1` discard the result, `2` direct call (re-enters the interpreter loop).

The return PC is split as 9 low bits plus the remainder because a `zword` is 16 bits and a V8 PC does not fit in one. Reassembly in `ret` is `pc = fp[2] | (fp[3] << 9)`.

The previous frame pointer is stored biased by one (`fp - stack - 1`) and restored as `stack + 1 + fp[1]`, which round-trips exactly. The bias exists so the initial `fp == stack + STACK_SIZE` is representable.

### Return

```c
if (sp > fp) runtime_error(ERR_STK_UNDF);
sp = fp;                        /* discard locals and working stack */
ct = *sp++ >> 12;
frame_count--;
fp = stack + 1 + *sp++;
pc = *sp++;
pc = ((long) *sp++ << 9) | pc;
SET_PC(pc)
if (ct == 0) store(value);
if (ct == 2) { *--sp = value; finished++; }
```

Note `sp = fp` before unwinding: this is what makes `throw` correct without separate stack cleanup.

### Luau frame constants

Define these once rather than scattering literals:

```luau
local FRAME_WORD    = 0   -- fp + 0
local FRAME_PREV_FP = 1   -- fp + 1
local FRAME_PC_LOW  = 2   -- fp + 2
local FRAME_PC_HIGH = 3   -- fp + 3

local CT_STORE   = 0
local CT_DISCARD = 1
local CT_DIRECT  = 2
```

## Variable access rules

Variable numbers are uniform across every opcode that takes one ([variable.c](Frotz/src/common/variable.c), [process.c:193-217](Frotz/src/common/process.c#L193-L217)):

| Number | Location |
| --- | --- |
| `0` | The stack |
| `1`-`15` | Local variable, at `fp - n` |
| `16`-`255` | Global, word at `header.globals + 2 * (n - 16)` |

### The variable-0 subtlety

This is the single easiest thing to get wrong, and Frotz is deliberate about it. Variable 0 means **push/pop** when the stack is used as an operand source or a store destination, but **modify in place** when the variable is named indirectly by an opcode:

| Operation | Variable 0 behavior | Reference |
| --- | --- | --- |
| `load_operand` (reading an operand) | pop: `value = *sp++` | [process.c:202](Frotz/src/common/process.c#L202) |
| `store` (storing a result) | push: `*--sp = value` | [process.c:488](Frotz/src/common/process.c#L488) |
| `z_store` | in place: `*sp = value` | [variable.c:397](Frotz/src/common/variable.c#L397) |
| `z_load` | peek, no pop: `value = *sp` | [variable.c:261](Frotz/src/common/variable.c#L261) |
| `z_pull` | pop, then write in place to new top | [variable.c:324-327](Frotz/src/common/variable.c#L324-L327) |
| `z_inc` / `z_dec` | in place: `(*sp)++` | [variable.c:167](Frotz/src/common/variable.c#L167) |

The state API must therefore expose **two** variable-write paths, not one:

```luau
ZState.storeResult(state, variable, value)   -- var 0 pushes
ZState.writeVariable(state, variable, value) -- var 0 replaces top
ZState.readVariable(state, variable)         -- var 0 pops
ZState.peekVariable(state, variable)         -- var 0 peeks
```

Naming them distinctly prevents Phase 4 handlers from reaching for the wrong one.

### V6 changes `pull` more than it looks

The table above describes the non-V6 path. In V6, `z_pull` takes a different shape entirely ([variable.c:319-348](Frotz/src/common/variable.c#L319-L348)):

| | Non-V6 | V6 |
| --- | --- | --- |
| Operand meaning | Variable number to write into | User-stack address, or absent |
| Result handling | Writes to that variable | Calls `store()`, consuming a store byte from the PC stream |
| With no operand | n/a | Pops the game stack, then stores |
| With one operand | Writes popped value to the variable | Increments the user stack's free-slot count, reads the value from `addr + 2 * size`, then stores |

The consequential difference is the store byte: V6 `pull` reads one **and** non-V6 `pull` does not, so the two forms consume different instruction lengths. Getting this wrong desynchronizes the PC rather than just producing a wrong value, which makes it hard to diagnose. The handler itself is Phase 4 work, but `storeResult` must be available for it.

## Packed address unpacking

`call()` unpacks a routine address by version ([process.c:338-345](Frotz/src/common/process.c#L338-L345)):

| Version | Routine byte address |
| --- | --- |
| V1-V3 | `routine * 2` |
| V4-V5 | `routine * 4` |
| V6-V7 | `routine * 4 + functionsOffset * 8` |
| V8 | `routine * 8` |

String unpacking uses `stringsOffset` instead of `functionsOffset` for V6/V7; it belongs to the text phase but should use the same shared helper. Provide `ZState.unpackRoutine(state, addr)` and `ZState.unpackString(state, addr)` in Phase 3 so the text phase inherits correct behavior.

## Routine prologue

After setting the PC, `call` reads the routine header:

```c
CODE_BYTE(count)
if (count > 15) runtime_error(ERR_CALL_NON_RTN);
if (sp - stack < count) runtime_error(ERR_STK_OVF);
fp[0] |= (zword) count << 8;
value = 0;
for (i = 0; i < count; i++) {
    if (z_header.version <= V4)
        CODE_WORD(value)        /* V1-V4 store default values inline */
    *--sp = (zword) ((argc-- > 0) ? args[i] : value);
}
```

Two details the indentation hides: the `if` guards only the `CODE_WORD` block (the macro supplies its own braces), and in V5+ there are no inline defaults, so uninitialized locals are zero. In Luau, write the argument test as `if i <= argc then args[i] else defaultValue`, and remember `args` is 1-based here but 0-based in C.

## Branch encoding

`branch(flag)` ([process.c:424-469](Frotz/src/common/process.c#L424-L469)):

1. Read one specifier byte. `off1 = specifier & 0x3f`.
2. If the flag is false, flip bit 7 (`specifier ^= 0x80`). This makes the remaining logic uniform.
3. If bit 6 is clear it is a long branch: sign-extend `off1` through bits 6-7 when bit 5 is set, read a second byte, `offset = (off1 << 8) | off2` as a 14-bit signed value.
4. If bit 6 is set it is a short branch: `offset = off1`, unsigned, 0-63.
5. If bit 7 is now set: `offset > 1` means `pc += signed(offset) - 2`; `offset == 0` means return false; `offset == 1` means return true.

Frotz does not bounds-check the branch target, though it does check `jump` and `call` targets. The port should add the same `ERR_ILL_JUMP_ADDR` check to `branch` for safety; `ZMemory.readU8` will assert on the next fetch anyway, so the only question is whether the failure is diagnosable.

## Runtime errors

Phase 3 raises these ([frotz.h:782-800](Frotz/src/common/frotz.h#L782-L800)):

| Code | Condition |
| --- | --- |
| `ERR_STK_OVF` | Fewer than 4 free words before a frame push, or fewer than `count` before locals |
| `ERR_STK_UNDF` | `sp > fp` on return |
| `ERR_ILL_CALL_ADDR` | Unpacked routine address at or beyond `storySize` |
| `ERR_CALL_NON_RTN` | Routine local count above 15 |
| `ERR_BAD_FRAME` | `throw` to a frame number above `frameCount` |
| `ERR_ILL_JUMP_ADDR` | Jump target at or beyond `storySize` |
| `ERR_STORE_RANGE` | Write at or above `staticMemoryBase` |

### Two error classes, not one

`_runtime_error` ([err.c:102-144](Frotz/src/common/err.c#L102-L144)) behaves in two completely different ways depending on the error number, and the distinction is load-bearing:

| Range | Behavior | Examples |
| --- | --- | --- |
| 1-18 (`errnum <= ERR_MAX_FATAL`) | Calls `os_fatal`, which **does not return**. Execution ends. | Every error Phase 3 raises |
| 19-35 | Prints a warning and **returns normally**. Execution continues. | `@jin called with object 0` and the other object-0 errors |

This is why C code such as `if (sp - stack < 4) runtime_error(ERR_STK_OVF);` can safely fall through into the push that follows: for a fatal code the call never comes back.

### Error strategy for the port

**Decision: `error()` plus a top-level `pcall` for the fatal class only.**

Lua's `error` is a precise match for `os_fatal` — a non-returning abort with a catch point at a chosen boundary. The minor class must *not* use `error()`; those are warnings that return, and raising on them would change execution semantics for stories Frotz runs happily.

```luau
-- fatal: unwinds to the interpreter's pcall boundary
ZState.runtimeError(state, ERR_STK_OVF)

-- minor: reports and returns, execution continues
ZState.runtimeWarning(state, ERR_JIN_0)
```

Two implementation requirements:

1. **Throw a table, not a string.** `error({ code = ERR_STK_OVF, pc = state.pc })` lets the handler separate a Z-machine fault from a genuine interpreter bug such as a nil index or arithmetic on nil. Those deserve different reporting: one is a bad story file, the other is our defect. Table payloads also avoid `error`'s automatic position-prefixing, which is noise here.
2. **`pcall` must be yieldable.** The interpreter loop lives inside the `pcall`, and every memory read within it can yield on a ROM page fault. Luau permits yielding across `pcall` where Lua 5.1 did not, so this should hold, but it is worth a short in-world smoke test before the design depends on it. If it does not hold, the catch boundary has to move outside the coroutine into `_run_coro` instead.

Note that `_run_coro` already provides an implicit outer catch, since `coroutine.resume` returns `false, err` rather than propagating. The explicit `pcall` adds a place to report into the game transcript before unwinding, and to tell the two failure kinds apart.

## Startup and restart

`z_restart` ([fastmem.c:755-783](Frotz/src/common/fastmem.c#L755-L783)) is the canonical initialization order:

1. Reload dynamic memory from the story image (skipped on first start, since it was just loaded).
2. `restart_header()` — write interpreter capabilities back into the live header.
3. `restart_screen()` — deferred to the host-adapter phase.
4. `sp = fp = stack + STACK_SIZE; frame_count = 0`.
5. If the version is not V6, `SET_PC(header.start_pc)` — `start_pc` is a direct byte address. If it is V6, `call(header.start_pc, 0, NULL, 0)` — in V6 `start_pc` is a *packed routine address*, not an address to jump to.

Step 5 means `call` must be usable before the main loop starts.

`restart_header()` ([fastmem.c:155-244](Frotz/src/common/fastmem.c#L155-L244)) writes interpreter identity and screen geometry back into the header: config byte, flags, interpreter number and version, screen rows and columns, and for V5+ the screen and font dimensions plus default colors, and the Standard revision number (Frotz claims 1.1). Phase 3 should implement the version-gated subset that does not require a real screen, using placeholder geometry, and leave a marked extension point for the host adapter to supply real values.

One live hook is required: writes to the flags register are special-cased in `storeb` ([fastmem.c:715-727](Frotz/src/common/fastmem.c#L715-L727)). A store to `H_FLAGS + 1` updates the shadow header's scripting and fixed-font bits and toggles transcription. Without this, the shadow header silently drifts from memory. Phase 3 should add the hook and leave the transcription side effect unimplemented.

## Proposed module

`VM/ZState.luau`, following the same conventions `zmemory.luau` established: a module table with a `new` constructor, an explicit instance passed to every function, no singleton at require time.

```luau
export type ZState = {
    memory: ZMemory.ZMemory,
    header: ZMemory.StoryHeader,

    pc: number,
    stack: buffer,      -- STACK_SIZE words, grows downward
    sp: number,         -- word index of top element; STACK_SIZE when empty
    fp: number,         -- word index of current frame word
    frameCount: number,

    zargs: { number },  -- preallocated, length 8, reused every instruction
    zargc: number,

    finished: number,
    instructionCount: number,

    -- Method signatures must be declared here, not just implemented, or the
    -- `:` operator will not type-check. See the note below.
    codeByte: (ZState) -> number,
    codeWord: (ZState) -> number,
    push: (ZState, number) -> (),
    pop: (ZState) -> number,
    -- ...one entry per function in the table below
}
```

### Constructor and the `:` operator

`ZState.new(memory, header)` allocates the stack buffer and the `zargs` table once, and **must attach the `ZState` metatable to the returned instance** so callers can use method syntax:

```luau
local ZState = {}
ZState.__index = ZState

function ZState.new(memory: ZMemory.ZMemory, header: ZMemory.StoryHeader): ZState
    local state = {
        memory = memory,
        header = header,
        pc = 0,
        stack = buffer.create(STACK_SIZE * 2),
        sp = STACK_SIZE,
        fp = STACK_SIZE,
        frameCount = 0,
        zargs = table.create(8, 0),
        zargc = 0,
        finished = 0,
        instructionCount = 0,
    }

    return setmetatable(state, ZState) :: any
end
```

This mirrors `ZMemory.new` exactly, including the `:: any` cast, which is needed because the type `setmetatable` infers does not match the declared `ZState` type.

Two consequences worth stating explicitly, because they are easy to get half-right:

1. **Declare methods in the exported type.** Implementing `function ZState.push(state, value)` is not enough for `state:push(v)` to type-check — the signature has to appear as a field on the `ZState` type as well. `zmemory.luau` does this for every method and the same discipline applies here.
2. **Both call forms then work.** Declaring functions as `function ZState.push(state: ZState, value: number)` with an explicit first parameter, combined with `__index`, means `state:push(v)` and `ZState.push(state, v)` are equivalent. Prefer the colon form in opcode handlers for readability; the dot form remains available where an explicit instance reads better, such as in tests.

### Required functions

| Function | Mirrors |
| --- | --- |
| `codeByte(state)` | `CODE_BYTE` — yields; advances `pc` |
| `codeWord(state)` | `CODE_WORD` — yields; advances `pc` by 2 |
| `push(state, value)` / `pop(state)` / `peek(state)` | `*--sp`, `*sp++`, `*sp` |
| `readVariable` / `peekVariable` / `writeVariable` / `storeResult` | the four variable paths above |
| `readGlobal(state, n)` / `writeGlobal(state, n, v)` | global word access |
| `call(state, routine, args, argc, ct)` | `call` |
| `ret(state, value)` | `ret` |
| `branch(state, flag)` | `branch` |
| `unpackRoutine` / `unpackString` | version-dependent unpacking |
| `catchFrame(state)` / `throwFrame(state, value, frame)` | `z_catch` / `z_throw` |
| `checkArgCount(state, n)` | `z_check_arg_count` |
| `restart(state)` | `z_restart` |
| `runtimeError(state, code)` | `_runtime_error` |

### The asynchronous contract carries forward

Every function above that touches memory inherits `ZMemory`'s rule: it may yield, so it must run inside a `CoroutineMgr` task. That includes `codeByte`, `codeWord`, `call` (it reads the routine prologue), `ret` (no — it only touches the stack), `branch` (it reads offset bytes), and any variable access that resolves to a global. Only pure stack operations are non-yielding. Document which is which in the module header so Phase 4 handlers do not assume the wrong thing.

### Nested interpretation and the `finished` counter

`finished` is an `int`, not a `bool`, and the difference is deliberate. Three events require running a story routine from interpreter code rather than from a `call` opcode: a sound effect completing, a `read` or `read_char` timeout expiring, and a V6 newline countdown reaching zero. In each case the interpreter is already mid-instruction — usually inside `z_read` — and must run a routine to completion, collect its result, and resume.

`direct_call` ([process.c:510-544](Frotz/src/common/process.c#L510-L544)) implements this through call type 2:

- `call()` ends with `if (ct == 2) interpret();`, recursively re-entering the main loop.
- `ret()` has `if (ct == 2) { *--sp = value; finished++; }`, pushing the result and bumping the counter.
- The loop is `do { ... } while (finished == 0); finished--;`, so the inner loop exits on the increment and then restores the counter for the outer loop.

Each nesting level consumes exactly one increment on its way out, which is why a counter is required. It is also why `z_quit` sets `finished = 9999` rather than 1: that unwinds every level, since each decrements by one as it returns.

**This ports directly.** The C version relies on the C call stack to hold the suspended outer interpretation; a Luau coroutine has a call stack too, so `direct_call` is an ordinary nested call to `interpret(state)`. When the inner loop yields on a page fault the entire stack — outer `z_read` frame included — suspends and resumes intact.

Three constraints follow:

1. **Do not model nesting with nested coroutines.** One coroutine with ordinary nested calls is correct and simpler. A second coroutine would violate the single-task assumption behind the memory layer's `mapi{id}` correlation.
2. **`zargs` must be saved and restored by value.** `direct_call` snapshots `zargs`/`zargc` because the nested execution clobbers them. Since `zargs` is a preallocated reused table, this must copy the eight values rather than swap table references. `direct_call` is rare, so a temporary table there is acceptable.
3. **Quit unwinds cooperatively, not immediately.** After the inner loop exits, control returns into the middle of `z_read`, which may do more work before returning. An `error()` sentinel would abort immediately instead, at the cost of skipping whatever those intermediate frames would have cleaned up. Phase 3 keeps the counter for fidelity.

The re-entry itself belongs to Phase 5; Phase 3 only needs to carry `finished` with these semantics.

## Second Life specific concerns

### Instruction budget

Frotz calls `os_tick()` once per instruction ([process.c:301](Frotz/src/common/process.c#L301)) so the host can do periodic work. The port needs the same hook for a sharper reason: an SLua script gets a bounded execution slice per event. ROM page faults yield naturally, but a hot loop running entirely in RAM and cache will never yield and can starve the script's other events or trip a runtime limit.

`CoroutineMgr` now provides the primitive, returned as the third element of the module table:

```luau
local CoroMgr, await_event, yield_frame = table.unpack(require("coromgr.luau"))
```

`yield_frame(delay)` awaits a uniquely-named event with a timeout, so the timeout itself is the resumption. The name must be unique per call — `handle_event` resumes *every* task registered for a matching name, so a shared name would let one task's timeout resume all the others early.

Phase 3 carries `instructionCount` in the state and exposes `ZState.tick(state)`, which calls `yield_frame` every N instructions.

**Choosing N.** Each yield costs about one `FRAME_DELAY` (0.1s by default), so the ceiling is roughly `N * 10` instructions per second:

| N | Approximate ceiling |
| --- | --- |
| 1,000 | 10k instructions/sec |
| 10,000 | 100k instructions/sec |
| 50,000 | 500k instructions/sec |

A heavy turn can run well into six figures of instructions, so N must be large — 10,000 or more — or turns will take tens of seconds from yield delay alone. Two factors make a high N safe: SLua preempts on its own script budget regardless, and ROM page faults already yield naturally on any story larger than the ten-page cache. The explicit yield is a safety net for RAM-resident hot loops, not the primary scheduling mechanism.

Both N and `FRAME_DELAY` need in-world measurement. Check what `LLTimers:once` actually delivers at 0.1 versus the sim frame floor; if it lands nearer a frame time, the ceiling rises proportionally.

### Allocation churn

`zargs` must be a preallocated table of eight slots, written in place and bounded by `zargc`. Allocating an operand table per instruction would be the single largest source of garbage in the interpreter and would put steady pressure on a 128 K heap. The same rule applies to any tuple-shaped return value in the hot path: prefer multiple return values or state fields over temporary tables.

### Footprint

| Item | Size |
| --- | --- |
| Stack buffer, 1024 words | 2048 bytes |
| `zargs` table, 8 slots | ~150 bytes, allocated once |
| `ZState` table, ~12 fields | small, allocated once |

`STACK_SIZE` of 1024 words matches the Frotz default and is generous for real stories; it is the obvious first knob to turn if the heap gets tight.

## Implementation order

1. `ZState.new` with the stack buffer, `zargs`, header wiring, and the `ZState` metatable attached.
2. Raw stack primitives: `push`, `pop`, `peek`, with overflow and underflow checks.
3. PC helpers: `codeByte`, `codeWord`.
4. Variable access: all four paths, plus global read/write.
5. `unpackRoutine` / `unpackString`.
6. `call` including the routine prologue and both V1-V4 and V5+ local defaults.
7. `ret` including all three call types.
8. `branch` and `storeResult`.
9. `catchFrame`, `throwFrame`, `checkArgCount`.
10. `restart`, plus the version-gated subset of `restart_header`.
11. The `storeb` flags-register hook.
12. `tick` and the instruction budget.

Steps 1-4 are independently testable before any frame logic exists, which is where most of the value of this ordering lies.

## Test plan

Phase 1's memory tests established the pattern: prove each invariant before building on it. These run inside a VM coroutine against the Adventureland story.

**Stack primitives**

1. Push and pop a single value; verify `sp` returns to its initial position.
2. Fill the stack to capacity; verify `ERR_STK_OVF` at the boundary, not one slot early or late.
3. Pop from an empty stack; verify `ERR_STK_UNDF`.

**Variables**

4. Write and read every local slot 1-15 within a frame.
5. Write and read a global; confirm the value lands at `globals + 2 * (n - 16)` in RAM by reading it back through `ZMemory` directly.
6. Variable 0 through `storeResult` pushes, and `sp` decreases by one.
7. Variable 0 through `writeVariable` replaces the top, and `sp` is unchanged.
8. Variable 0 through `readVariable` pops; through `peekVariable` does not.

**Frames**

9. Call a routine with fewer arguments than locals; verify unsupplied locals get their defaults (zero in V5+).
10. Call with more arguments than locals; verify the extras are discarded and `argc` in the frame word is correct.
11. Verify the frame word's three packed fields independently after a call.
12. Round-trip a return PC above 65535 through the 9-bit split and confirm `ret` restores it exactly. This is the case a 16-bit assumption would silently break.
13. Nest calls several deep, return through all of them, and confirm `sp`, `fp`, and `frameCount` all return to their pre-call values.
14. `ret` with call type 0 stores, with 1 discards, with 2 pushes and increments `finished`.

**Catch and throw**

15. `catchFrame` inside nested calls returns the current frame number.
16. `throwFrame` back to an outer frame restores `fp` and `frameCount` and discards the intervening frames' stack space.
17. `throwFrame` to a frame number above `frameCount` raises `ERR_BAD_FRAME`.

**Branch**

18. Short branch forward, both polarities.
19. Long branch with a negative offset; verify the 14-bit sign extension.
20. Branch offset 0 returns false and offset 1 returns true, rather than jumping.

**Startup**

21. `restart` sets the PC from `start_pc` for a non-V6 story and leaves an empty stack.
22. `restart` twice in a row produces identical state.

## Completion criteria

Phase 3 is complete when:

- `ZState.new` produces a valid state from a loaded `ZMemory` and parsed header
- all four variable paths behave per the table above, including the variable-0 distinctions
- `call` and `ret` round-trip frames exactly, including PCs above 65535
- `catch` / `throw` unwind correctly
- `branch` decodes both forms and both polarities, including the return-value special cases
- `restart` leaves the VM ready to execute its first instruction
- every test above passes inside a VM coroutine

## Decisions

The four questions this plan originally left open are now settled:

1. **Instruction budget.** `CoroutineMgr.yield_frame` is implemented and is the yield primitive. N should start high (10,000+); both it and `FRAME_DELAY` need in-world measurement. See [Instruction budget](#instruction-budget).
2. **Error policy.** `error()` with a table payload plus a top-level `pcall`, for the fatal error class only; the minor class warns and returns. See [Error strategy for the port](#error-strategy-for-the-port).
3. **Version coverage.** Full V1-V8 in the state layer, V6 included. See [Version coverage](#version-coverage).
4. **`direct_call` re-entry.** Nested ordinary function calls inside the single VM coroutine, with `finished` kept as a counter. See [Nested interpretation and the `finished` counter](#nested-interpretation-and-the-finished-counter).

### Still to measure or decide later

- The values of N and `FRAME_DELAY`, once there is something running in-world to measure.
- Whether `pcall` is yieldable in SLua — assumed yes, needs a smoke test before the error design is built on.
- Whether V6 stories eventually run with graphics or text-only. This is a screen-phase decision and does not block Phase 3.

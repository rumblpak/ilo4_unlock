# iLO 2.80 minimal read-only memory probe

Tests whether `patches/280-tools`'s still-unidentified brick cause is
specific to one of its removed capabilities, by flashing a much smaller
version of the same technique that only implements read-only memory
access.

## Background

`patches/280-tools` (the full port of `patches/277-tools`'s Airbus
Security Lab memory probe) bricked on real hardware on 2026-11-05, for a
cause that was never identified -- ruled out as "the technique is broken
in general" (strong evidence 277-tools itself is sound, see
`research/2026-11-12-documentation-audit-untested-items.md`) and ruled
out as "the literal addresses were mis-ported" (independently verified
byte-identical function prologues across all six shipped firmware
versions, 2.77-2.82). Something else about that specific 1136-byte
payload is the cause, and nobody has isolated what.

## This build

Replaces the exact same injection point (`help` command handler, file
offset `0xaed07c`, same 1136-byte slot `patches/280-tools` used) with a
hand-trimmed 208-byte variant (`asm/tools_readonly.S`) that keeps only
the `r` (read memory) command and drops:

- **`w` (write memory)**: the single riskiest primitive in the original,
  never needed to answer this question.
- **`x` (execute)**: `blx` to an arbitrary, unvalidated user-supplied
  address -- the second-riskiest primitive.
- **`a`/`f` (malloc/free)**: the *only* code paths in the original that
  call external helpers (`libc_malloc_fn`/`libc_free_fn`) whose targets
  research flagged as unverifiable -- "reference an address outside this
  firmware image's own file bounds entirely... can't be statically
  verified either way for any version"
  (`research/2026-11-05-278-282-feasibility.md`). Removing them means
  every external reference this build makes (`GrabContext_fn`,
  `printToShell_fn`) is one this session independently re-verified as a
  real function prologue in the genuine stock firmware (not just trusted
  from prior research).
- **The `sprintf` trampoline**: confirmed, via a full Ghidra instruction
  scan this session, to be dead code in the original -- never called by
  anything, so dropping it changes nothing behaviorally.

Everything kept (prologue, `GrabContext` bootstrap, the hex-digit
address-parsing loop, the single-command dispatch, the default/fallback
echo, `cmd_read`) is structurally identical to the original, just
re-assembled without the removed pieces.

Assembled fresh every build (not shipped as a prebuilt binary) with
`arm-none-eabi-as`/`objcopy` (GNU ARM toolchain, not keystone --
keystone-engine's Python bindings failed to load on this machine and
failed to build from source in a Linux container; the GNU toolchain
produces equivalent machine code). Every instruction, branch target, and
literal in the assembled 208-byte blob was independently verified once,
by hand, by disassembling the output and confirming every branch/`ADR`
computation lands exactly on its intended label -- not just trusted from
the assembler.

The remaining 928 bytes of the 1136-byte slot are left as the genuine,
untouched original "help" handler content (not zero-padded), matching
the minimal-footprint discipline of every diagnostic in this project.

This patch makes **no** change to VirtRange, `.secinfo`, or any
task-local address-space structure. It overwrites the content of an
already-present, already-executable, already-correctly-permissioned
module -- the same technique as `patches/277-tools`, entirely unrelated
to the now-closed VirtRange re-attribution investigation.

## How to read the result

- **If this bricks with 270**: the brick is not specific to write,
  execute, or the malloc/free references -- something about the core
  read-primitive, the bootstrap mechanism, or the injection point itself
  is the actual cause, and the mystery deepens rather than resolves.
- **If this boots fine**: the brick cause is isolated to one of the
  removed capabilities (most likely write or execute, given they're the
  only primitives capable of directly corrupting memory or jumping
  somewhere unintended). This would also be the project's first live
  memory-read capability on 2.80+, enabling direct verification of
  claims this session has so far only established statically (e.g. live
  inspection of entry 2's contents, confirming or refining the
  bootstrap-pointer finding with real runtime data instead of static
  inference).

## How to verify the result on hardware

See `patches/280-diag9-rights-flip-existing-entry/readme.md`'s checklist
(POST, iLO version readback, network ping, SSH shell, web UI -- a missing
POST error alone isn't sufficient). If all five pass, also try the probe
itself over SSH: `help r<hex-address>` should echo back readable memory
without a shell crash, confirming the read path actually works end to
end, not just that the firmware boots with the patch present.

## Result -- boots clean, but the `help` command hangs its invoking shell (2026-11-12)

Flashed on real hardware. **The full boot-stability checklist passed**:
no POST error 270, iLO's version string read back correctly, ping
responded, a fresh SSH session connected and gave a real shell prompt,
and the web UI loaded over HTTPS. This is the first build in the whole
`fan`/`tools` investigation (spanning `patches/280-tools`,
`patches/280-fan-restore` v1-v4, and `patches/280-diag1-9`) confirmed to
boot and remain network-reachable while carrying a content change to
`ConAppCLI`'s own "help" command slot.

However, invoking the probe itself hangs the SSH session it's run from,
with **zero output** and no response to Ctrl-C, in two separate tests:

- `help r00000000` (intended target: address `0`) -- hung, no output.
- `help rAAABAAAA` (intended target: task-local `0x10000`, the literal
  start of `.ConAppCLI.elf.text` -- independently confirmed to be real,
  mapped, executable code via disassembly, not a guess) -- hung
  identically, no output.
- `help` alone, with **no** address argument at all -- **also hung
  identically**, zero output. This is the decisive result: it rules out
  `cmd_read` and address validity entirely as the cause, since this path
  never reaches `cmd_read` at all -- it only exercises the shared
  bootstrap (`GrabContext` + the default/fallback `printToShell` echo).

Critically, in every case, everything *other* than that one SSH session
stayed fully responsive -- ping, HTTPS, and a brand-new SSH session all
continued working normally. This is a session/task-local hang, not
another total-RTOS-failure brick like the 270 errors seen throughout
this project; no power cycle was needed to continue testing (though the
hung session itself never recovered and had to be abandoned).

### Root cause, found via static analysis (not live-debugged, see caveat below)

The hang is not caused by anything this patch trimmed or changed. Every
instruction in the kept code path (prologue, address-parsing loop,
dispatch, `cmd_read`, and the exact `GrabContext_fn`/`printToShell_fn`
addresses) was diff-checked instruction-for-instruction against
`patches/277-tools/asm/tools.S` and found **byte-for-byte identical**.
The genuine, un-patched "help" handler content itself (`patch_userland.
json`'s own recorded `prev_data`) is also byte-for-byte identical between
2.77 and 2.80 for the full 1136-byte slot. `GrabContext_fn`'s and
`printToShell_fn`'s own code (not just their addresses) were
independently re-extracted and disassembled from a fresh, genuine 2.77
`elf.bin` at the same task-local offsets and found to match 2.80's bytes
exactly, despite `.ConAppCLI.elf.text`'s absolute placement shifting
between the two versions (`sh_addr` 0x2169000 in 2.77 vs 0x2162000 in
2.80) -- confirming the task-local addressing convention this project
uses is being applied correctly, and that this isn't a stale/wrong
hardcoded address left over from 2.77.

Disassembling `GrabContext_fn`'s full body (not just its prologue)
reveals why: it performs a runtime lookup, not a fixed computation. It
calls an internal helper that searches a 6-entry table for one matching
the original caller-supplied `R0` value (the identity argument passed
into whatever CLI handler invoked it). If a match is found, it computes
and returns a pointer into that entry's context structure. **If no match
is found, it returns `0` (NULL)** -- via `movcs r0, #0` on the
"not-found" branch, with no error signaled to the caller.

That 6-entry table lives at true vaddr `0xc3d08` (stride `0x1da4` bytes
per entry, both values read directly from `GrabContext_fn`'s own literal
pool), inside **`MemRegion7`** -- a 512KB, zero-initialized (`SHT_NOBITS`)
section, i.e. a globally-shared runtime region with no static file
content at all. Its real contents are written at boot by whichever up to
6 tasks register themselves into it (via a further internal call,
`bl 0x21d234c` in the lookup-miss path, not yet traced) -- this is
runtime registration state, not anything visible in the firmware image's
static bytes.

`tools.S` (both the original and this trimmed build) saves
`GrabContext`'s return value straight into `R5` with **no validation**,
then uses it unconditionally everywhere downstream: `R5+0x264` (the
command-string buffer), `R5+0x364` (the read-size byte in `cmd_read`),
and as the context-pointer argument to every `printToShell` call,
including the plain no-argument fallback echo. If `R5` comes back `0`,
every one of those becomes a read from near-NULL memory (literal
addresses `0x264`/`0x364`), which is almost certainly unmapped in this
task's own Address Space -- consistent with an unhandled fault that
leaves the task (and its SSH session) stuck rather than crashing it
outright, matching the observed silent, Ctrl-C-proof hang exactly.

**This means the hang is very likely a registration/identity mismatch at
the moment "help" is invoked via SSH/SM-CLP on this exact firmware and
session, not a defect in this patch's code.** The same lookup-and-trust
pattern is original to `patches/277-tools`'s own design and has a working
track record there -- either 2.77's "help" was invoked by a caller
context that *is* one of the 6 registered entries, or something about
2.80's actual runtime task/registration layout differs from 2.77's in a
way this project hasn't characterized.

### What this does NOT prove

- The internal registration mechanism (`bl 0x21d234c`, the lookup-miss
  path) was not traced. Finding and characterizing all 6 real
  registration call sites across the full firmware, to determine why
  this specific invocation context isn't among them, would be a
  substantially larger undertaking (likely many hours) with no guarantee
  of a fixable outcome even if completed -- this is runtime boot-order
  state, not something a byte patch to this handler alone could change.
- This was not live-debugged. The fault/hang mechanism (what actually
  happens when the task dereferences near-NULL memory) is inferred from
  the lookup-miss code path and the observed symptom, not traced via a
  live debugger or vendor documentation.
- This does not bear on whether the *read* primitive itself would work
  correctly if `GrabContext` ever did return a valid, non-NULL context --
  that remains untested.

## What was verified (static)

- Genuine "help" handler content at the injection offset reconfirmed,
  byte-for-byte, against the recorded original before patching.
- Both external function addresses (`GrabContext_fn`, `printToShell_fn`)
  independently disassembled from the genuine stock firmware and
  confirmed to be real ARM function prologues (`mov ip,sp; push {...};
  sub fp,ip,#N`), not just trusted from prior research.
- Every branch target and `ADR` computation in the assembled 208-byte
  blob manually verified against its intended label.
- Full compression round-trip: decompressed ELF and kernel match the
  patched inputs byte-for-byte; bootloader region matches exactly.
- Built via the deterministic `tools/package_build.sh` pipeline.

## Build

Not committed as a binary artifact (proprietary HP firmware bytes). Only
`asm/tools_readonly.S` (this session's own assembly source) is committed
-- the build script assembles it fresh every run and derives the genuine
original "help" handler content it replaces from
`patches/280-tools/patch_userland.json`'s own already-committed
`prev_data` field, so no proprietary firmware bytes are stored anywhere
in this patch's own directory.

This build's result hash (`firmware.bin.backdoored.toflash`), this run:
`cade45d436bda777c6d85b79b0470462b93f7159` (SHA1) -- confirmed identical
before and after the build script was refactored to assemble on the fly
instead of reading a prebuilt binary.

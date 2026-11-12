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

# iLO 2.80 Patch (signature-bypass + full `fan` command backport, v2) -- EXPERIMENTAL, NOT HARDWARE-TESTED

**Status: static build verified only. Has NOT been flashed to real hardware.**

This supersedes `patches/280-fan-restore` (v1), which **bricked real hardware**
("iLO FW Communication Issue" / unresponsive iLO -- the same failure mode as
`patches/280-tools`). See "Why v1 failed" below before considering this safe
to flash either.

Like v1, this backports the actual `fan` CLI handler (8-function dependency
closure, 15,548 bytes) from 2.77 into 2.80 and re-enables the disabled CLI
registration call site. What's different in v2 is **where the restored code
lives**.

## Why v1 failed

v1 placed the relocated code at true vaddr `0xe94000`, reasoning that it was
"free" because it sat past `.health.elf.data`'s declared on-disk content but
still inside that module's `VirtRange` reservation (`0x91000` bytes
reserved, only `0x2e8c` bytes initialized from file). That reasoning was
wrong: the reserved-but-uninitialized remainder of a module's `VirtRange` is
standard ELF-style BSS -- zero-filled at boot, then actively used by the
task's own running code for real global state, not idle scratch space. An
adversarial review after the hardware failure found literal-pool references
from *unrelated*, surviving Health code pointing into that same reserved
region (a suspicious table of 9 addresses spaced exactly `0x10000` apart,
well within `.health.elf.data`'s reservation) -- strong evidence the "free"
space was live. Growing `.health.elf.data`'s on-disk size to cover v1's
injection point almost certainly stomped on real BSS used by other,
unrelated Health subsystems at boot, before `fan` was ever invoked --
consistent with the observed failure (total iLO unresponsiveness, not a
narrow "fan command doesn't work" symptom).

## What v2 does differently

v2 never reuses address space already claimed by any existing module.
Instead it adds a **brand new, independent ELF section** (`sh_addr =
0x4000000`, chosen because the highest true-vaddr used by *anything* in the
firmware, per an exhaustive scan of all 577 `.secinfo` entries, is
`0x3e22b18` -- comfortably below it) containing three things back-to-back:

1. The relocated `fan` handler code+data (same 8-function closure as v1,
   re-relocated for its new address).
2. A new `.secinfo` `SectionInfo` entry describing that code (appended to
   the existing linked list by patching the previous tail entry's
   `next_ptr` -- a single in-place 4-byte edit, no resizing of `.secinfo`
   itself).
3. A new, 64-entry copy of Health's `VirtRange` array (the existing 63
   entries, unchanged, plus one new entry mapping Health task-local address
   `0x2001000` to the new section via the new `.secinfo` entry's index).
   Health's `TaskInfo.virt_space`/`virt_space_size` fields (within
   `.boottable`) are repointed to this new array -- again a small in-place
   edit, not a resize of `.boottable`.

Because nothing existing is resized or shifted in *address* space (only the
section header *table* moves, via the usual append-at-file-end trick), this
cannot collide with any other module's declared or reserved memory the way
v1 did.

### A second constraint this surfaced: branch range

The CLI registration trampoline's `bl` to the restored handler is a plain
ARM `B`/`BL`-style PC-relative branch, limited to +/-32MB. The first v2
attempt chose Health task-local address `0x3000000` for the relocated code,
which was ~48MB from the trampoline (task-local ~`0x2604c`) -- unreachable.
Health's own task-local address usage currently tops out at `0x2000000`, so
`0x2001000` was chosen instead (just above existing usage, ~2.4MB from the
trampoline, comfortably in range). All 100 branch instructions inside the
relocated closure, plus the trampoline's own call, were explicitly checked
to fall within the signed 24-bit (word-granularity) immediate range before
this was considered done -- `encode_branch` does **not** itself raise on
overflow, it silently wraps, so this check matters and must be re-run if
the placement ever changes.

## What was verified (static only) -- same caveats as v1

- Independent pyelftools re-parse: 629 sections enumerate correctly, the
  new section's content matches `fan_block.bin` byte-for-byte, the new
  `.secinfo` entry and `VirtRange` array read back with the expected
  values, `.boottable`'s `TaskInfo` for Health correctly points at the new
  array.
- All 100 branch instructions in the relocated closure, plus the
  trampoline's own re-pointed call, verified in-range for ARM's +/-32MB
  `B`/`BL` reach.
- `ilo4_repack.py` completes without error, producing a correctly-sized
  16,777,216-byte flashable image.

**None of this proves runtime correctness.** The address-collision class of
bug that broke v1 is specifically addressed, but this does not rule out
other classes of bug (a subtle literal/branch fixup error elsewhere in the
closure, the open structural question of whether any other code reads
Health's `TaskInfo`/`.secinfo` metadata in a way sensitive to array growth
from 63 to 64 entries, etc.), and it does not change the standing,
separately-acknowledged risk around HPESBHF04134 (see `patches/280-fan-restore/readme.md`).

## Build

`build_patched_280.py` in this directory is self-contained: given a freshly
extracted 2.80 `elf.bin` (via `ilo4_extract.py`), it applies the sig-bypass
patch and the full v2 fan-restore patch, and writes the result for feeding
into `ilo4_repack.py`. `fan_block.bin` is the final 15,548-byte relocated
code+data blob. See `elf_patch_summary.md` for exact offsets, for anyone
re-deriving this without re-running the script.

Result sha1 (`ilo4_280.bin.backdoored.toflash` after repack):
`a3bee3cf3f35dcd9617484b326239b178dd0ebf7`

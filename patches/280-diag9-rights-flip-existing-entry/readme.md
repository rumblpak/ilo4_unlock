# iLO 2.80 Diagnostic Build #9: flip rights on an already-present entry -- NOT A REAL PATCH

**Follow-up to the now-closed VirtRange re-attribution series (diag1-8,
see `research/2026-11-12-virtrange-reattribution-closed.md`) and the
entry-2 dead-space investigation (now confirmed live in all 6 shipped
firmware versions, see
`research/2026-11-12-entry2-literal-table-re-examined.md`).**

## Why this build

Every prior diagnostic changed a VirtRange entry's `present` field (dw1)
from 0 to 1. All six bricked, converging on: converting *any* anonymous
entry to present=1 is fatal, regardless of mechanism, mod_id newness,
array relocation, or position in the table. The leading explanation is
that INTEGRITY RTOS Address Spaces are fixed at build time -- an
anonymous entry's descriptor has no real MMU page-table backing, so
flipping `present` makes the kernel try to use a mapping that was never
built.

That explanation is specifically about *presence*. It says nothing about
whether an **already-present** entry's permission bits (`rights`: 5 =
executable, 7 = data) are also fixed at build time, or whether those are
free to change on a region the kernel already has real MMU backing for.
This build isolates that question directly.

## This build

Finds the first (lowest-index) VirtRange entry that is already
`present=1`, rights=7 (data), with `rsize=0x1000` -- entry 14
(`rbase=0x1788000`, `mod_id=0x83`) in this firmware -- and flips **only**
its `rights` field from 7 to 5, in place. Nothing else changes anywhere
in the file:

- `present`, `rbase`, `rsize`, `mod_id`: unchanged.
- The entry's actual content bytes: untouched.
- `.secinfo`: untouched, no new entry.
- `TaskInfo.virt_space`/`virt_space_size`: untouched, array doesn't move,
  count stays 63.
- Callsite: untouched, same content-blind structural test as every prior
  diagnostic.

This is the single most narrowly-isolated variable tested in this series
-- one bit, in one field, on an entry the kernel already has to set up
correctly regardless of this patch.

## How to read the result

- **If this bricks with 270**: permission bits are *also* fixed at build
  time for an already-present entry, not just presence itself. The
  INTEGRITY Address Space model enforces the entire `MEM_RANGE`
  descriptor (presence AND permission) as immutable once built. This
  closes off "reuse an existing module's slot with different
  permissions" as a mechanism too, on top of the already-closed "create a
  new present link" and "existing module space is free" findings.
- **If this boots fine**: presence is the only build-time-fixed property;
  permission bits on an already-mapped region can change freely. This
  doesn't by itself reopen a placement option -- no present=1 module has
  been shown to have free space large enough for the 49,952-byte `fan`
  closure (entry 2, the only one big enough, is confirmed live in all 6
  shipped versions) -- but it meaningfully narrows what "Address Space
  fixed at build time" means at the kernel level, which matters for
  interpreting any future finding (e.g. the still-unidentified
  `patches/280-tools` brick cause).

## What was verified (static)

- Entry 14 reconfirmed fresh (not hardcoded) as present=1, rights=7,
  rsize=0x1000, matching the intended selection criteria, before
  patching.
- Full compression round-trip: decompressed ELF and kernel match the
  patched inputs byte-for-byte; bootloader region matches exactly.
- Built via the deterministic `tools/package_build.sh` pipeline.

## Build

Not committed as a binary artifact (proprietary HP firmware bytes).

This build's result hash (`firmware.bin.backdoored.toflash`), this run:
`fb4a3f48c326ccc5f908cc1ae0e07c8daf449938` (SHA1).

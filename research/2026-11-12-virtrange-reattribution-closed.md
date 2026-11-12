# 2026-11-12: VirtRange re-attribution is closed -- 6/6 hardware-confirmed failures

## Verdict

**Converting any anonymous (`present=0`) `VirtRange` entry in Health's
`.boottable` to `present=1` is fatal, unconditionally.** Six diagnostic
builds hardware-tested this across every structurally distinct variable
this project could isolate, with zero survivors. This closes out "register
a new or existing module via VirtRange re-attribution" as a restoration
mechanism for `fan` entirely -- not one variant of it, the whole technique.

## Cumulative results

| Build | New `present=1` link? | New `mod_id`? | Array relocated? | Entry position | Result |
|---|---|---|---|---|---|
| diag2 (`.secinfo` growth, unreferenced) | no | n/a | no | n/a | booted fine |
| diag3 (in-place `rsize` shrink, stays anonymous) | no | n/a | no | n/a | booted fine |
| diag1 (new 64th entry + array relocation, new module) | yes | yes | yes | new entry, past ceiling | **bricked** |
| diag4 (relocate `virt_space` only, address `0x4000000`) | n/a (no new module) | n/a | yes | n/a | **bricked** |
| diag5 (relocate `virt_space` only, tight address) | n/a (no new module) | n/a | yes | n/a | **bricked** |
| diag6 (reuse entry 62 in place, new module) | yes | yes | no | ceiling (entry 62) | **bricked** |
| diag7 (reuse entry 62 in place, alias existing module) | yes | no | no | ceiling (entry 62) | **bricked** |
| diag8 (reuse entry 11 in place, alias existing module) | yes | no | no | mid-table (entry 11) | **bricked** |

Every variable that could plausibly have been the real culprit was tested
in isolation and shown **not** to matter:

- **Registration mechanism**: new array entry + relocation (diag1) vs.
  in-place slot reuse with no relocation at all (diag6/7/8) -- both fail
  identically.
- **`mod_id` newness**: a brand-new `mod_id` backed by a freshly-appended
  `.secinfo` entry (diag1, diag6) vs. aliasing an existing, already-valid,
  completely unmodified module (diag7, diag8) -- both fail identically.
  This rules out a per-module content hash/checksum as the mechanism:
  diag7/8 touch zero bytes of the aliased module's actual content.
- **Array relocation address**: `0x4000000` (diag4) vs. a tight,
  purpose-computed address (diag5) -- both fail identically, ruling out
  the `FUN_2000b16c` image-end fit-check as the (sole) explanation.
- **Entry position**: the ceiling-ending entry, entry 62 (diag6, diag7)
  vs. a mid-table entry 8.5 MiB below the ceiling, entry 11 (diag8) --
  both fail identically, ruling out "the kernel treats the last/ceiling
  entry specially" as the explanation.
- **Content**: diag7/diag8 patch zero content bytes (pure structural
  alias); diag6/diag1 do add inert zeroed content. No difference in
  outcome.

The only thing every bricked build shares, and the only thing every clean
build (diag2, diag3) avoids, is: **a VirtRange entry's `present` field
flips from 0 to 1.** That is now the full extent of what's provable by
black-box hardware testing from this side.

## Why, probably (not confirmed -- would need a live debugger or vendor docs)

Per `research/2026-11-06-kernel-re-methodology-and-pitfalls.md`, this
firmware runs Green Hills INTEGRITY RTOS, whose Address Space model is
documented (independently, by Perigaud/Gazet/Czarny's 2018 REcon research
on this exact product) to be **fixed at system-integration/build time, not
dynamically extensible**, with `AddressSpaceLimitExceeded` as a real, named
OS error. The leading explanation, consistent with every result above: an
anonymous (`present=0`) `VirtRange`/`MEM_RANGE` entry is not simply "a
memory range nobody's using yet that you can claim" -- it's a *descriptor*
for a region whose actual MMU page-table backing (or lack of it) was
decided by the System Builder tool when the image was integrated, outside
anything this project can edit by patching the shipped binary. Flipping
`present` to 1 in the descriptor doesn't grant the underlying hardware
mapping; it just makes the kernel's own task-setup code try to use a
mapping that was never built, which fails immediately and totally,
independent of which entry, which module, or how the registration is
wired -- exactly the uniform, total-boot-failure signature observed six
times in a row.

This is "very likely," not proven: nothing here caught the exact
instruction/trap that fires, and that would need either a live debugger
on real hardware or vendor documentation this project doesn't have access
to.

## What this doesn't rule out

- **Runtime safety was never actually tested.** No diagnostic in this
  series ever wired a callsite to branch into the registered region --
  every one was a content-blind structural test. If a mechanism had
  survived boot, it still wouldn't have proven safety under sustained
  operation.
- **An integrity-check gap was separately audited and ruled out** (see
  `research/2026-11-12-integrity-check-audit.md`) -- the bricks are not
  explained by a missed checksum/signature check.
- This doesn't bear on non-VirtRange approaches (e.g. a task that already
  has spare, *present* capacity in its own declared module, or a
  completely different restoration path like direct I2C/GPIO access,
  which `research/2026-11-05-278-282-feasibility.md` already flagged as
  unexplored).

## Recommendation

Per this project's own systematic-debugging discipline (3+ failures of the
same hypothesis class means question the architecture, not the next
variant of it) -- already raised once after diag6, continued per explicit
user direction, and now at 6 consecutive, maximally-diversified failures --
**VirtRange re-attribution should be considered closed.** Continuing to
test further variants of "flip an anonymous entry to present" is very
unlikely to produce a different result; every axis of variation available
within this technique has now been exhausted. The live, unresolved paths
forward are the ones `research/2026-11-05-278-282-feasibility.md` already
named: direct I2C/GPIO hardware-level fan control research, or accepting
that fine-grained PWM control is not achievable through this software layer
on 2.80+.

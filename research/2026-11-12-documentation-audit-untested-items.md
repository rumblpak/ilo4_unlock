# 2026-11-12: Audit of previously-documented, never-tested items

Prompted after the `var_array` investigation showed this project has, more
than once, documented a structural detail or a recommended next step
without ever actually following up on it. Re-read every file in
`research/*.md` (14 files) and every `patches/*/readme.md` (25 files) in
full, specifically looking for claims/leads flagged as untested,
unverified, assumed, or "not yet done" that were never subsequently
revisited.

## Actionable: still worth doing

1. **`patches/277-tools` has never been hardware-tested, and this
   project's own research already recommended testing it before touching
   280/281/282-tools again.** From
   `research/2026-11-05-278-282-feasibility.md`: *"there is no documented
   hardware-test confirmation of `patches/277-tools` anywhere in this
   repo... Test `patches/277-tools` on this same DL380 Gen9 with genuine
   2.77 firmware before touching 280/281/282-tools again."* This is the
   single cleanest, lowest-new-risk step toward resolving the still-open
   `patches/280-tools` brick (separate from, and never explained by, the
   now-closed VirtRange investigation): if 277-tools *also* bricks genuine
   2.77, the "overwrite `help`" technique is unsound in general, version-
   independent. If it works, the defect is specific to the 2.80+ port and
   worth chasing further. Nobody ran this test. It uses firmware this
   project already has and a technique already built -- no new patch
   development needed.

2. **Existing, stock, read-only telemetry surfaces were never checked for
   live memory exposure**, independent of the broken `280-tools` memory
   probe. From `research/2026-11-06-v3-fan-restore-strategy.md`: *"any
   existing, stock, read-only iLO diagnostic surface that happens to
   expose memory contents (AHS log export, a SMASH-CLP target not yet
   explored, a RedFish diagnostics endpoint) would be worth checking
   before writing this option off. Not yet investigated this session."*
   This is zero-flash-risk (works against the already-confirmed-working
   plain `patches/280` image) and could directly validate or refute the
   "INTEGRITY Address Space is fixed at build time" explanation this
   project is currently relying on for why VirtRange re-attribution
   bricks -- instead of inferring it from boot-failure patterns alone.

3. **Whether `/system1` or an aggregate thermal target supports `set` for
   finer-grained fan control via Redfish/CLP was never tried.** From the
   same feasibility doc: *"Doesn't rule out `set` working on a different
   target... untested, and not attempted without deliberate decision given
   it'd be a write operation on live hardware."* This is a completely
   different path to the user's actual goal (quieter/more controllable
   fans) that doesn't touch firmware at all -- it was set aside out of
   caution about a live write, not because it was ruled out.

4. **`tools.S`'s `sprintf_fn`/`libc_malloc_fn`/`libc_free_fn` reference an
   address outside the firmware image and were never verified for any
   version**, including 2.80 -- explicitly flagged as un-verifiable
   statically and never investigated via another method (live debugger,
   alternate static technique). A real, acknowledged, never-chased
   candidate explanation for `280-tools`'s still-unidentified brick cause.

5. **2.81 and 2.82's plain signature-bypass-only builds were never
   separately hardware-tested** -- only 2.80 was confirmed working. Low
   urgency unless the target hardware is actually running 2.81/2.82.

## Lower-priority / likely moot given the VirtRange closure

- 87 "other-module" literal-pointer candidates from the v3/v4
  closure-relocation work were assumed benign for data-word references but
  never specifically re-verified that way (`2026-11-06-v3-literal-pointer-relocation-gap.md`).
- v4's two residual unproven assumptions (the `0xe915e8` fallback believed
  but not proven unreachable; the deleted fan-name string table not
  exhaustively ruled out as reachable some other way) --
  `patches/280-fan-restore-v4/readme.md`.
- 9 externally-referenced removed functions from the "106 removed
  functions" count were never individually traced for exact purpose
  (`2026-11-05-278-282-feasibility.md`).

All three of the above only matter if a safe module-registration mechanism
is found later; with VirtRange re-attribution closed
(`2026-11-12-virtrange-reattribution-closed.md`), none of this content has
anywhere to be placed right now.

## Historical, already closed out

- Early 2.77-only CLI wishlist items and internal `ConnectionRecord`/`r7`
  register speculation (`2022-02-17-docs.md`, `2022-02-19-onto-277.md`) --
  no bearing on 2.80+ or the fan/integrity investigations.
- `patches/250`'s "isn't intended for use, nor has it been tested" --
  intentionally untested scaffold, by design.
- The Health service-ID 5/6/7/8 dispatch table was "never reliably
  located" -- superseded by the later direct hardware test confirming the
  fan service is simply dead on 2.80 regardless of dispatch-table detail.
- `patches/280-fan-restore` v1/v2/v3's in-file "not yet done" framing is
  stale; each was superseded by the next version after its own hardware
  brick.

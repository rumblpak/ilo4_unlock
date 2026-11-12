# 2026-11-12: Re-examining the v1 postmortem's "9-hit" evidence for live BSS

Prompted by a request to find genuinely dead space in Health's existing
(present=1) modules for the already-fully-characterized `fan` closure, now
that VirtRange re-attribution is closed. Entry 2 (`.health.elf.data`,
rbase `0xb4000`, rsize `0x91000`, real content only `0x2e8c`) is the only
present=1 entry large enough to conceivably hold the 49,952-byte closure in
its reserved-but-unused tail -- but this is the exact region
`research/2026-11-06-fan-restore-v2-postmortem.md` already identified as
unsafe, via "9 hits... evenly spaced by exactly `0x10000`... a real table
of base addresses to distinct structures used by code that has nothing to
do with `fan`."

## Re-verifying the finding, properly scoped

A literal-word scan restricted to Health's own `.text`+`.data` (the only
scope where a task-local address reference is architecturally meaningful --
an earlier, wrongly-scoped whole-firmware scan produced ~180 false
positives from unrelated tasks) reproduces the original finding exactly:
9 values, `0xea0900` through `0xf20900`, each spaced `0x10000` apart,
present as raw bytes in the stock firmware. This part of the original
finding is solid and reproducible.

## What's new: checking whether anything actually *loads* these values as code

The original postmortem's conclusion ("actively-referenced... by code")
was never independently confirmed by decompiling a consumer -- it was
inferred from the byte pattern itself. Checked properly this time:

1. **Ghidra's `getReferencesTo()`** on the file offsets where each literal
   word sits: zero references. (This specific check is known-unreliable
   for this purpose -- see below -- but is the first sign something's off.)
2. **Disassembling the bytes immediately around each literal word**
   (Capstone): decodes as nonsense (`sbcseq r0, r0, r0, lsl #18` and
   similar) -- the classic signature of disassembling non-code data, not
   a real literal pool sitting next to its loader.
3. **A full linear Capstone sweep of Health's entire `.text`**: stalls
   after only 231 instructions (924 bytes) -- confirms `.text` has data
   interleaved with code that breaks naive linear disassembly almost
   immediately, consistent with #2.
4. **A proper, function-aware scan via Ghidra's own instruction iterator**
   (which correctly separates code from data, unlike #3): covers all
   **118,287** real instructions in Health's `.text`. Checked every
   instruction's scalar operands against all 9 target values, covering
   both `LDR [pc,#imm]` literal-pool loads and `MOVW`/`MOVT` immediate
   pairs (the two standard ARM ways to materialize a 32-bit constant).
   **Zero matches, of either kind.**

## What this means

No instruction anywhere in Health's properly-disassembled code loads any
of these 9 values as an immediate operand, by any standard ARM
constant-loading mechanism. This directly contradicts the postmortem's
"actively-referenced... by code" characterization, which was never itself
backed by a decompiled consumer -- only by the byte pattern's existence.
This looks like the same class of mistake this project has made twice
before (`FUN_20031d24`'s SHA-256 false positive in
`2026-11-06-kernel-re-methodology-and-pitfalls.md`; the `dvcrcv` false
lead in `2026-11-12-integrity-check-audit.md`): a needle match on
values that look meaningful, taken as evidence without verifying a real
consumer exists.

**What this does NOT prove:** a value computed via register arithmetic
(e.g. a base address loaded via one mechanism, combined with a
runtime-computed offset) rather than materialized as a single immediate
operand would not appear in this scan. The region is not proven dead --
only the specific piece of evidence previously used to call it live has
failed to replicate under direct verification.

## Where this leaves entry 2

Still unresolved, not reopened. Before placing anything here, the
honest next steps are:
1. Check for non-immediate access patterns (e.g. a base register loaded
   from some other location and indexed at runtime) -- this would need
   broader dataflow analysis, not just an operand scan.
2. Independently determine whether this specific byte range is genuinely
   padding/BSS at all versus some other kind of embedded data (its own
   non-code disassembly signature suggests it may not be ordinary BSS).
3. Only after both of those come back clean would this be a credible
   placement candidate -- and even then, only for content that's been
   through the same rigorous verification v4's fan-closure content
   already received.

This finding doesn't change the VirtRange closure
(`2026-11-12-virtrange-reattribution-closed.md`), which rests on
independent, direct hardware evidence (6/6 bricks) unrelated to this
specific region.

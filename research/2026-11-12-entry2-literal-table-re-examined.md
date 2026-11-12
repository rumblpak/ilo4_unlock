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

## Checking for register-computed (base + offset) access

The remaining gap in the scan above: a value *computed* at runtime (base
register + offset) rather than loaded as a single immediate wouldn't show
up in an operand-scalar match. Checked directly: searched all of Health's
`.text` for any instruction loading entry 2's own module base address
(`0xe91000` true-vaddr / `0xb4000` task-local) as an immediate -- the
precondition for a later `base + offset` computation to reach into the
tail at all.

**Zero instructions load the base address either.** This is itself
informative: it means this compiler does not use a shared
base-register-plus-offset pattern for accessing this module's globals at
all -- each global variable access apparently gets its own, individually
hardcoded absolute-address literal (the normal pattern for non-PIC ARM
code with simple scalar globals). Since that's the only addressing
convention in use, the exhaustive 118,287-instruction immediate-operand
scan already covers the one mechanism this codebase actually uses to
reach any address in this module, including the tail. There is no
register-computed access pattern left unchecked for *this specific
addressing convention*.

**What would still slip past this:** runtime-computed array/loop indexing
from a *different* base that happens to resolve into this range at
runtime (not detectable by static operand matching at all, would need
real value-set/symbolic analysis across loop bodies), or access by
something other than the ARM CPU entirely -- e.g. if these 9 values are
actually a hardware DMA scatter-gather descriptor table (a plausible
explanation for 9 evenly-spaced 64KB-granular addresses in BMC firmware),
they'd be read by a DMA engine, never by a CPU instruction, which would
equally explain zero CPU-side references and would be **more** dangerous
to overwrite than ordinary dead data, not less -- corrupting a live DMA
target can cause silent, delayed memory corruption elsewhere rather than
an immediate, obvious crash.

## Checking for a DMA descriptor consumer

Searched Health's `.text`+`.data` for DMA/scatter-gather terminology.
Found one real hit -- `"QueueNum: %x\nSGListCnt %x\nSGTotalLo: %x\nCmdAddr: %x"`,
genuine CISS (HP Smart Array) scatter-gather debug-dump terminology -- but
it's a format string for printing *external PCI storage controller*
command structures (attached RAID cards), at true-vaddr `0xe21b88`, with
no connection to entry 2's region or to the 9 values. Dead end.

Also clarified something important while tracing this: the 9 values
themselves are **not stored inside the free/tail region at all**. Their
storage locations (`0xe8f9cc`-`0xe9010c`) sit inside entry 1's
(`.health.elf.text`) own real, compiled content -- which ends at
`0xe907a8`, comfortably above all 9 -- not in its slack. They are
genuine compiler-emitted data, not junk or padding themselves; the open
question was only ever whether they're *used as addresses* pointing into
entry 2, and no mechanism found so far (immediate load, base+offset,
DMA) shows that they are.

## Verifying with Ghidra

Cross-checked the findings above against Ghidra directly rather than
relying only on the raw-byte/Capstone scripting used so far:

- **The `SGListCnt` string, confirmed and traced to its actual consumer.**
  Ghidra defines the real string (starting a bit earlier than the
  substring search found, at true-vaddr `0xe21b50`) with exactly one
  reference, from `0xe219f8`. Disassembling that site: `add r0, pc, #84`
  (computing the string's address) immediately followed by `bl` to a
  separate function -- a textbook `printf`-style call, with the
  preceding ~10 instructions loading byte/halfword/word fields (offsets
  `0x18`-`0x26`) from a structure pointer in `r5` to pass as the `%x`
  arguments. This is a legitimate, unrelated debug dump of a storage
  command structure's fields -- fully confirmed, not just inferred from
  the string's content.
- **The scalar-operand scan, extended from Health's `.text` alone
  (118,287 instructions) to the entire firmware.** Re-ran it across
  every disassembled instruction in the whole 24MB image -- all
  **3,497,124** of them, every task, not just Health. Zero matches for
  any of the 9 target values, anywhere.
- **No function anywhere in the firmware has "dma" in its name** (a weak
  check on its own, since this is a stripped binary where most functions
  are auto-named `FUN_xxxxxxxx`, but consistent with everything else).

## Checking for runtime-computed (loop/array-index) access

A loop indexing into entry 2 from a static base wouldn't necessarily load
one of the 9 exact tail addresses -- it would load some *other* literal
base address anywhere in entry 2's full range (`0xe91000`-`0xf22000`,
module start to module end, not just the tail), then index into it at
runtime. Checked for that directly: scanned all of Health's `.text`+`.data`
for any literal word landing anywhere in that full range.

**Found exactly the same 9 values, nowhere else.** There is no other
literal base address, anywhere in Health's compiled code or data, that
points into any part of entry 2's module -- only the 9 already-known,
already-unreferenced constants. This means there's no second candidate
base for a static-base/runtime-index loop to even start from.

**What this does and doesn't settle:** it rules out the common case (a
loop or array access from a literal-constant base baked into the code).
It does **not** rule out a base computed via register arithmetic from
some other starting point entirely (e.g. Health's own `.text` base plus a
large, non-literal offset derived from a parameter, return value, or
further indirection) -- that would require genuine value-set/symbolic
execution tracing every register through every loop in Health's 1,214
functions, which is beyond what static operand/literal scanning can
settle with certainty. This is also the point where this project's
earlier-identified blocker applies: there's no live telemetry access to
directly observe what memory is actually touched at runtime
(`research/2026-11-06-v3-fan-restore-strategy.md`), so a fully conclusive
answer isn't achievable through static analysis alone.

## Where this leaves entry 2

Still unresolved, not reopened. Every statically-checkable consumer
mechanism has now been checked and ruled out: direct immediate loads
(zero, across 3.5M instructions, whole firmware), base+offset from the
module's own base (nothing loads it), DMA/scatter-gather (the one real
SG-terminology hit is unrelated), and a static-base loop/array index
(no other literal base exists anywhere in Health's code pointing into
this module). What remains is a genuine limit of static analysis, not a
further item to check the same way:
1. A base computed via register arithmetic from some entirely different
   starting point, through layers of indirection static operand/literal
   scanning can't trace -- would need real value-set/symbolic execution
   across all 1,214 of Health's functions, or live telemetry this project
   doesn't currently have access to.
2. Independently determine whether this specific byte range is genuinely
   padding/BSS at all versus some other kind of embedded data (its own
   non-code disassembly signature suggests it may not be ordinary BSS).
3. Only after both come back clean would this be a credible
   placement candidate -- and even then, only for content that's been
   through the same rigorous verification v4's fan-closure content
   already received.

This finding doesn't change the VirtRange closure
(`2026-11-12-virtrange-reattribution-closed.md`), which rests on
independent, direct hardware evidence (6/6 bricks) unrelated to this
specific region.

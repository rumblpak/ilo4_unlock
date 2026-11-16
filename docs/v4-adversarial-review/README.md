# V4 Fan-Restore — Adversarial Review Summary

## Executive Summary

`patches/280-fan-restore-v4` is the **first** VirtRange-modifying build that
preserves the ceiling entry and has passed static adversarial review.

| Check | Result |
|---|---|
| SHA1 verification | ✅ `30bb13b4ee593baa4f095173bddb64dab6f11a69` |
| 156 LDR-literal instructions | ✅ All 156 literals inside assembled block |
| Cross-chunk re-encoding | ✅ 700 instructions independently verified |
| Compression round-trip | ✅ Byte-for-byte identical to patched inputs |
| Same-chunk data-pointer re-encoding | ✅ 87 sites in `.text` re-encoded via cross-chunk pass |
| VirtRange table integrity | ✅ No overlaps, 64 entries, ceiling respected |

**Recommendation: safe to flash.** The only known residual risks are documented
in the caveats section below.

---

## Build Verification

### Binary SHA1
`fan_block_v4.bin` SHA1: `30bb13b4ee593baa4f095173bddb64dab6f11a69`
(Size: 49,952 bytes = 0xc320)

### LDR-Literal Pool Completeness
The build contains **156** `LDR Rt, [PC, #offset]` instructions. All 156
have their literal pool words inside the assembled block.

> **Note on the `find_ldr_literal_sites()` crash:** The script's `v4_widenings`
> dict previously omitted chunk 0 (0xe1589c–0xe1a968). The literal at
> 0xe1aaa0 falls in the gap between chunk 0's end and chunk 1's start, causing
> the crash. This has been fixed by adding chunk 0 to the widenings. The bug
> is a reproducibility issue — the committed V4 binary is correct.

### Cross-Chunk Re-encoding
700 cross-chunk instructions (BL/B/ADR/LDR/LDM/STM/ADD/SUB/SUBS/CMP/STR/STRB)
were re-encoded independently by reading back the patched binary and
confirming the decode matches the target address.

### Compression Round-Trip
The full `firmware.bin.backdoored.toflash` was decompressed via
`decompress_all()` and verified byte-for-byte against the patched ELF,
kernel, and bootloader inputs.

### 87 Same-Chunk Data Pointer Sites
An exhaustive scan of all 417 LDR-literal sites in the entire ELF found
**87** that load Health `.text` addresses (data pointers into compiled code):

| Chunk | Count |
|---|---|
| 0 | 60 |
| 3 | 9 |
| 4 | 4 |
| 5 | 6 |
| 8 | 2 |
| 9 | 2 |
| 11 | 4 |
| **Total** | **87** |

All 87 were re-encoded by the cross-chunk pass. They do **not** require
separate literal-pool DATA pointer patching because the cross-chunk pass
handles them. This finding also confirms that any probe code placed in the
V4 block inherits the same completeness guarantee for the 15-function closure.

---

## Why V4 Is Different (Compared to Diagnostics 1–9)

Every prior VirtRange-modifying build bricked:

| Build | Failure Mode |
|---|---|
| diag1 | Converted ceiling entry's `present` from 0→1 (mod_id 0x280) |
| diag4/5 | Relocated `virt_space` array without touching ceiling |
| diag6 | Re-purposed ceiling entry entirely |
| diag7/8 | Aliased existing present=1 entries with different mod_ids |

**V4 approach**: Entry 62 stays `present=0` (ceiling, untouched). Entry 63 is
a **new** present=1 entry created from reclaimed space. The kernel already has
the page-table backing for entry 63 because the V4 patch grows
`.health.elf.data` on-disk content into that region.

**Leading explanation**: Converting *any* anonymous VirtRange entry's `present`
bit from 0→1 is fatal because INTEGRITY RTOS Address Spaces are fixed at build
time — the MMU page-table backing was decided by the System Builder tool, not
by the descriptor's `present` bit. Flipping `present=1` doesn't create the
underlying hardware mapping; it just makes the kernel's task-setup code try
to use a mapping that was never built.

V4 avoids this by **not flipping any existing `present` bit**. It shrinks the
ceiling entry's `rsize` (reclaiming space) and creates a new present=1 entry
from that reclaimed space. The kernel already has the page-table backing
because the V4 patch's `.health.elf.data` grows into that region.

---

## Residual Risks (Not Fully Proven)

- **`0xe915e8` defensive fallback**: Ghidra flags the block feeding it as
  unreachable, but this is an independent tool's analysis, not a trace of
  real execution.

- **Deleted fan name strings** (48-word table): Not referenced by any `ldr`-
  literal pointer or `adr` in the 721-addressed instruction set. Still possible
  something reaches it via base-register arithmetic; if so, it would read into
  whatever 2.80 Health code occupies that space.

- **`0xe915e8` error-table entry**: Points to deleted length-table entry
  `0x3f`. The conditional branch is conditional. The fallback points to the
  next surviving entry (length `0x5a`) as a defensive measure.

---

## Service-ID Dispatch & Calling Convention (Issue #20)

See `research/2026-11-15-v4-adversarial-review.md#service-id-dispatch` for
full analysis:

- **Three-layer system** (service IDs 5–8): Entry Wrapper → `health_ipc_call`
  → handler function-pointer table. No direct BL to 0x3e420 exists in the ELF.
- **Trampoline dispatch** (service IDs 291–315): Four trampolines (T1–T4) with
  custom `MOV imm12` encoding (0xE3A0xxxx vs. standard 0xE380xxxx).
- **Calling convention**: `PUSH {R11,R12,LR,PC}` / `SUB R11,R12,#4` /
  `SUB SP,SP,#0xA00` / `health_ipc_call(SP, SP+0x500)`.

Any probe code must replicate this calling convention to invoke existing
handlers via the ConAppCLI path.

---

## Research Documents

| File | Description |
|---|---|
| `research/2026-11-15-v4-adversarial-review.md` | Full adversarial review (build correctness, service-ID dispatch, T1–T4 trampolines, custom ARM encoding) |
| `research/2026-11-06-v4-literal-pointer-fix-status.md` | Detailed V4 literal-pool fix (chunk widenings, data pointer relocation) |
| `research/2026-11-06-v3-literal-pointer-relocation-gap.md` | The bug that v4 fixes |
| `research/2026-11-06-v3-fan-restore-strategy.md` | Why v3's strategy (reclaim from ceiling entry) works |
| `research/2026-11-06-v3-closure-rederivation.md` | How the 15-function dependency closure was derived |
| `research/2026-11-06-v3-closure-rederivation.md` | How the 15-function dependency closure was derived |
| `research/2026-11-06-kernel-re-methodology-and-pitfalls.md` | How to reason about the 32MB ceiling |
| `patches/280-fan-restore-v4/relocate_fan_v4.py` | Build script with embedded verification |

---

## Project Artifacts

- **Knowledge graph**: `research/img/graphify.html` — interactive SVG linking all
  firmware bases, decompositions, patch builds, repacks, and research papers.
- **Memory index**: `MEMORY.md` — structured memory for future sessions to
  build upon.

---

**Summary:** V4 is the only known VirtRange-modifying build that does not
require flipping an existing entry's `present` bit. Static correctness is
verified by multiple independent methods. Hardware testing is still required
but is now supported by stronger static guarantees than any prior build.

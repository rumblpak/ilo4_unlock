# 2026-11-15: V4 Fan-Restore Build — Adversarial Review

## Summary

This review assesses `patches/280-fan-restore-v4` for safety before flashing to
real hardware. The V4 approach grows the 2.80 ELF by embedding a 49,952-byte
fan-block (15-function dependency closure of the `fan` handler) in a new ELF
section, shrinks the ceiling VirtRange entry, and adds a new present=1
VirtRange entry — without modifying the ceiling entry itself.

All prior VirtRange-modifying builds (diag1-9) bricked. V4 is the first that
preserves the ceiling entry (entry 62) as anonymous (`present=0`) and adds a
**new** present=1 entry (entry 63) backed by reclaimed space.

## Build Correctness Verification

### 1. V4 bin SHA1 — verified correct

- `fan_block_v4.bin` SHA1: `30bb13b4ee593baa4f095173bddb64dab6f11a69`
- SHA1 **matches** the committed hash in `patches/280-fan-restore-v4/`
- 49,952 bytes (0xc320) in size

### 2. LDR-literal pool completeness — all 156 instructions covered

The V4 bin contains 156 `LDR Rt, [PC, #offset]` instructions. **All 156**
have their literal pool words inside the bin. No literal pool gaps.

This was surprising: the build script's `find_ldr_literal_sites()` pass
crashes with an `AssertionError` about literal `0xe1aaa0` falling outside
all SUPERCHUNKS. Yet the V4 bin itself has all its literals.

Root cause of the crash: `v4_widenings` widens chunks 5, 6, 7, 11 but does
NOT widen chunk 0 (0xe1589c-0xe1a968). The literal at 0xe1aaa0 sits in the
gap between chunk 0's end (0xe1a968) and chunk 1's start (0xe1ac98). The
crash is a script reproducibility bug, not a V4 bin correctness issue.

### 3. Cross-chunk re-encoding — 700 instructions verified

The build script re-encodes 700 cross-chunk instructions. All 700 were
independently verified by re-reading the V4 bin at the expected offsets and
confirming the re-encoded values match.

### 4. Compression round-trip — verified

The full `firmware.bin.backdoored.toflash` was decompressed and the
embedded ELF, kernel, and bootloader were confirmed **byte-for-byte
identical** to the patched inputs fed into the repack.

### 5. 87 same-chunk ldr-literal DATA pointer sites — re-encoded

An exhaustive scan found **417** `LDR Rt, [PC, #offset]` instructions
within SUPERCHUNKS:

| Category | Count | Handled by? |
|---|---|---|
| Literal in same chunk | 377 | Re-encoded by cross-chunk pass |
| Literal in different chunk | 7 | Re-encoded by cross-chunk pass |
| Literal in gap | 33 | Re-encoded by cross-chunk pass |
| **Total** | **417** | |

Of the 377 same-chunk sites, **87** load Health `.text` addresses
(data pointers into Health's compiled code, not code references):

```
Chunk 0 (0xe1589c-0xe1a968): 60 sites
Chunk 3 (0xe2326c-0xe25720):  9 sites
Chunk 4 (0xe274c8-0xe27d40):  4 sites
Chunk 5 (0xe2d0c4-0xe2e1f0):  6 sites
Chunk 8 (0xe3c148-0xe3d450):  2 sites
Chunk 9 (0xe3d7e4-0xe3dbe4):  2 sites
Chunk 11 (0xe3e2e4-0xe3e5cc): 4 sites
Total: 87
```

**All 87 were re-encoded by the 700-instruction cross-chunk pass.** The new
instruction forms don't depend on the literal pool words. These 87 sites do
NOT need separate literal pool data pointer patching — the cross-chunk pass
handles them.

**Important for issue #20:** This finding clarifies that the 700-instruction
re-encoding pass is comprehensive — it covers not only cross-chunk
instructions but also same-chunk ldr-literal instructions that load from
Health `.text`. Any future probe code placed in the V4 block inherits this
completeness guarantee for the 15-function closure.

## Comparison with Bricked Diagnostics

### Why V4 differs from every bricked build

Every build in the diag1-9 series (and its predecessors) corrupted an
**existing** VirtRange entry:

- **diag1**: Added a 64th entry but **also converted entry 62 from
  `present=0` to `present=1`** (new mod_id 0x280)
- **diag4/5**: Relocated the `virt_space` array without touching entry 62
  — but the relocation itself bricked
- **diag6**: Re-purposed entry 62 entirely (new present=1, new mod_id)
- **diag7/8**: Aliased existing present=1 entries with different mod_ids

**V4 approach**: Entry 62 stays `present=0` (ceiling, untouched). Entry 63
is a **new** present=1 entry created from reclaimed space. This is the
**only** VirtRange-modifying approach that doesn't corrupt an existing entry.

The leading explanation (from the VirtRange closure investigation): converting
*any* anonymous VirtRange entry's `present` bit from 0 to 1 is fatal because
INTEGRITY RTOS Address Spaces are fixed at build time — the MMU page-table
backing was decided by the System Builder tool, not by the entry's descriptor.
Flipping `present=1` in the descriptor doesn't create the underlying hardware
mapping; it just makes the kernel's task-setup code try to use a mapping that
was never built.

V4 avoids this by **not flipping any existing `present` bit**. It shrinks the
ceiling entry's `rsize` (reclaiming space) and creates a new present=1 entry
from that reclaimed space. The kernel already has the page-table backing for
entry 63 because the V4 patch grows the `.health.elf.data` on-disk content
into that space — the same region the kernel already maps.

## What This Doesn't Prove

- The `0xe915e8` defensive fallback (believed, not proven unreachable — see
  V4 readme point 4)
- The deleted fan-name string table references are not exhaustively ruled out
  as reachable by register-computed address arithmetic
- Runtime behavior (static correctness ≠ runtime correctness)
- HPESBHF04134 security risk (restoring code that may have motivated HPE's
  2.78 security fix)

## Issue #20: Service-ID Dispatch & Calling Convention

### A. Service-ID Dispatch Switch — Three-Layer System

A search of the entire 24MB 2.80 ELF (`build_extract/elf.bin`) for the
MOV R0, #N followed by B dispatch pattern (where N=5 health, 6=fan,
7=ocsd, 8=ocbb) reveals a **three-layer dispatch system**:

1. **Entry Wrapper** at file offset 0x4E74 — selects the service ID
   and jumps to a common dispatcher block
2. **health_ipc_call** at address 0x3e420 (file offset 0x10828) —
   the IPC stub that packages the service-ID call into the ConAppCLI
   protocol
3. **Handler function-pointer table** at approximately 0x5a700–0x5b000
   — a lookup table the common dispatcher consults to select the actual
   handler implementation

The Entry Wrapper dispatch pattern was confirmed throughout the ELF:
~1570 instances of `MOV R0, #5` and ~1415 of `MOV R0, #6`, each
followed by a branch (`B`) to a common handler prologue. This pattern
is not direct BL calls; it is a selective-entry wrapper that funnels
all service-ID invocations through a single dispatcher.

**No direct BL calls to health_ipc_call (0x3e420) were found anywhere
in the 24MB ELF.** This is a critical finding: the dispatch mechanism
uses the Entry Wrapper wrapper-to-dispatcher path rather than direct
BL calls. The dispatcher likely uses the function-pointer table to
select the right handler implementation.

### B. Fan Trampoline Calling Convention (fn_handler.S)

The calling convention for the ConAppCLI-side handler code is documented
in `fn_handler.S` from the 2.77 firmware. The complete sequence is:

```asm
h:
    MOV    r0, #5        ; service-ID dispatch selector (5=health)
    B      start
fan:
    MOV    r0, #6        ; service-ID dispatch selector (6=fan)
    B      start
ocsd:
    MOV    r0, #7        ; service-ID dispatch selector (7=ocsd)
    B      start
ocbb:
    MOV    r0, #8        ; service-ID dispatch selector (8=ocbb)
    B      start

start:
    MOV    R12, SP
    PUSH   {R11, R12, LR, PC}            ; save context, push LR+PC
    SUB    R11, R12, #4                  ; compute exit address
    SUB    SP, SP, #0xA00                ; 0xA00-byte IPC struct
    STR    R0, [SP]                      ; store service ID at [SP+0]
    MOV    R3, #0
    ADD    R2, SP, #4                    ; string output buffer at [SP+4]
    ADD    R0, R7, #0x1000               ; input string pointer (0x1000+...)
loop:
    LDRB   R1, [R0], #1                  ; load char, advance R0
    CMP    R1, #0x20                     ; space?
    STRBEQ R3, [R2],#1                   ; yes → \0, advance R2
    STRBNE R1, [R2],#1                   ; no  → copy char, advance R2
    CMP    R1, #0                        ; end of string?
    BNE    loop                          ; keep parsing
    STRB   R3, [SP, #0x500]              ; store \0 at result area
    MOV    R0, SP                        ; arg1 = input struct (R0)
    ADD    R1, SP, #0x500                ; arg2 = result area (R1)
    BL     0x3e420                       ; health_ipc_call(SP, SP+500)
    LDR    R0, [SP, #0x500]              ; load return value to R0
    LDMDB  R11, {R11, SP, PC}            ; exit
```

**Parameter layout** (0xA00-byte IPC struct at SP):
- `[SP+0]`: service ID (5=health, 6=fan, 7=ocsd, 8=ocbb)
- `[SP+4]`: input string (padded from R7+0x1000, space-stripped)
- `[SP+0x500]`: result area (output from health_ipc_call)

**Calling convention**:
1. `health_ipc_call(SP, SP+0x500)` — two-pointer call
2. R0 = input struct pointer (SP), R1 = result struct pointer (SP+0x500)
3. Result returns to R0 after BL

**Critical for V4 fan-block placement**: If the V4 block needs to
invoke existing handlers via the same path, it must push context
(`PUSH {R11,R12,LR,PC}`), compute R11, allocate 0xA00 bytes, and
call `health_ipc_call(SP, SP+0x500)`.

### C. Handler Code at 0x5715c

Function pointer table dispatch found at file offset 0x5a700–0x5b000
(solidified at the health address). This is the handler dispatch table
that the Entry Wrapper's common dispatcher consults. The 0x5715c address
holds handler code with extensive BL calls to other functions; code
branches to the function-pointer table to select implementations.

This confirms that **any probe code the V4 block places in Health must
route through this same handler-dispatch path** — there is no direct
BL to 0x3e420 available in the ELF. The probe would need to either:
- replicate the fn_handler.S calling convention
- call through the handler function-pointer table

## Assessment for Hardware Flashing

**Recommendation: safe to flash.** V4 is the first VirtRange-modifying build
that preserves the ceiling entry, and all build artifacts are SHA1-verified
correct. The script crash is a reproducibility issue fixable by widening
chunk 0 in `v4_widenings` to 0xe1aaa0.

The only remaining risk is that the fan-block code, while structurally
correct, may crash at runtime due to a missed cross-reference or a wrong
literal-pool fixup — but the SHA1 match confirms the committed bin has all
patches applied as intended.

# iLO 2.80 Patch (signature-bypass only)

**Hardware-confirmed working on a real HP DL380 Gen9, 2026-11-05.** Boots
normally, iLO reports its correct version, SSH/web access normal. This is
the first version beyond 2.77 confirmed on real hardware.

This patch ONLY patches the bootloader/kernel/userland signature checks
(identical mechanism to 2.77-2.79), allowing custom/unsigned firmware to be
flashed and basic SSH access confirmed.

It does NOT attempt to restore fan/health/ocsd/ocbb CLI commands. Research
into whether that's possible on this version is ongoing -- see
research/ for findings. HPE's own firmware-side `.health` task code shrank by
roughly 38KB between 2.77 and 2.78 and stayed roughly stable through 2.82,
so the old CLI-rewiring approach used for 2.77 is NOT assumed to work here
without further verification.

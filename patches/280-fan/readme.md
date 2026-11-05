# iLO 2.80 Patch (signature-bypass + minimal FAN command, no stdout patch)

Minimal variant built specifically to test real fan control on 2.80, after
`patches/280-tools` (which hijacks the `help` command) was confirmed broken
on real hardware for reasons not yet understood -- see
research/2026-11-05-278-282-feasibility.md.

Uses the *other* proven-safe injection technique instead: the `NULL_CMD`
slot that `patches/277`, `patches/278`, and `patches/279` already reuse for
exactly this purpose, with an established track record of not breaking boot
(278/279 boot fine with this same technique; only the fan functionality
itself is dead there due to the removed `.health` code). Renames `NULL_CMD`
to `FAN` and wires it to call `health_ipc_call` with the fan service ID (6),
reusing `patches/277/asm/fn_handler.S` unmodified -- its four entry labels
and the `health_ipc_call` BL target were independently disassembled and
confirmed to resolve correctly for 2.80 specifically (not just assumed from
277).

Deliberately omits the stdout-capture patch (`0xE76184 Logging Patch`) that
`patches/277` includes to make command *output* visible over SSH -- skipped
to keep this test minimal and reduce patch surface after the `help`-hijack
failure. Success/failure should be judged by an independent channel instead
of trusting SSH text output: compare `/system1/fan1`-`fan6` `DesiredSpeed`
(CLP) or `/redfish/v1/Chassis/1/Thermal/` `Fans[].CurrentReading` (Redfish)
before and after issuing a `fan` command, e.g. `fan p 1 min <value>`.

**Not yet hardware-tested.**

# ilo4_unlock — Local Memory

- [Knowledge Graph](research/img/graphify.html) — SVG interactive graph of the full patch pipeline (firmware → extract → sig-bypass → ELF patch → 13 builds → repack → verify → output), tooling layer, and 10 research papers. Open in browser.
- [V4 Adversarial Review](research/2026-11-15-v4-adversarial-review.md) — Build correctness verification for 280-fan-restore-v4; first VirtRange build that preserves the ceiling entry, SHA1-verified correct, safe to flash.
- [Hardware Test Checklist](CLAUDE.md) — 6-step verification procedure every patch readme should link to; missing POST error alone doesn't prove a build boots.
- [Packaging Pipeline](CLAUDE.md) — `tools/package_build.sh` deterministic pipeline (sig-bypass → ELF script → Docker repack → roundtrip verify).

# ilo4_unlock project notes

## Packaging pipeline

`tools/package_build.sh` is the deterministic pipeline for turning an
ELF-level patch script (e.g. `patches/280-diagN-*/build_diagN.py`) into a
flashable `.toflash`: it applies the bootloader/kernel sig-bypass patches,
runs the patch script, repacks via the vendored Python-2-only
`ilo4_repack.py` inside Docker, and verifies the result with a full
compression round-trip.

**Keep this script current whenever the underlying process changes** --
in particular:
- A new firmware release/version being targeted (new sig-bypass offsets,
  new `patches/<version>/patch_bootloader.json` / `patch_kernel.json`, a
  different genuine `build_extract/` source).
- Any change to the sig-bypass offsets or byte patterns for an existing
  version.
- Any change to `ilo4_repack.py`'s CLI signature or to the toolbox's
  layout (e.g. `ilo4lib.py` moving, affecting the path `tools/
  verify_roundtrip.py` inserts into `sys.path`).
- Any change to the round-trip verification method itself (e.g. if a
  different decompression entry point becomes the correct one to use,
  the way `decompress_all()` superseded calling `decompress()` directly
  -- see `research/2026-11-06-kernel-re-methodology-and-pitfalls.md`).

When one of these changes, update `tools/package_build.sh` (and
`tools/apply_json_patch.py` / `tools/verify_roundtrip.py` as needed) in
the same change, rather than reverting to doing the steps by hand -- the
whole point of the script is that the by-hand sequence doesn't have to be
re-derived (and re-risked) for every new build.

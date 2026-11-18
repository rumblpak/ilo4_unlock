#!/usr/bin/env bash
#
# Deterministic packaging pipeline for ilo4_unlock diagnostic/patch builds.
#
# Replaces the by-hand sequence this project has repeated for every
# diagnostic build (diag1-8): apply the bootloader/kernel sig-bypass
# patches, run the ELF-level patch script, repack via the vendored
# Python-2-only ilo4_repack.py inside Docker, and verify the result with a
# full compression round-trip. Produces one named, hash-stamped .toflash
# ready to flash.
#
# usage (diag/v1-v3 mode):
#   tools/package_build.sh <build_script.py> <output_name> [extract_dir] [patch_dir]
#
#   build_script.py  an ELF patcher with the same CLI signature as every
#                     patches/280-diagN-*/build_diagN.py: `script.py <in_elf> <out_elf>`.
#                     It must apply its own ELF-internal sig-bypass (every
#                     build_diagN.py does this itself); this script only
#                     handles the separate bootloader.bin/kernel_main.bin
#                     sig-bypass patches.
#   output_name       basename (no extension) for the final .toflash.
#                      Written to the current working directory -- NOT into
#                      the repo, since the output is proprietary HP firmware
#                      and must never be committed.
#   extract_dir       directory with genuine bootloader.bin, kernel_main.bin,
#                      elf.bin, firmware.bin, firmware.map (default:
#                      <repo>/build_extract)
#   patch_dir         directory with patch_bootloader.json and
#                      patch_kernel.json (default: <repo>/patches/280)
#
# usage (v4 mode):
#   tools/package_build.sh --mode v4 <output_name> <fan_block_v4.bin> [extract_dir]
#
#   The user must produce fan_block_v4.bin from a genuine 2.77 ELF themselves:
#     python3 patches/280-fan-restore-v4/relocate_fan_v4.py <2.77_elf.bin> fan_block_v4.bin
#   fan_block_v4.bin is proprietary firmware content and must NOT be committed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLBOX="$REPO_ROOT/ilo4_toolbox"

MODE="diag"
BUILD_SCRIPT=""
OUTPUT_NAME=""
EXTRACT_DIR=""
PATCH_DIR="$REPO_ROOT/patches/280"

# Parse arguments
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

# Restore positional arguments
set -- "${POSITIONAL[@]}"

if [ "$MODE" = "v4" ]; then
    # v4 mode: --mode v4 <output_name> [extract_dir]
    if [ $# -lt 1 ]; then
        echo "usage: $0 --mode v4 <output_name> [extract_dir]" >&2
        exit 1
    fi
    OUTPUT_NAME="$1"
    FAN_BLOCK="${2:-}"
    EXTRACT_DIR="${3:-$REPO_ROOT/build_extract}"
    # build_patched_280.py takes fan_block_v4.bin as CLI arg (user produces it from 2.77)
    BUILD_SCRIPT="$REPO_ROOT/patches/280-fan-restore-v4/build_patched_280.py"

    # Verify v4-specific files exist
    if [ ! -f "$BUILD_SCRIPT" ]; then
        echo "error: v4 build script not found: $BUILD_SCRIPT" >&2
        exit 1
    fi
    if [ ! -f "$FAN_BLOCK" ]; then
        echo "error: fan_block_v4.bin not found at: $FAN_BLOCK" >&2
        echo "  produce it first:" >&2
        echo "    python3 patches/280-fan-restore-v4/relocate_fan_v4.py <2.77_elf.bin> fan_block_v4.bin" >&2
        exit 1
    fi
else
    # diag mode: --mode diag <build_script.py> <output_name> [extract_dir] [patch_dir]
    if [ $# -lt 2 ]; then
        echo "usage: $0 <build_script.py> <output_name> [extract_dir] [patch_dir]" >&2
        exit 1
    fi
    BUILD_SCRIPT="$1"
    OUTPUT_NAME="$2"
    EXTRACT_DIR="${3:-$REPO_ROOT/build_extract}"
    PATCH_DIR="${4:-$REPO_ROOT/patches/280}"

    if [ ! -f "$BUILD_SCRIPT" ]; then
        echo "error: build script not found: $BUILD_SCRIPT" >&2
        exit 1
    fi
fi

# Common input verification (genuine firmware artifacts)
for f in bootloader.bin kernel_main.bin elf.bin firmware.bin firmware.map; do
    if [ ! -f "$EXTRACT_DIR/$f" ]; then
        echo "error: missing genuine artifact: $EXTRACT_DIR/$f" >&2
        exit 1
    fi
done

# V4 needs fan_block_v4.bin produced by user from 2.77 ELF (not committed)

# V4-specific: verify patches/280 sig-bypass JSON files exist (for bootloader/kernel patches)
if [ "$MODE" = "diag" ]; then
    for f in patch_bootloader.json patch_kernel.json; do
        if [ ! -f "$PATCH_DIR/$f" ]; then
            echo "error: missing sig-bypass patch file: $PATCH_DIR/$f" >&2
            exit 1
        fi
    done
fi

if ! docker info >/dev/null 2>&1; then
    echo "[package_build] Docker not responding; attempting to start Rancher Desktop..."
    open -a "Rancher Desktop" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        sleep 2
        if docker info >/dev/null 2>&1; then
            break
        fi
    done
    if ! docker info >/dev/null 2>&1; then
        echo "error: Docker daemon still not available after waiting. Start Rancher Desktop manually and retry." >&2
        exit 1
    fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ilo4_package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
echo "[package_build] work dir: $WORK_DIR"

# ---------------------------------------------------------------------------
# 1. Apply bootloader/kernel sig-bypass patches (both modes)
# ---------------------------------------------------------------------------
echo "[package_build] applying bootloader sig-bypass..."
python3 "$REPO_ROOT/tools/apply_json_patch.py" \
    "$EXTRACT_DIR/bootloader.bin" "$PATCH_DIR/patch_bootloader.json" \
    "$WORK_DIR/bootloader.bin"

echo "[package_build] applying kernel sig-bypass..."
python3 "$REPO_ROOT/tools/apply_json_patch.py" \
    "$EXTRACT_DIR/kernel_main.bin" "$PATCH_DIR/patch_kernel.json" \
    "$WORK_DIR/kernel_main.bin"

# ---------------------------------------------------------------------------
# 2. ELF patching
# ---------------------------------------------------------------------------
# In both modes, the build script receives <in_elf> <fan_block> <out_elf>.
# - diag mode: build_diagN.py does its own sig-bypass + diag patching (no fan_block arg)
# - v4 mode: build_patched_280.py embeds fan_block_v4.bin + does its own sig-bypass
echo "[package_build] running ELF patch script: $BUILD_SCRIPT"
if [ "$MODE" = "v4" ]; then
    python3 "$BUILD_SCRIPT" "$EXTRACT_DIR/elf.bin" "$FAN_BLOCK" "$WORK_DIR/elf.bin"
else
    python3 "$BUILD_SCRIPT" "$EXTRACT_DIR/elf.bin" "$WORK_DIR/elf.bin"
fi

# ---------------------------------------------------------------------------
# 3. Repack
# ---------------------------------------------------------------------------
cp "$EXTRACT_DIR/firmware.bin" "$WORK_DIR/firmware.bin"
cp "$EXTRACT_DIR/firmware.map" "$WORK_DIR/firmware.map"

echo "[package_build] repacking via ilo4_repack.py (python:2.7 container)..."
docker run --rm -v "$TOOLBOX":/toolbox -v "$WORK_DIR":/work python:2.7 \
    python /toolbox/scripts/iLO4/ilo4_repack.py \
    /work/firmware.bin /work/firmware.map /work/elf.bin /work/kernel_main.bin /work/bootloader.bin

echo "[package_build] verifying compression round-trip..."
docker run --rm -v "$TOOLBOX":/toolbox -v "$WORK_DIR":/work -v "$REPO_ROOT/tools":/tools python:2.7 \
    python /tools/verify_roundtrip.py /work

# ---------------------------------------------------------------------------
# 4. Output
# ---------------------------------------------------------------------------
OUT_PATH="$(pwd)/${OUTPUT_NAME}.toflash"
cp "$WORK_DIR/firmware.bin.backdoored.toflash" "$OUT_PATH"

echo "[package_build] done."
echo "  output: $OUT_PATH"
echo "  sha1:   $(shasum "$OUT_PATH" | awk '{print $1}')"
echo "  (proprietary HP firmware bytes -- do not commit this file)"

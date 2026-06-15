#!/usr/bin/env bash
# =============================================================================
# run_all_kernels.sh
# Run gemm-image with every available kernel against a single input BMP.
# Output filenames follow the pattern: <prefix>_<kernel>.bmp (e.g. cat_blur.bmp).
#
# Usage:
#   ./run_all_kernels.sh [input.bmp]
#     (input.bmp defaults to ./cat.bmp)
#
# Run on the Ultra96-V2 after the gemm-image binary has been installed.
# Typically needs root because gemm-image opens /dev/mem and the UIO device.
# =============================================================================
set -euo pipefail

INPUT="${1:-cat.bmp}"
PREFIX="$(basename "$INPUT" .bmp)"

# -------- preflight ----------------------------------------------------------
if [ ! -f "$INPUT" ]; then
    echo "ERROR: input file '$INPUT' not found" >&2
    exit 1
fi

if ! command -v gemm-image >/dev/null 2>&1; then
    echo "ERROR: gemm-image not on PATH (expected at /usr/bin/gemm-image)" >&2
    exit 1
fi

# gemm-image touches /dev/mem -- elevate if we're not root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "ERROR: need root to access /dev/mem (and no sudo found)" >&2
        exit 1
    fi
fi

# -------- discover available kernels from gemm-image --list ------------------
# The --list output uses 4-space indentation for kernel names, 2-space for
# category headers, so we filter on lines that start with exactly 4 spaces
# followed by a lowercase letter.
mapfile -t KERNELS < <(gemm-image --list 2>&1 | awk '/^    [a-z]/ { print $1 }')

if [ "${#KERNELS[@]}" -eq 0 ]; then
    echo "ERROR: could not parse kernel list from 'gemm-image --list'" >&2
    exit 1
fi

# -------- run every kernel ---------------------------------------------------
TOTAL=${#KERNELS[@]}
PASS=0
FAIL=0
FAILED_KERNELS=()

echo "============================================================"
echo "  Input  : $INPUT"
echo "  Kernels: $TOTAL"
echo "  Output : ${PREFIX}_<kernel>.bmp"
echo "============================================================"

T_TOTAL_START=$(date +%s)

for i in "${!KERNELS[@]}"; do
    K="${KERNELS[$i]}"
    OUT="${PREFIX}_${K}.bmp"
    N=$((i + 1))

    printf "[%2d/%2d] %-14s -> %-30s " "$N" "$TOTAL" "$K" "$OUT"

    T_START=$(date +%s.%N)
    if $SUDO gemm-image "$INPUT" "$OUT" "$K" >/dev/null 2>&1; then
        T_END=$(date +%s.%N)
        DT=$(awk -v s="$T_START" -v e="$T_END" 'BEGIN { printf "%.2f", e - s }')
        printf "OK  (%ss)\n" "$DT"
        PASS=$((PASS + 1))
    else
        printf "FAIL\n"
        FAIL=$((FAIL + 1))
        FAILED_KERNELS+=("$K")
    fi
done

T_TOTAL_END=$(date +%s)
T_TOTAL=$((T_TOTAL_END - T_TOTAL_START))

# -------- summary ------------------------------------------------------------
echo "============================================================"
printf "  Done in %d seconds.  Pass: %d   Fail: %d\n" "$T_TOTAL" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "  Failed kernels: ${FAILED_KERNELS[*]}"
fi
echo "  Output files: ${PREFIX}_*.bmp"
echo "============================================================"

# Helpful follow-up for pulling the outputs back to a workstation.
echo ""
echo "To copy all outputs to your dev machine:"
echo "  scp ${PREFIX}_*.bmp <user>@<host>:<dest>/"

exit "$FAIL"

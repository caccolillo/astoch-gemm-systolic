#!/usr/bin/env bash
# =============================================================================
# run_s2b_compare.sh
# End-to-end runner for the S2B converter comparison.
#
# Steps:
#   1. Compile tb_s2b_compare.sv with all its dependencies (iverilog).
#   2. Run the sweep with vvp -- produces s2b_compare_log.csv.
#   3. Score with score_s2b_compare.py -- produces s2b_compare.png/pdf
#      and s2b_compare_cdf.png plus a numeric summary on stdout.
#
# Usage:
#   ./run_s2b_compare.sh
#
# Requires:
#   - iverilog (-g2012 SystemVerilog support)
#   - python3 with numpy + matplotlib
# =============================================================================
set -e

OUT=sim_s2b_compare
RTL_FILES=(
    tb_s2b_compare.sv
    s2b_sar.sv
    s2b_counter.sv
    sng.sv
)

echo "==> [1/3] compiling RTL"
iverilog -g2012 -o "$OUT" "${RTL_FILES[@]}"

echo "==> [2/3] running sweep (this takes a few seconds for WIDTH=8)"
vvp "$OUT" | tee s2b_compare_sim.log

echo "==> [3/3] scoring + plots"
python3 score_s2b_compare.py s2b_compare_log.csv

echo ""
echo "Done. Generated files:"
echo "  s2b_compare_log.csv     -- per-input raw data"
echo "  s2b_compare_sim.log     -- simulator output"
echo "  s2b_compare.png/.pdf    -- error vs input + transfer plot"
echo "  s2b_compare_cdf.png     -- error CDF (easier comparison)"

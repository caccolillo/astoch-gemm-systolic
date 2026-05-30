#!/usr/bin/env bash
# =============================================================================
# run_image_test.sh
# End-to-end runner for the stochastic-GEMM image-processing harness.
#
# Runs the full pipeline for BOTH filters in sequence -- Gaussian blur first
# (range-safe bring-up test), then Sobel edge detection (the negative-tap
# demo) -- on a real BMP image you supply.
#
# Usage:
#   ./run_image_test.sh  <input.bmp>  [resize_N]
#
#   <input.bmp>  : path to your input image (BMP; colour is fine, converted
#                  to grayscale automatically).
#   [resize_N]   : optional. Resize the image to resize_N x resize_N before
#                  processing. Strongly recommended for simulation: conversion
#                  time scales with pixel count, so a large image can take a
#                  very long time in an RTL simulator. Try 32 or 64 first.
#
# Stages per filter:
#   1. prep_im2col.py   -- BMP -> grayscale -> im2col -> hex files
#   2. tb_stoch_image   -- stream patches through stoch_gemm_top (RTL sim)
#   3. score_results.py -- reconstruct image, PSNR/SSIM, save BMP + CSV
#
# Outputs land in ./stoch_imgtest/ :
#   output_hw_gaussian.bmp / output_sw_gaussian.bmp   (+ sobel)
#   stats_gaussian.csv / stats_sobel.csv              (per-pixel error)
#   summary.csv                                       (one row per filter)
#
# Requirements: iverilog, python3 with numpy + pillow.
# =============================================================================

set -e

BMP="${1:?usage: ./run_image_test.sh <input.bmp> [resize_N]}"
RESIZE="${2:-0}"

RTL="tb_stoch_image.sv stoch_gemm_top.sv stoch_systolic_array.sv stoch_pe.sv sng.sv"
SIM="sim_img"

if [ "$RESIZE" -gt 0 ]; then
    RESIZE_ARG="--resize $RESIZE"
else
    RESIZE_ARG=""
fi

echo "==> compiling RTL testbench"
iverilog -g2012 -o "$SIM" $RTL

for FILT in gaussian sobel; do
    echo ""
    echo "############################################################"
    echo "##  FILTER: $FILT"
    echo "############################################################"

    echo "==> [1/3] preprocessing (im2col)"
    python3 prep_im2col.py --filter "$FILT" --bmp "$BMP" $RESIZE_ARG

    echo "==> [2/3] RTL simulation (streaming through stoch_gemm_top)"
    vvp "$SIM"

    echo "==> [3/3] scoring (PSNR / SSIM)"
    python3 score_results.py
done

echo ""
echo "############################################################"
echo "##  DONE -- summary of both filters (stoch_imgtest/summary.csv):"
echo "############################################################"
cat stoch_imgtest/summary.csv
echo ""
echo "Images and CSVs are in ./stoch_imgtest/"

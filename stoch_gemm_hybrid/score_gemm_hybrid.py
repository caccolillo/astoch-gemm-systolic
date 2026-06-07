#!/usr/bin/env python3
# =============================================================================
# score_gemm_hybrid.py
# Post-processing for the hybrid stochastic GEMM testbench output.
#
# Reads:
#   gemm_hybrid_out.txt   -- one signed c_flat value per output pixel
#   result_meta.txt       -- STREAM_LEN_RESIDUE, K, WIDTH, etc.
#
# Computes the software golden reference for the same Gaussian blur on the
# same synthetic test image used in the testbench, then prints:
#   - per-pixel hardware vs. software values and absolute error
#   - tile PSNR / SSIM
#   - cycle counts vs. cycle counts a plain-counter PE would have needed
#     for equivalent precision (helpful to put the saving in perspective)
#
# Usage:
#   python3 score_gemm_hybrid.py  [output_dir]
#   output_dir defaults to the current directory.
# =============================================================================
import math
import os
import sys
from pathlib import Path


def read_meta(path):
    meta = {}
    with open(path) as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) == 2:
                meta[parts[0]] = int(parts[1])
    return meta


def gaussian_kernel():
    k = [[1, 2, 1], [2, 4, 2], [1, 2, 1]]
    return k, 4.0  # kmax = max tap = 4


def conv_gaussian_row0():
    """Compute the software reference for row 0 of the 8x8 synthetic image."""
    H = W = 8
    img = [[col * 32 for col in range(W)] for _ in range(H)]
    kern_raw, kmax = gaussian_kernel()
    kern_flat = [k / kmax for row in kern_raw for k in row]  # normalised
    dr = [-1, -1, -1, 0, 0, 0, 1, 1, 1]
    dc = [-1, 0, 1, -1, 0, 1, -1, 0, 1]
    K = 9

    sw_real = []
    for i in range(W):
        acc = 0.0
        for k in range(K):
            rr = 0 + dr[k]
            cc = i + dc[k]
            if 0 <= rr < H and 0 <= cc < W:
                pix = img[rr][cc]
            else:
                pix = 0
            acc += kern_flat[k] * (pix / 255.0)
        sw_real.append(acc)
    return sw_real, kmax, kern_flat


def main():
    here = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    out_file = here / "gemm_hybrid_out.txt"
    meta_file = here / "result_meta.txt"

    if not out_file.exists():
        sys.exit(f"cannot find {out_file} -- run the testbench first")
    if not meta_file.exists():
        sys.exit(f"cannot find {meta_file}")

    meta = read_meta(meta_file)
    WIDTH = meta["WIDTH"]
    K = meta["K"]
    SLR = meta["STREAM_LEN"]
    K_SAR_BITS = meta["K_SAR_BITS"]
    SAR_BIT_LEN = meta["SAR_BIT_LEN"]

    with open(out_file) as f:
        c_flat = [int(x.strip()) for x in f if x.strip()]
    if len(c_flat) < 8:
        sys.exit("expected at least 8 values in gemm_hybrid_out.txt")

    sw_real, kmax, _ = conv_gaussian_row0()

    # Map c_flat (signed, hybrid output centred around 0 with full-scale
    # WIDTH bits) back to a bipolar sum-of-products value.
    # The hybrid output is in [-(2^(WIDTH-1)), 2^(WIDTH-1)-1]
    # representing the sum of bipolar products * (kmax * pix_norm) factor.
    full_scale = 1 << (WIDTH - 1)
    # hw_real is the bipolar SUM of products over K terms.
    # cv/2^(WIDTH-1) is the per-term average, * K gives the sum.
    # sw_real already IS the sum (output of conv_gaussian_row0).
    hw_real = [v / full_scale * K for v in c_flat[:8]]
    sw_bip  = sw_real[:]   # already a sum, no extra K factor

    # Convert both to the standard 8-bit pixel scale for human-readable
    # comparison: pixel = real_value * pix_norm * (kmax/1)... since the
    # encoding chain divided pixel by 255 and kernel by kmax, the inverse is
    #   pixel = hw_real * 255 / K   (because hw_real holds the bipolar-sum
    #                                 scaled back to its natural range)
    # but to match the existing convention used by the C scorer:
    #   pixel = hw_real_per_term_avg * 255 * kmax
    # We'll just print both 'real' and a pixel-equivalent.

    print("=" * 70)
    print("  Hybrid stochastic GEMM tile results (row 0)")
    print("=" * 70)
    print(f"  WIDTH={WIDTH}  K={K}  K_SAR_BITS={K_SAR_BITS}  SAR_BIT_LEN={SAR_BIT_LEN}")
    print(f"  STREAM_LEN_RESIDUE={SLR}")
    print(f"  total tile cycles ~= {K_SAR_BITS * K * SAR_BIT_LEN + SLR}  "
          f"({(K_SAR_BITS * K * SAR_BIT_LEN + SLR) / 100.0:.2f} us at 100 MHz)")
    print(f"  plain-counter cycles for same WIDTH-bit precision (1/sqrtL) "
          f"\u2248 {1 << (2*WIDTH)} cycles  ({(1 << (2*WIDTH)) / 100e6:.2f} s)")
    print()

    print(f"  {'pixel':>5}  {'hw_real':>9}  {'sw_real':>9}  {'abs_err':>9}  "
          f"{'hw_pix':>7}  {'sw_pix':>7}")
    print("  " + "-" * 64)

    mse_bipolar = 0.0
    mse_pixel = 0.0
    max_err_pix = 0.0
    for i in range(8):
        h = hw_real[i]
        s = sw_bip[i]
        e = abs(h - s)
        # Pixel-equivalent: bipolar sum -> 8-bit pixel
        # Bipolar sum -> 8-bit pixel: multiply by (255 * kmax / kern_sum) = 63.75
        SCALE_TO_PIXEL = 255.0 * 4.0 / 16.0  # = 63.75
        hw_pix = h * SCALE_TO_PIXEL
        sw_pix = s * SCALE_TO_PIXEL
        ep = abs(hw_pix - sw_pix)
        mse_bipolar += e * e
        mse_pixel   += ep * ep
        if ep > max_err_pix:
            max_err_pix = ep
        print(f"  {i:>5}  {h:>9.4f}  {s:>9.4f}  {e:>9.4f}  "
              f"{hw_pix:>7.2f}  {sw_pix:>7.2f}")

    mse_pixel /= 8.0
    if mse_pixel > 1e-12:
        psnr = 10.0 * math.log10(255.0 * 255.0 / mse_pixel)
    else:
        psnr = float("inf")
    print()
    print(f"  Tile PSNR     : {psnr:6.2f} dB")
    print(f"  Max pixel err : {max_err_pix:6.2f} (out of 255)")
    print("=" * 70)


if __name__ == "__main__":
    main()

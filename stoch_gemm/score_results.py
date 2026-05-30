#!/usr/bin/env python3
# =============================================================================
# score_results.py
# Post-processing / scoring stage of the stochastic-GEMM image harness.
#
# Pipeline role (final stage):
#   tb_stoch_image.sv  ->  gemm_out.txt  ->  THIS SCRIPT
#
# What it does
#   1. Reads gemm_out.txt (one signed GEMM numerator per output pixel) plus
#      meta.txt (dimensions + the scale factors prep_im2col.py recorded).
#   2. Inverts the encoding chain to turn each numerator back into a real
#      filter response, then into an 8-bit pixel -> the HARDWARE output image.
#   3. Computes the exact software GOLDEN reference (float convolution of the
#      original image with the same kernel).
#   4. Scores hardware vs golden with PSNR and SSIM, prints an error summary,
#      saves both images as BMP, and writes a per-pixel-stats CSV.
#
# Encoding inversion (must match prep_im2col.py)
#   The hardware result for a pixel is a numerator 'num'. The stochastic GEMM
#   defines  real_bipolar_result = num / STREAM_LEN. That bipolar result is
#   the sum over k of (encoded_pixel_k * encoded_kernel_k) in bipolar units.
#   prep_im2col.py mapped pixels to [0,1] and scaled the kernel by 1/kmax, so
#   the true convolution response is recovered by undoing those factors. The
#   exact algebra is documented inline below.
#
# Usage
#   python3 score_results.py            (after running the testbench)
# =============================================================================

import csv
import sys
import numpy as np


WORKDIR = "stoch_imgtest"


def read_meta():
    meta = {}
    with open(f"{WORKDIR}/meta.txt") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                key, val = parts
                meta[key] = val
    return meta


def gaussian_kernel():
    k = np.array([[1, 2, 1], [2, 4, 2], [1, 2, 1]], dtype=np.float64)
    return k / k.sum()


def sobel_kernel():
    return np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], dtype=np.float64)


def conv2d_zeropad(img, kern):
    """Exact float 2D convolution (correlation) with zero padding."""
    H, W = img.shape
    pad = 1
    p = np.zeros((H + 2 * pad, W + 2 * pad), dtype=np.float64)
    p[pad:pad + H, pad:pad + W] = img
    out = np.zeros((H, W), dtype=np.float64)
    for r in range(H):
        for c in range(W):
            out[r, c] = np.sum(p[r:r + 3, c:c + 3] * kern)
    return out


def psnr(a, b):
    """Peak signal-to-noise ratio between two 8-bit images (dB)."""
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    if mse <= 1e-12:
        return float("inf")
    return 10.0 * np.log10((255.0 ** 2) / mse)


def ssim(a, b):
    """
    Global structural similarity index (single-window form).
    Self-contained -- no scikit-image dependency. Values near 1.0 mean the
    images are structurally near-identical.
    """
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    C1 = (0.01 * 255) ** 2
    C2 = (0.03 * 255) ** 2
    mu_a, mu_b = a.mean(), b.mean()
    va, vb = a.var(), b.var()
    cov = np.mean((a - mu_a) * (b - mu_b))
    num = (2 * mu_a * mu_b + C1) * (2 * cov + C2)
    den = (mu_a ** 2 + mu_b ** 2 + C1) * (va + vb + C2)
    return num / den


def save_bmp(arr_uint8, path):
    """Save a uint8 array as BMP; falls back to .npy if PIL is absent."""
    try:
        from PIL import Image
        Image.fromarray(arr_uint8, mode="L").save(path)
        return path
    except ImportError:
        np.save(path.replace(".bmp", ".npy"), arr_uint8)
        return path.replace(".bmp", ".npy")


def main():
    meta = read_meta()
    H        = int(meta["H"])
    W        = int(meta["W"])
    K        = int(meta["K"])
    WIDTH    = int(meta["WIDTH"])
    n_out    = int(meta["n_out"])
    kmax     = float(meta["kmax"])
    flt      = meta.get("filter", "gaussian")

    # STREAM_LEN: read from result_meta.txt, which the RTL testbench writes
    # with the value it actually used -- guarantees the de-bias divisor matches.
    STREAM_LEN = 1024
    try:
        with open(f"{WORKDIR}/result_meta.txt") as f:
            for line in f:
                p = line.split()
                if len(p) == 2 and p[0] == "STREAM_LEN":
                    STREAM_LEN = int(p[1])
    except OSError:
        print("warning: result_meta.txt not found, assuming STREAM_LEN=1024")

    # ---- Read the hardware output -----------------------------------------
    try:
        nums = np.loadtxt(f"{WORKDIR}/gemm_out.txt", dtype=np.float64)
    except OSError:
        sys.exit("cannot read gemm_out.txt -- run the testbench first")
    if nums.size != n_out:
        print(f"warning: expected {n_out} values, got {nums.size}")

    # ---- Invert the encoding chain ----------------------------------------
    # Hardware gives, per pixel:  num  -> bipolar GEMM result  r_bip = num/L.
    #
    # r_bip = sum_k  enc_x(pixel_k) * enc_x(kernel_k)   in bipolar units,
    # where enc_x maps a real operand into [-1,1]. prep_im2col.py used:
    #   pixel_real_k  in [0,1]              (pixel / 255)
    #   kernel_real_k in [-1,1]             (kernel / kmax)
    # The bipolar product of two such operands equals the product of their
    # real values, so  r_bip = sum_k pixel01_k * (kernel_k / kmax).
    # The true convolution response is  conv = sum_k pixel01_k * kernel_k
    #                                        = r_bip * kmax.
    # Finally pixels were /255, so to compare in 8-bit units multiply by 255.
    r_bip = nums / float(STREAM_LEN)
    conv_hw = r_bip * kmax * 255.0            # hardware filter response, 8-bit scale
    conv_hw = conv_hw.reshape(H, W)

    # ---- Software golden reference ----------------------------------------
    img_in = np.load(f"{WORKDIR}/input_img.npy")          # uint8, HxW
    kern   = gaussian_kernel() if flt == "gaussian" else sobel_kernel()
    conv_sw = conv2d_zeropad(img_in.astype(np.float64), kern)   # 8-bit scale

    # ---- Map both responses to a displayable 8-bit image ------------------
    if flt == "sobel":
        # Sobel response is signed and its magnitude can far exceed 255.
        # A gradient image is conventionally NORMALISED, not clipped: scale so
        # the reference's peak magnitude maps to 255. The SAME scale factor is
        # applied to the hardware output so the comparison is fair.
        mag_sw = np.abs(conv_sw)
        mag_hw = np.abs(conv_hw)
        norm = mag_sw.max() if mag_sw.max() > 1e-6 else 1.0
        disp_sw = np.clip(mag_sw / norm * 255.0, 0, 255).astype(np.uint8)
        disp_hw = np.clip(mag_hw / norm * 255.0, 0, 255).astype(np.uint8)
    else:
        # Blur preserves the input range; a direct clip is correct.
        disp_hw = np.clip(conv_hw, 0, 255).astype(np.uint8)
        disp_sw = np.clip(conv_sw, 0, 255).astype(np.uint8)

    # ---- Scores ------------------------------------------------------------
    score_psnr = psnr(disp_sw, disp_hw)
    score_ssim = ssim(disp_sw, disp_hw)
    err = np.abs(conv_hw.reshape(-1) - conv_sw.reshape(-1))

    print("=======================================================")
    print(f"Stochastic GEMM image-processing score  ({flt})")
    print("=======================================================")
    print(f"  image            : {H}x{W}  ({n_out} pixels)")
    print(f"  STREAM_LEN        : {STREAM_LEN}")
    print(f"  PSNR  (hw vs sw)  : {score_psnr:.2f} dB")
    print(f"  SSIM  (hw vs sw)  : {score_ssim:.4f}")
    print(f"  mean abs error    : {err.mean():.3f}  (8-bit pixel units)")
    print(f"  max  abs error    : {err.max():.3f}")
    print(f"  error std dev     : {err.std():.3f}")
    print("=======================================================")

    # ---- Save output images ------------------------------------------------
    p_hw = save_bmp(disp_hw, f"{WORKDIR}/output_hw_{flt}.bmp")
    p_sw = save_bmp(disp_sw, f"{WORKDIR}/output_sw_{flt}.bmp")
    save_bmp(img_in, f"{WORKDIR}/input.bmp")
    print(f"  saved hardware image : {p_hw}")
    print(f"  saved golden image   : {p_sw}")

    # ---- Per-pixel stats CSV ----------------------------------------------
    csv_path = f"{WORKDIR}/stats_{flt}.csv"
    with open(csv_path, "w", newline="") as f:
        wtr = csv.writer(f)
        wtr.writerow(["pixel_index", "row", "col",
                      "sw_response", "hw_response", "abs_error"])
        for idx in range(n_out):
            r, c = idx // W, idx % W
            wtr.writerow([idx, r, c,
                          f"{conv_sw.reshape(-1)[idx]:.4f}",
                          f"{conv_hw.reshape(-1)[idx]:.4f}",
                          f"{err[idx]:.4f}"])
    print(f"  saved per-pixel CSV  : {csv_path}")

    # ---- Summary CSV (one row -- easy to append across sweeps) ------------
    summ_path = f"{WORKDIR}/summary.csv"
    import os
    new = not os.path.exists(summ_path)
    with open(summ_path, "a", newline="") as f:
        wtr = csv.writer(f)
        if new:
            wtr.writerow(["filter", "H", "W", "STREAM_LEN",
                          "psnr_db", "ssim", "mean_abs_err", "max_abs_err"])
        wtr.writerow([flt, H, W, STREAM_LEN,
                      f"{score_psnr:.3f}", f"{score_ssim:.4f}",
                      f"{err.mean():.4f}", f"{err.max():.4f}"])
    print(f"  appended summary     : {summ_path}")
    print("=======================================================")


if __name__ == "__main__":
    main()

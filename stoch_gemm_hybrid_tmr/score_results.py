#!/usr/bin/env python3
# =============================================================================
# score_results.py
#
# Compare the hardware GEMM output (gemm_out.txt) against a NumPy software
# reference for the same 3x3 convolution. Writes:
#   - output_hw_<filter>.bmp        : 24-bit grayscale render of HW result
#   - output_sw_<filter>.bmp        : 24-bit grayscale render of SW reference
#   - stats_<filter>.csv            : per-pixel comparison
#   - summary.csv                   : PSNR/SSIM/mean_err/max_err
#
# Inputs (looks for these in the current directory by default):
#   input.bmp        : the same BMP fed to the testbench
#   gemm_out.txt     : one signed c_flat value per line, H*W lines
#   kernel.txt       : K hex-encoded 16-bit bipolar SC kernel taps
#   meta.txt         : filter, H, W, K, WIDTH, n_out, kmax, pix_scale
#   result_meta.txt  : MODE, K, N, WIDTH, SCALING, STREAM_LEN, ...
#
# DECODE FIX (June 2026):
#   The old scoring code computed hw = c_flat * pix_scale * kmax / 2**W,
#   which is wrong by a factor of 2*K: c_flat is a SIGNED bipolar count
#   (range [-2^(W-1), +2^(W-1)]), not a raw unipolar count, and it represents
#   the K-tap sum of products, not a single product. The correct decode is:
#       hw = c_flat * K * pix_scale * kmax / 2^(W-1) / ksum_norm
#   For a Gaussian (kmax_norm=0.25, ksum_norm=1, K=9, W=16, pix_scale=255):
#       0.000973 -> 0.017509   (factor of 2*K = 18 recovered)
#   The testbench already writes the correct SCALING into result_meta.txt,
#   so this script prefers that value and only falls back to computing it
#   from first principles if result_meta.txt is missing SCALING.
# =============================================================================

import argparse
import math
import os
import struct
import sys
from pathlib import Path

import numpy as np


# --------------------------------------------------------------------------
# Metadata parsing -- the testbench writes "KEY VALUE" lines.
# --------------------------------------------------------------------------
def read_kv(path):
    """Parse simple 'KEY VALUE' files (meta.txt, result_meta.txt)."""
    d = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            d[parts[0]] = parts[1]
    return d


# --------------------------------------------------------------------------
# Kernel decode: kernel.txt holds K 16-bit hex words, each encoding a
# bipolar value via enc(x) = (x+1)/2 * 65536. The normalised kernel weight
# (the one used in software reference convolution) is then
#   kern_norm[k] = decode_bipolar(hex[k]) * kmax_norm
# where kmax_norm is the max(|kern_norm|) the testbench stored in meta.txt.
# --------------------------------------------------------------------------
def read_kernel(path, K, kmax_norm):
    raw = [int(line.strip(), 16) for line in Path(path).read_text().splitlines()
           if line.strip()]
    if len(raw) != K:
        raise ValueError(
            f"kernel.txt has {len(raw)} entries, expected K={K}")
    bipolar = [(v / 65536.0) * 2.0 - 1.0 for v in raw]
    kern = np.array([b * kmax_norm for b in bipolar], dtype=np.float64)
    return kern.reshape(3, 3)


# --------------------------------------------------------------------------
# BMP I/O -- use PIL if available, otherwise a minimal 24-bit reader/writer.
# --------------------------------------------------------------------------
def read_bmp_gray(path):
    """Return (H, W) float64 grayscale image in [0, 255]."""
    try:
        from PIL import Image
        img = Image.open(path).convert("L")
        return np.asarray(img, dtype=np.float64)
    except ImportError:
        pass

    # Minimal 24-bit BMP fallback (matches the testbench's writer).
    data = Path(path).read_bytes()
    if data[:2] != b"BM":
        raise ValueError(f"{path}: not a BMP file")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    W = struct.unpack_from("<i", data, 18)[0]
    H_signed = struct.unpack_from("<i", data, 22)[0]
    bpp = struct.unpack_from("<H", data, 28)[0]
    if bpp != 24:
        raise ValueError(f"{path}: only 24-bpp BMP supported, got {bpp}")

    H = abs(H_signed)
    flip_vertical = H_signed > 0          # positive height = bottom-up rows
    row_bytes = ((W * 3 + 3) // 4) * 4

    img = np.zeros((H, W), dtype=np.float64)
    for y in range(H):
        off = pixel_offset + y * row_bytes
        for x in range(W):
            b = data[off + x * 3 + 0]
            g = data[off + x * 3 + 1]
            r = data[off + x * 3 + 2]
            # Rec.601 luma (same as the testbench's BMP loader)
            img[y, x] = 0.299 * r + 0.587 * g + 0.114 * b
    if flip_vertical:
        img = img[::-1, :].copy()
    return img


def write_bmp_gray(path, arr):
    """Write a uint8 grayscale array as a 24-bit BMP (R=G=B)."""
    arr = np.clip(np.round(arr), 0, 255).astype(np.uint8)
    H, W = arr.shape

    try:
        from PIL import Image
        Image.fromarray(arr, mode="L").convert("RGB").save(str(path), format="BMP")
        return
    except ImportError:
        pass

    # Minimal 24-bit BMP writer.
    row_bytes = ((W * 3 + 3) // 4) * 4
    pad = row_bytes - W * 3
    pixel_data = bytearray()
    # BMP rows go bottom-up by convention.
    for y in range(H - 1, -1, -1):
        for x in range(W):
            v = int(arr[y, x])
            pixel_data += bytes((v, v, v))
        pixel_data += b"\x00" * pad

    file_size = 54 + len(pixel_data)
    header = bytearray()
    header += b"BM"
    header += struct.pack("<I", file_size)
    header += struct.pack("<HH", 0, 0)
    header += struct.pack("<I", 54)             # pixel data offset
    header += struct.pack("<I", 40)             # DIB header size
    header += struct.pack("<ii", W, H)
    header += struct.pack("<HH", 1, 24)         # planes, bpp
    header += struct.pack("<I", 0)              # no compression
    header += struct.pack("<I", len(pixel_data))
    header += struct.pack("<II", 2835, 2835)    # 72 dpi
    header += struct.pack("<II", 0, 0)          # colours used

    Path(path).write_bytes(bytes(header) + bytes(pixel_data))


# --------------------------------------------------------------------------
# Software reference: zero-padded 3x3 convolution. Matches what the
# testbench's im2col patches feed to the FPGA -- borders see zeros, every
# output pixel sees the 9 taps centred on it.
# --------------------------------------------------------------------------
def conv2d_zero_pad(img, kern):
    H, W = img.shape
    out = np.zeros((H, W), dtype=np.float64)
    padded = np.pad(img, 1, mode="constant", constant_values=0.0)
    for kr in range(3):
        for kc in range(3):
            out += kern[kr, kc] * padded[kr:kr + H, kc:kc + W]
    return out


# --------------------------------------------------------------------------
# Decode helpers.
# --------------------------------------------------------------------------
def compute_scaling(K, W, pix_scale, kmax_norm, ksum_norm):
    """Re-derive SCALING from first principles (sanity check / fallback)."""
    factor = K * pix_scale * kmax_norm / float(1 << (W - 1))
    if ksum_norm != 0:
        factor /= ksum_norm
    return factor


def decode_mode_for(kernel_weights):
    """For an averaging kernel (ksum != 0) decode as-is; otherwise abs()."""
    if abs(kernel_weights.sum()) > 1e-9:
        return "avg"
    return "edge"


# --------------------------------------------------------------------------
# Metrics.
# --------------------------------------------------------------------------
def psnr(ref, test, peak=255.0):
    mse = float(np.mean((ref - test) ** 2))
    if mse <= 0:
        return float("inf")
    return 20.0 * math.log10(peak / math.sqrt(mse))


def ssim_optional(ref, test):
    try:
        from skimage.metrics import structural_similarity as ssim
        return float(ssim(ref, test, data_range=255.0))
    except ImportError:
        return float("nan")


# --------------------------------------------------------------------------
# Main.
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Score the HW GEMM output against a SW convolution reference.")
    ap.add_argument("-d", "--dir", default="stoch_imgtest",
                    help="directory with the testbench outputs "
                         "(default: stoch_imgtest)")
    ap.add_argument("--gemm-out", default="gemm_out.txt")
    ap.add_argument("--input-bmp", default="input.bmp")
    ap.add_argument("--kernel", default="kernel.txt")
    ap.add_argument("--meta", default="meta.txt")
    ap.add_argument("--result-meta", default="result_meta.txt")
    ap.add_argument("--verify-scaling", action="store_true",
                    help="re-derive SCALING and check it matches result_meta")
    args = ap.parse_args()

    d = Path(args.dir)

    # ---- Read everything ------------------------------------------------
    meta   = read_kv(d / args.meta)
    rmeta  = read_kv(d / args.result_meta)

    filt       = meta.get("filter", "unknown")
    H          = int(meta["H"])
    W_img      = int(meta["W"])
    K          = int(meta["K"])
    width_bits = int(meta["WIDTH"])
    kmax_norm  = float(meta["kmax"])
    pix_scale  = float(meta.get("pix_scale", 255.0))

    if K != 9:
        sys.exit(f"score_results.py only supports K=9 (3x3); got K={K}")

    kern = read_kernel(d / args.kernel, K, kmax_norm)
    ksum_norm = float(kern.sum())                # ~1.0 for blur, ~0 for edges

    # SCALING: prefer the value the testbench computed.
    if "SCALING" in rmeta:
        scaling = float(rmeta["SCALING"])
        scaling_src = "result_meta.txt"
    else:
        scaling = compute_scaling(K, width_bits, pix_scale, kmax_norm,
                                  ksum_norm if abs(ksum_norm) > 1e-9 else 1.0)
        scaling_src = "derived locally"

    if args.verify_scaling:
        derived = compute_scaling(K, width_bits, pix_scale, kmax_norm,
                                  ksum_norm if abs(ksum_norm) > 1e-9 else 1.0)
        print(f"SCALING from result_meta: {scaling:.8f}")
        print(f"SCALING derived locally : {derived:.8f}")
        if not math.isclose(scaling, derived, rel_tol=1e-3):
            print("  WARNING: derived SCALING disagrees by >0.1%")

    # ---- Software reference --------------------------------------------
    in_img = read_bmp_gray(d / args.input_bmp)
    if in_img.shape != (H, W_img):
        sys.exit(f"input.bmp is {in_img.shape}, meta.txt says ({H},{W_img})")

    sw = conv2d_zero_pad(in_img, kern)

    # ---- Hardware decode ------------------------------------------------
    c_flat = np.loadtxt(d / args.gemm_out, dtype=np.int64)
    if c_flat.size != H * W_img:
        sys.exit(f"{args.gemm_out} has {c_flat.size} samples, "
                 f"expected H*W = {H * W_img}")
    hw = c_flat.reshape(H, W_img).astype(np.float64) * scaling

    decode_mode = decode_mode_for(kern)
    if decode_mode == "edge":
        # Edge-detector display: absolute value.
        hw_disp = np.abs(hw)
        sw_disp = np.abs(sw)
    else:
        # Averaging filter display: clamp to [0, 255].
        hw_disp = hw.copy()
        sw_disp = sw.copy()
    hw_disp_clamped = np.clip(hw_disp, 0, 255)
    sw_disp_clamped = np.clip(sw_disp, 0, 255)

    # ---- Write BMPs -----------------------------------------------------
    out_hw_bmp = d / f"output_hw_{filt}.bmp"
    out_sw_bmp = d / f"output_sw_{filt}.bmp"
    write_bmp_gray(out_hw_bmp, hw_disp_clamped)
    write_bmp_gray(out_sw_bmp, sw_disp_clamped)

    # ---- Stats CSV (per pixel) -----------------------------------------
    stats_path = d / f"stats_{filt}.csv"
    with stats_path.open("w", newline="") as f:
        f.write("pixel_index,row,col,sw_response,hw_response,abs_error\r\n")
        sw_flat = sw.reshape(-1)
        hw_flat = hw.reshape(-1)
        for idx in range(H * W_img):
            r, c = divmod(idx, W_img)
            s = float(sw_flat[idx])
            h = float(hw_flat[idx])
            f.write(f"{idx},{r},{c},{s:.4f},{h:.4f},{abs(s - h):.4f}\r\n")

    # ---- Summary CSV ----------------------------------------------------
    abs_err = np.abs(sw - hw)
    summary_path = d / "summary.csv"
    psnr_db    = psnr(sw_disp_clamped, hw_disp_clamped)
    ssim_score = ssim_optional(sw_disp_clamped, hw_disp_clamped)
    stream_len = int(rmeta.get("STREAM_LEN", 0))
    with summary_path.open("w", newline="") as f:
        f.write("filter,H,W,STREAM_LEN,psnr_db,ssim,mean_abs_err,max_abs_err\r\n")
        f.write(f"{filt},{H},{W_img},{stream_len},"
                f"{psnr_db:.3f},{ssim_score:.4f},"
                f"{abs_err.mean():.4f},{abs_err.max():.4f}\r\n")

    # ---- Console report -------------------------------------------------
    print(f"=== score_results.py ({filt}) ===")
    print(f"  image       : {H} x {W_img}")
    print(f"  SCALING     : {scaling:.6f}  [{scaling_src}]")
    print(f"  decode mode : {decode_mode}")
    print(f"  PSNR        : {psnr_db:.3f} dB")
    if not math.isnan(ssim_score):
        print(f"  SSIM        : {ssim_score:.4f}")
    print(f"  mean |err|  : {abs_err.mean():.4f}")
    print(f"  max  |err|  : {abs_err.max():.4f}")
    print(f"  wrote       : {out_hw_bmp.name}, {out_sw_bmp.name}")
    print(f"                {stats_path.name}, {summary_path.name}")

    # ---- Smoke check ----------------------------------------------------
    # On a properly decoded run the ratio sw / hw should sit close to 1.
    # The pre-fix script gave ~18; flag anything >= 2 as suspicious.
    nz = sw_disp_clamped > 5.0
    if nz.any():
        ratio = sw_disp_clamped[nz] / np.maximum(hw_disp_clamped[nz], 0.1)
        med = float(np.median(ratio))
        if med > 2.0 or med < 0.5:
            print(f"\n  WARNING: median sw/hw ratio = {med:.2f}")
            print(f"           (expected ~1.0; the pre-fix scoring gave ~18)")


if __name__ == "__main__":
    main()

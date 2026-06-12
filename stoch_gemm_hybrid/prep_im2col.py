#!/usr/bin/env python3
# =============================================================================
# prep_im2col.py
# Pre-processing stage of the stochastic-GEMM image-processing harness.
#
# Pipeline role:
#   BMP/synthetic image  ->  grayscale  ->  im2col lowering  ->  text files
#   that the SystemVerilog testbench (tb_stoch_image.sv) reads with $readmemh.
#
# What it does
#   1. Loads an 8-bit grayscale image from a BMP file (required: --bmp PATH).
#      Colour BMPs are converted to grayscale; --resize N optionally shrinks
#      the image to NxN to keep simulation time manageable.
#   2. Zero-pads the image so the convolution output is the same size as input.
#   3. Performs im2col: every 3x3 neighbourhood becomes one K=9 column.
#   4. Writes, for the chosen filter, the data the hardware needs:
#        - patches.txt : the im2col activation matrix, one hex value per line
#        - kernel.txt  : the 3x3 filter, flattened, one hex value per line
#        - meta.txt    : dimensions and scaling info for the other stages
#
# Value encoding (must match the stochastic GEMM's expectations)
#   stoch_gemm_top consumes OFFSET-ENCODED operands: a WIDTH-bit unsigned value
#   v_enc represents the bipolar real value  x = 2*(v_enc / 2^WIDTH) - 1, i.e.
#   v_enc = round((x + 1)/2 * 2^WIDTH).  Both pixels and kernel taps are mapped
#   into the real range [-1, +1] first, then offset-encoded here so the
#   testbench can feed them directly.
#
# Range discipline
#   A K=9 GEMM result lies in [-9, +9] in bipolar units. Pixels are mapped to
#   [0,1] (a sub-range of [-1,1]); kernel taps are scaled so the worst-case
#   filter response cannot leave [-1,1] per tap. meta.txt records every scale
#   factor so post-processing can invert the chain exactly.
#
# Usage
#   python3 prep_im2col.py --filter gaussian --bmp myimage.bmp  [--resize 64]
#   python3 prep_im2col.py --filter sobel    --bmp myimage.bmp  [--resize 64]
#
# Or run the whole blur-then-Sobel flow with: ./run_image_test.sh myimage.bmp
# =============================================================================

import argparse
import os
import sys
import numpy as np

WIDTH = 16          # operand bit-width: must match tb_stoch_image.sv WIDTH
K     = 9           # 3x3 kernel -> contraction depth 9


def load_bmp(path):
    """Load a BMP as 8-bit grayscale via PIL."""
    try:
        from PIL import Image
    except ImportError:
        sys.exit("PIL/Pillow required to read BMP input -- install pillow")
    try:
        im = Image.open(path).convert("L")          # 'L' = 8-bit grayscale
    except FileNotFoundError:
        sys.exit(f"input image not found: {path}")
    return np.asarray(im, dtype=np.uint8)


def gaussian_kernel():
    """3x3 Gaussian blur. Taps are positive and sum to 1 (range-safe)."""
    k = np.array([[1, 2, 1],
                  [2, 4, 2],
                  [1, 2, 1]], dtype=np.float64)
    return k / k.sum()


def sobel_kernel():
    """3x3 Sobel-X edge kernel. Has NEGATIVE taps -> exercises bipolar mode."""
    return np.array([[-1, 0, 1],
                     [-2, 0, 2],
                     [-1, 0, 1]], dtype=np.float64)


def offset_encode(x_real):
    """Map real x in [-1,1] to a WIDTH-bit unsigned offset code."""
    q = np.round((x_real + 1.0) / 2.0 * (2 ** WIDTH))
    q = np.clip(q, 0, (2 ** WIDTH) - 1)
    return q.astype(np.uint64)


def main():
    ap = argparse.ArgumentParser(
        description="im2col preprocessing for the stochastic-GEMM image harness")
    ap.add_argument("--filter", choices=["gaussian", "sobel"], required=True)
    ap.add_argument("--bmp", required=True,
                    help="path to the input BMP image (8-bit or colour; "
                         "converted to grayscale)")
    ap.add_argument("--resize", type=int, default=0,
                    help="optional: resize the image to NxN before processing "
                         "(0 = keep original size). Useful to keep simulation "
                         "time manageable -- conversion time scales with pixel "
                         "count.")
    ap.add_argument("--outdir", default="stoch_imgtest")
    args = ap.parse_args()

    # ---- Load image --------------------------------------------------------
    img = load_bmp(args.bmp)
    print(f"loaded BMP {args.bmp}  shape={img.shape}")
    if args.resize > 0:
        try:
            from PIL import Image
            img = np.asarray(
                Image.fromarray(img).resize((args.resize, args.resize)),
                dtype=np.uint8)
            print(f"resized to {img.shape}")
        except ImportError:
            sys.exit("PIL required for --resize")
    H, Wd = img.shape

    # ---- Kernel + scaling --------------------------------------------------
    if args.filter == "gaussian":
        kern = gaussian_kernel()
    else:
        kern = sobel_kernel()

    # Pixels: 8-bit [0,255] -> real [0,1] (a positive sub-range of [-1,1]).
    pix = img.astype(np.float64) / 255.0

    # Kernel taps must sit in [-1,1]. Scale by the max absolute tap so the
    # largest-magnitude tap maps to +/-1; record the factor for inversion.
    kmax = np.max(np.abs(kern))
    kern_scaled = kern / kmax            # now every tap in [-1,1]

    # ---- Zero-pad so output size == input size ----------------------------
    pad = 1                               # 3x3 kernel -> 1-pixel border
    padded = np.zeros((H + 2 * pad, Wd + 2 * pad), dtype=np.float64)
    padded[pad:pad + H, pad:pad + Wd] = pix

    # ---- im2col : every 3x3 neighbourhood -> one length-9 column ----------
    # Row-major flatten of each patch; column index = output pixel index.
    n_out = H * Wd
    patches = np.zeros((K, n_out), dtype=np.float64)
    idx = 0
    for r in range(H):
        for c in range(Wd):
            patch = padded[r:r + 3, c:c + 3].reshape(-1)   # length 9
            patches[:, idx] = patch
            idx += 1

    # ---- Offset-encode operands -------------------------------------------
    patches_enc = offset_encode(patches)                   # K x n_out
    kernel_enc  = offset_encode(kern_scaled.reshape(-1))    # length 9

    # ---- Write hex files for the testbench --------------------------------
    od = args.outdir
    os.makedirs(od, exist_ok=True)         # create stoch_imgtest/ if absent
    # patches.txt : row-major, K rows then n_out cols (patches_enc[k][p])
    with open(f"{od}/patches.txt", "w") as f:
        for k in range(K):
            for p in range(n_out):
                f.write(f"{int(patches_enc[k, p]):0{WIDTH//4}x}\n")
    with open(f"{od}/kernel.txt", "w") as f:
        for k in range(K):
            f.write(f"{int(kernel_enc[k]):0{WIDTH//4}x}\n")

    # meta.txt : human-readable, used by score_results.py
    with open(f"{od}/meta.txt", "w") as f:
        f.write(f"filter {args.filter}\n")
        f.write(f"H {H}\n")
        f.write(f"W {Wd}\n")
        f.write(f"K {K}\n")
        f.write(f"WIDTH {WIDTH}\n")
        f.write(f"n_out {n_out}\n")
        f.write(f"kmax {kmax:.10f}\n")            # kernel scale factor
        f.write(f"pix_scale 255.0\n")             # pixel scale factor

    # meta_tb.txt : integers only, in fixed order, for the SystemVerilog
    # testbench ($fscanf of strings is unreliable in some simulators).
    # Order: H  W  K  WIDTH  n_out
    with open(f"{od}/meta_tb.txt", "w") as f:
        f.write(f"{H} {Wd} {K} {WIDTH} {n_out}\n")

    # Save the input image too, so post-processing can score against it.
    np.save(f"{od}/input_img.npy", img)
    np.save(f"{od}/kernel_raw.npy", kern)

    print(f"filter      : {args.filter}")
    print(f"image       : {H}x{Wd}  ({n_out} output pixels)")
    print(f"im2col      : {K} x {n_out} activation matrix")
    print(f"kernel kmax : {kmax:.4f}")
    print(f"wrote       : {od}/patches.txt, kernel.txt, meta.txt")


if __name__ == "__main__":
    main()

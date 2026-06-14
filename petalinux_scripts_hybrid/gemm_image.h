// =============================================================================
// gemm_image.h
// Common types and constants used across the gemm-image library.
// =============================================================================
#ifndef GEMM_IMAGE_H
#define GEMM_IMAGE_H

#include <stdint.h>

// 3x3 convolution: the entire library is hard-wired to K=9 because the FPGA
// wrapper expects exactly 9 input terms per tile. Larger kernels would need a
// different bitstream.
#define K 9

// Position offsets for the 9 kernel taps (NW N NE W C E SW S SE).
extern const int gemm_dr[K];
extern const int gemm_dc[K];

// How a raw c_flat value from the FPGA gets mapped to a uint8 output pixel.
enum decode_mode {
    DECODE_AVG,        // pixel = clamp(signed_result, 0, 255)
    DECODE_EDGE,       // pixel = clamp(|signed_result|, 0, 255)
    DECODE_OFFSET,     // pixel = clamp(signed_result + 128, 0, 255) (emboss)
    DECODE_MAGNITUDE,  // two parallel passes -> sqrt(a^2 + b^2)
    DECODE_PIPELINE    // two sequential passes -> stage A then stage B
};

// Display-only grouping for the --list output.
enum category {
    CAT_SMOOTH,
    CAT_SHARPEN,
    CAT_EDGE_AXIS,
    CAT_EDGE_OMNI,
    CAT_LINE,
    CAT_EMBOSS,
    CAT_MAGNITUDE,
    CAT_SPECIAL
};

// One entry in the kernel library.
struct kernel_def {
    const char       *name;        // command-line name
    enum category     cat;
    enum decode_mode  mode;

    // Single-pass weights (unused when mode is MAGNITUDE / PIPELINE).
    double            w[K];
    double            kmax;        // max(|w[k]|) -- weights normalised by this
    double            ksum;        // sum(w[k])  -- ksum=0 marks edge detectors

    // Two-pass component / stage kernels.
    //   MAGNITUDE: pass_a/pass_b are the two parallel components.
    //   PIPELINE : pass_a/pass_b are stage 1 / stage 2 (sequential).
    const char       *pass_a;
    const char       *pass_b;

    // If 1 (only meaningful for MAGNITUDE), the input is Gaussian-blurred
    // before the magnitude components are computed -- used by `canny` for the
    // gradient stage of the Canny edge detector.
    int               preblur;

    const char       *desc;        // shown by --list
};

#endif  // GEMM_IMAGE_H

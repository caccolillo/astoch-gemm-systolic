// =============================================================================
// kernels.c
// The full library of 30 single-pass 3x3 kernels + 5 multi-pass operations,
// grouped by category for the --list output. Also implements the SC encode
// and signed-decode helpers used by the FPGA driver.
//
// Multi-pass operations (mode == DECODE_MAGNITUDE or DECODE_PIPELINE) are
// dispatched by main.c, not by this file. Their pass_a / pass_b fields
// reference other entries in this same library by name.
// =============================================================================
#include "kernels.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

const int gemm_dr[K] = {-1,-1,-1,  0, 0, 0,  1, 1, 1};
const int gemm_dc[K] = {-1, 0, 1, -1, 0, 1, -1, 0, 1};

const struct kernel_def gemm_kernels[] = {

    // ============ Smoothing ===============================================
    {.name="blur",       .cat=CAT_SMOOTH, .mode=DECODE_AVG,
     .w={1,2,1, 2,4,2, 1,2,1}, .kmax=4.0,  .ksum=16.0,
     .desc="Gaussian 3x3 low-pass blur"},

    {.name="binomial",   .cat=CAT_SMOOTH, .mode=DECODE_AVG,
     .w={1,2,1, 2,4,2, 1,2,1}, .kmax=4.0,  .ksum=16.0,
     .desc="3x3 binomial filter (= Gaussian via binomial coefficients)"},

    {.name="boxblur",    .cat=CAT_SMOOTH, .mode=DECODE_AVG,
     .w={1,1,1, 1,1,1, 1,1,1}, .kmax=1.0,  .ksum=9.0,
     .desc="Uniform 3x3 box average"},

    {.name="motionblur_h", .cat=CAT_SMOOTH, .mode=DECODE_AVG,
     .w={0,0,0, 1,1,1, 0,0,0}, .kmax=1.0,  .ksum=3.0,
     .desc="Horizontal motion blur (3-tap row)"},

    {.name="motionblur_v", .cat=CAT_SMOOTH, .mode=DECODE_AVG,
     .w={0,1,0, 0,1,0, 0,1,0}, .kmax=1.0,  .ksum=3.0,
     .desc="Vertical motion blur (3-tap column)"},

    // ============ Sharpening ==============================================
    {.name="sharpen",    .cat=CAT_SHARPEN, .mode=DECODE_AVG,
     .w={0,-1,0, -1,5,-1, 0,-1,0}, .kmax=5.0, .ksum=1.0,
     .desc="Gentle sharpen / edge enhancement (Laplacian-subtraction)"},

    {.name="unsharp",    .cat=CAT_SHARPEN, .mode=DECODE_AVG,
     .w={-1,-1,-1, -1,9,-1, -1,-1,-1}, .kmax=9.0, .ksum=1.0,
     .desc="Aggressive 8-neighbour unsharp mask"},

    {.name="highboost",  .cat=CAT_SHARPEN, .mode=DECODE_AVG,
     .w={-1,-1,-1, -1,12,-1, -1,-1,-1}, .kmax=12.0, .ksum=4.0,
     .desc="High-boost filter (boosted unsharp)"},

    // ============ Edge detection -- single axis ===========================
    {.name="sobelx",     .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={-1,0,1, -2,0,2, -1,0,1}, .kmax=2.0, .ksum=0.0,
     .desc="Sobel horizontal gradient (Gx)"},

    {.name="sobely",     .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={-1,-2,-1, 0,0,0, 1,2,1}, .kmax=2.0, .ksum=0.0,
     .desc="Sobel vertical gradient (Gy)"},

    {.name="prewittx",   .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={-1,0,1, -1,0,1, -1,0,1}, .kmax=1.0, .ksum=0.0,
     .desc="Prewitt horizontal gradient"},

    {.name="prewitty",   .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={-1,-1,-1, 0,0,0, 1,1,1}, .kmax=1.0, .ksum=0.0,
     .desc="Prewitt vertical gradient"},

    {.name="scharrx",    .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={-3,0,3, -10,0,10, -3,0,3}, .kmax=10.0, .ksum=0.0,
     .desc="Scharr horizontal (improved isotropy)"},

    {.name="scharry",    .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={-3,-10,-3, 0,0,0, 3,10,3}, .kmax=10.0, .ksum=0.0,
     .desc="Scharr vertical (improved isotropy)"},

    {.name="robertsx",   .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={0,0,0, 0,1,0, 0,0,-1}, .kmax=1.0, .ksum=0.0,
     .desc="Roberts cross +diagonal (2x2 anchored top-left)"},

    {.name="robertsy",   .cat=CAT_EDGE_AXIS, .mode=DECODE_EDGE,
     .w={0,0,0, 0,0,1, 0,-1,0}, .kmax=1.0, .ksum=0.0,
     .desc="Roberts cross -diagonal (2x2 anchored top-right)"},

    // ============ Edge detection -- omnidirectional =======================
    {.name="laplacian",  .cat=CAT_EDGE_OMNI, .mode=DECODE_EDGE,
     .w={0,1,0, 1,-4,1, 0,1,0}, .kmax=4.0, .ksum=0.0,
     .desc="4-neighbour Laplacian (2nd-derivative edge detector)"},

    {.name="laplacian_d", .cat=CAT_EDGE_OMNI, .mode=DECODE_EDGE,
     .w={1,1,1, 1,-8,1, 1,1,1}, .kmax=8.0, .ksum=0.0,
     .desc="8-neighbour Laplacian (includes diagonals)"},

    {.name="dog",        .cat=CAT_EDGE_OMNI, .mode=DECODE_EDGE,
     .w={1,2,1, 2,-12,2, 1,2,1}, .kmax=12.0, .ksum=0.0,
     .desc="Difference of Gaussians (3x3 approximation, blur - 16*identity)"},

    {.name="edges",      .cat=CAT_EDGE_OMNI, .mode=DECODE_EDGE,
     .w={-1,-1,-1, -1,8,-1, -1,-1,-1}, .kmax=8.0, .ksum=0.0,
     .desc="Strong omnidirectional edge map (8-neighbour high-pass)"},

    // ============ Line detection ==========================================
    {.name="line_h",     .cat=CAT_LINE, .mode=DECODE_EDGE,
     .w={-1,-1,-1, 2,2,2, -1,-1,-1}, .kmax=2.0, .ksum=0.0,
     .desc="Detect horizontal lines (1-pixel wide)"},

    {.name="line_v",     .cat=CAT_LINE, .mode=DECODE_EDGE,
     .w={-1,2,-1, -1,2,-1, -1,2,-1}, .kmax=2.0, .ksum=0.0,
     .desc="Detect vertical lines (1-pixel wide)"},

    {.name="line_d1",    .cat=CAT_LINE, .mode=DECODE_EDGE,
     .w={2,-1,-1, -1,2,-1, -1,-1,2}, .kmax=2.0, .ksum=0.0,
     .desc="Detect diagonal lines (top-left to bottom-right, \\)"},

    {.name="line_d2",    .cat=CAT_LINE, .mode=DECODE_EDGE,
     .w={-1,-1,2, -1,2,-1, 2,-1,-1}, .kmax=2.0, .ksum=0.0,
     .desc="Detect diagonal lines (bottom-left to top-right, /)"},

    // ============ Embossing ===============================================
    {.name="emboss",     .cat=CAT_EMBOSS, .mode=DECODE_OFFSET,
     .w={-2,-1,0, -1,0,1, 0,1,2}, .kmax=2.0, .ksum=0.0,
     .desc="Emboss along NW-SE diagonal (3D relief look)"},

    {.name="emboss_se",  .cat=CAT_EMBOSS, .mode=DECODE_OFFSET,
     .w={0,1,2, -1,0,1, -2,-1,0}, .kmax=2.0, .ksum=0.0,
     .desc="Emboss along SW-NE diagonal (opposite light direction)"},

    {.name="emboss_n",   .cat=CAT_EMBOSS, .mode=DECODE_OFFSET,
     .w={-1,-2,-1, 0,0,0, 1,2,1}, .kmax=2.0, .ksum=0.0,
     .desc="Emboss along N-S axis (vertical relief)"},

    {.name="emboss_w",   .cat=CAT_EMBOSS, .mode=DECODE_OFFSET,
     .w={1,0,-1, 2,0,-2, 1,0,-1}, .kmax=2.0, .ksum=0.0,
     .desc="Emboss along W-E axis (horizontal relief)"},

    // ============ Multi-pass operations ===================================
    {.name="sobel",      .cat=CAT_MAGNITUDE, .mode=DECODE_MAGNITUDE,
     .pass_a="sobelx", .pass_b="sobely",
     .desc="Sobel edge magnitude: sqrt(Gx^2 + Gy^2)"},

    {.name="prewitt",    .cat=CAT_MAGNITUDE, .mode=DECODE_MAGNITUDE,
     .pass_a="prewittx", .pass_b="prewitty",
     .desc="Prewitt edge magnitude"},

    {.name="scharr",     .cat=CAT_MAGNITUDE, .mode=DECODE_MAGNITUDE,
     .pass_a="scharrx", .pass_b="scharry",
     .desc="Scharr edge magnitude (best balance of accuracy/cost)"},

    {.name="roberts",    .cat=CAT_MAGNITUDE, .mode=DECODE_MAGNITUDE,
     .pass_a="robertsx", .pass_b="robertsy",
     .desc="Roberts cross edge magnitude (2 FPGA passes)"},

    {.name="log",        .cat=CAT_MAGNITUDE, .mode=DECODE_PIPELINE,
     .pass_a="blur", .pass_b="laplacian",
     .desc="Laplacian of Gaussian: blur, then Laplacian (2 FPGA passes)"},

    {.name="canny",      .cat=CAT_MAGNITUDE, .mode=DECODE_MAGNITUDE,
     .pass_a="sobelx", .pass_b="sobely", .preblur=1,
     .desc="Canny gradient stage: blur + Sobel magnitude (3 FPGA passes)"},

    // ============ Special =================================================
    {.name="identity",   .cat=CAT_SPECIAL, .mode=DECODE_AVG,
     .w={0,0,0, 0,1,0, 0,0,0}, .kmax=1.0, .ksum=1.0,
     .desc="Identity (sanity check; output should match grayscale input)"},

    // Sentinel
    {NULL, 0, 0, {0}, 0, 0, NULL, NULL, 0, NULL}
};

static const char *category_names[] = {
    "Smoothing",
    "Sharpening",
    "Edge detection (single axis)",
    "Edge detection (omnidirectional)",
    "Line detection",
    "Embossing",
    "Multi-pass operations (runs FPGA more than once)",
    "Special"
};

const struct kernel_def *kernel_find(const char *name)
{
    for (int i = 0; gemm_kernels[i].name; i++)
        if (strcmp(gemm_kernels[i].name, name) == 0)
            return &gemm_kernels[i];
    return NULL;
}

void kernel_list_all(void)
{
    // Count kernels for the header line.
    int n_total = 0, n_multipass = 0;
    for (int i = 0; gemm_kernels[i].name; i++) {
        n_total++;
        if (gemm_kernels[i].mode == DECODE_MAGNITUDE ||
            gemm_kernels[i].mode == DECODE_PIPELINE)
            n_multipass++;
    }
    fprintf(stderr, "Available kernels (%d total: %d single-pass, %d multi-pass):\n\n",
            n_total, n_total - n_multipass, n_multipass);
    for (int c = 0; c <= CAT_SPECIAL; c++) {
        int any = 0;
        for (int i = 0; gemm_kernels[i].name; i++) {
            if (gemm_kernels[i].cat == c) {
                if (!any) {
                    fprintf(stderr, "  %s:\n", category_names[c]);
                    any = 1;
                }
                fprintf(stderr, "    %-13s  %s\n",
                        gemm_kernels[i].name, gemm_kernels[i].desc);
            }
        }
        if (any) fprintf(stderr, "\n");
    }
}

uint16_t kernel_enc(double x)
{
    int q = (int)((x + 1.0) / 2.0 * 65536.0 + (x >= 0 ? 0.5 : -0.5));
    if (q < 0) q = 0;
    if (q > 0xFFFF) q = 0xFFFF;
    return (uint16_t)q;
}

double kernel_decode_signed(int32_t cf,
                            const struct kernel_def *kern,
                            int hw_kw)
{
    double base = (double)cf * K * 255.0 * kern->kmax
                / (double)(1 << (hw_kw - 1));
    if (kern->ksum != 0.0)
        return base / kern->ksum;
    return base;
}

uint8_t kernel_signed_to_pixel(double v, enum decode_mode mode)
{
    switch (mode) {
        case DECODE_AVG:                          break;
        case DECODE_EDGE:      v = fabs(v);       break;
        case DECODE_OFFSET:    v = v + 128.0;     break;
        case DECODE_MAGNITUDE: /* fallthrough */
        case DECODE_PIPELINE:  /* handled by caller */ break;
    }
    if (v < 0)   v = 0;
    if (v > 255) v = 255;
    return (uint8_t)(v + 0.5);
}

// =============================================================================
// gemm_image_main.c
// Main entry point for the gemm-image library demo. Wires together:
//   - bmp.c     : input/output BMP I/O
//   - fpga.c    : UIO + DMA + AXI-Lite control of the GEMM accelerator
//   - kernels.c : the 35-entry kernel library and SC encode/decode helpers
//
// Modes handled here:
//   SINGLE-PASS  (AVG / EDGE / OFFSET)
//     one run_pass call, then map signed result via kernel_signed_to_pixel().
//
//   MAGNITUDE    (sobel, prewitt, scharr, roberts, canny)
//     two run_pass calls for the two parallel components. If preblur=1
//     (canny), an additional pass blurs the input first.
//
//   PIPELINE     (log)
//     two run_pass calls in sequence -- pass A's output is quantised back
//     to uint8 and fed into pass B.
// =============================================================================
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "gemm_image.h"
#include "bmp.h"
#include "fpga.h"
#include "kernels.h"

// ----------------------------------------------------------------------------
// Run one full pass of the FPGA across the whole image with a single-pass
// kernel. Fills signed_out[0..H*W-1] with decoded signed values.
// ----------------------------------------------------------------------------
static int run_pass(struct fpga_ctx *ctx,
                    const struct kernel_def *kern,
                    const uint8_t *in_img, int H, int W,
                    float *signed_out,
                    const char *progress_label)
{
    if (kern->mode == DECODE_MAGNITUDE || kern->mode == DECODE_PIPELINE) {
        fprintf(stderr, "internal: run_pass called with multi-pass kernel\n");
        return -1;
    }

    uint16_t kenc[K];
    for (int k = 0; k < K; k++)
        kenc[k] = kernel_enc(kern->w[k] / kern->kmax);

    int n_tiles = (H * W + ctx->hw_n - 1) / ctx->hw_n;
    int32_t *raw = malloc((size_t)ctx->hw_n * sizeof(int32_t));
    if (!raw) { perror("malloc raw"); return -1; }

    int progress_step = (n_tiles + 19) / 20;
    if (progress_step < 1) progress_step = 1;

    for (int t = 0; t < n_tiles; t++) {
        int tile_base = t * ctx->hw_n;
        if (fpga_process_tile(ctx, tile_base, H, W, in_img, kenc, raw) < 0) {
            free(raw); return -1;
        }
        for (int i = 0; i < ctx->hw_n; i++) {
            int p = tile_base + i;
            if (p < H * W)
                signed_out[p] = (float)kernel_decode_signed(raw[i], kern,
                                                            ctx->hw_kw);
        }
        if ((t % progress_step) == 0) {
            printf("  %s: tile %5d / %d (%3d%%)\r",
                   progress_label, t, n_tiles, (int)(100.0 * t / n_tiles));
            fflush(stdout);
        }
    }
    printf("  %s: tile %5d / %d (100%%)\n",
           progress_label, n_tiles, n_tiles);
    free(raw);
    return 0;
}

// ----------------------------------------------------------------------------
// Convenience: run a single-pass kernel and write its uint8-quantised output
// into an intermediate buffer (used by preblur and the PIPELINE first stage).
// ----------------------------------------------------------------------------
static int run_pass_to_uint8(struct fpga_ctx *ctx,
                             const struct kernel_def *kern,
                             const uint8_t *in_img, int H, int W,
                             uint8_t *uint8_out,
                             const char *progress_label)
{
    float *tmp = malloc((size_t)H * W * sizeof(float));
    if (!tmp) { perror("malloc tmp"); return -1; }
    if (run_pass(ctx, kern, in_img, H, W, tmp, progress_label) < 0) {
        free(tmp); return -1;
    }
    for (int p = 0; p < H * W; p++)
        uint8_out[p] = kernel_signed_to_pixel(tmp[p], kern->mode);
    free(tmp);
    return 0;
}

// ----------------------------------------------------------------------------
// CLI
// ----------------------------------------------------------------------------
static void usage(const char *prog)
{
    fprintf(stderr,
        "gemm-image -- FPGA-accelerated 3x3 image convolution library\n\n"
        "Usage:\n"
        "  %s input.bmp output.bmp [kernel]\n"
        "  %s --list\n\n"
        "  Default kernel: sobel (two-pass magnitude)\n\n",
        prog, prog);
    kernel_list_all();
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--list") == 0) {
        kernel_list_all();
        return 0;
    }
    if (argc < 3 || argc > 4) { usage(argv[0]); return 1; }

    const char *in_path  = argv[1];
    const char *out_path = argv[2];
    const char *kname    = (argc == 4) ? argv[3] : "sobel";

    const struct kernel_def *kern = kernel_find(kname);
    if (!kern) {
        fprintf(stderr, "Unknown kernel '%s'\n\n", kname);
        kernel_list_all();
        return 1;
    }

    printf("=== Stochastic GEMM image processor (HYBRID) ===\n");
    printf("  input  : %s\n", in_path);
    printf("  output : %s\n", out_path);
    printf("  kernel : %s  (%s)\n", kern->name, kern->desc);
    if (kern->mode == DECODE_MAGNITUDE) {
        if (kern->preblur)
            printf("  passes : 3 (blur, then %s + %s combined via sqrt(a^2+b^2))\n",
                   kern->pass_a, kern->pass_b);
        else
            printf("  passes : 2 (component %s + %s, combined via sqrt(a^2+b^2))\n",
                   kern->pass_a, kern->pass_b);
    } else if (kern->mode == DECODE_PIPELINE) {
        printf("  passes : 2 (sequential: %s, then %s on the result)\n",
               kern->pass_a, kern->pass_b);
    }

    // Read input
    uint8_t *in_img = NULL;
    int H = 0, W = 0;
    if (bmp_read_gray(in_path, &in_img, &H, &W) < 0) return 1;
    printf("  image  : %d x %d grayscale\n", W, H);

    uint8_t *out_img = malloc((size_t)H * W);
    if (!out_img) { perror("malloc out_img"); free(in_img); return 1; }

    // FPGA setup
    struct fpga_ctx ctx;
    if (fpga_open(&ctx) < 0) return 1;
    int n_tiles = (H * W + ctx.hw_n - 1) / ctx.hw_n;
    printf("  HW     : N=%d KW=%d %s SLR=%d\n",
           ctx.hw_n, ctx.hw_kw, ctx.is_hybrid ? "HYBRID" : "PLAIN", ctx.hw_slr);
    printf("  tiles  : %d (= ceil(%d / %d))\n", n_tiles, H*W, ctx.hw_n);
    if (fpga_configure(&ctx) < 0) return 1;

    // Process
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int total_tiles = n_tiles;

    printf("\n");
    if (kern->mode == DECODE_MAGNITUDE) {
        const struct kernel_def *kern_a = kernel_find(kern->pass_a);
        const struct kernel_def *kern_b = kernel_find(kern->pass_b);
        if (!kern_a || !kern_b) {
            fprintf(stderr, "internal: missing component kernel\n");
            return 1;
        }

        // Optional pre-blur stage (canny gradient).
        const uint8_t *mag_in = in_img;
        uint8_t *preblurred = NULL;
        if (kern->preblur) {
            const struct kernel_def *kern_blur = kernel_find("blur");
            preblurred = malloc((size_t)H * W);
            if (!preblurred) { perror("malloc preblurred"); return 1; }
            if (run_pass_to_uint8(&ctx, kern_blur, in_img, H, W,
                                  preblurred, "preblur") < 0) return 1;
            mag_in = preblurred;
            total_tiles += n_tiles;
        }

        float *a_buf = malloc((size_t)H * W * sizeof(float));
        float *b_buf = malloc((size_t)H * W * sizeof(float));
        if (!a_buf || !b_buf) { perror("malloc mag bufs"); return 1; }

        if (run_pass(&ctx, kern_a, mag_in, H, W, a_buf, kern_a->name) < 0)
            return 1;
        if (run_pass(&ctx, kern_b, mag_in, H, W, b_buf, kern_b->name) < 0)
            return 1;
        total_tiles += 2 * n_tiles;
        if (!kern->preblur) total_tiles = 2 * n_tiles;
        else total_tiles = 3 * n_tiles;

        for (int p = 0; p < H * W; p++) {
            double a = a_buf[p];
            double b = b_buf[p];
            double m = sqrt(a*a + b*b);
            if (m < 0)   m = 0;
            if (m > 255) m = 255;
            out_img[p] = (uint8_t)(m + 0.5);
        }
        free(a_buf);
        free(b_buf);
        if (preblurred) free(preblurred);
    } else if (kern->mode == DECODE_PIPELINE) {
        const struct kernel_def *kern_a = kernel_find(kern->pass_a);
        const struct kernel_def *kern_b = kernel_find(kern->pass_b);
        if (!kern_a || !kern_b) {
            fprintf(stderr, "internal: missing pipeline stage\n");
            return 1;
        }

        // Stage 1: run pass_a, quantise to uint8.
        uint8_t *intermediate = malloc((size_t)H * W);
        if (!intermediate) { perror("malloc intermediate"); return 1; }
        if (run_pass_to_uint8(&ctx, kern_a, in_img, H, W,
                              intermediate, kern_a->name) < 0) return 1;

        // Stage 2: run pass_b on the intermediate; map using pass_b's mode.
        float *signed_buf = malloc((size_t)H * W * sizeof(float));
        if (!signed_buf) { perror("malloc signed_buf"); return 1; }
        if (run_pass(&ctx, kern_b, intermediate, H, W,
                     signed_buf, kern_b->name) < 0) return 1;
        free(intermediate);

        for (int p = 0; p < H * W; p++)
            out_img[p] = kernel_signed_to_pixel(signed_buf[p], kern_b->mode);
        free(signed_buf);
        total_tiles = 2 * n_tiles;
    } else {
        // Single-pass: run once, decode each pixel by mode.
        float *signed_buf = malloc((size_t)H * W * sizeof(float));
        if (!signed_buf) { perror("malloc signed_buf"); return 1; }

        if (run_pass(&ctx, kern, in_img, H, W, signed_buf, kern->name) < 0)
            return 1;
        for (int p = 0; p < H * W; p++)
            out_img[p] = kernel_signed_to_pixel(signed_buf[p], kern->mode);
        free(signed_buf);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double dt_s = (t1.tv_sec - t0.tv_sec) +
                  (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("\nProcessing complete:\n");
    printf("  total time     : %.2f s\n", dt_s);
    printf("  total tiles    : %d\n", total_tiles);
    printf("  per tile       : %.3f ms\n", dt_s * 1000.0 / total_tiles);
    printf("  per pixel      : %.2f us\n", dt_s * 1e6 / (H * W));
    printf("  throughput     : %.2f Mpix/s\n", (H * W) / dt_s / 1e6);

    if (bmp_write_gray(out_path, out_img, H, W) < 0) return 1;
    printf("  wrote %s\n", out_path);

    free(in_img);
    free(out_img);
    fpga_close(&ctx);
    return 0;
}

// =============================================================================
// fpga.h
// UIO + /dev/mem + AXI DMA control surface for the stochastic GEMM
// accelerator, plus the whole-image pass runner.
// =============================================================================
#ifndef FPGA_H
#define FPGA_H

#include <stdint.h>
#include "gemm_image.h"

// ---- Physical layout (must match the bitstream / block design) -----------
#define MAP_SIZE       0x1000
#define DMA_BASE       0xA0000000UL
#define TX_BUF_PHYS    0x0FF00000UL
#define RX_BUF_PHYS    0x0FF10000UL
#define BUF_SIZE       0x10000

// ---- GEMM wrapper register offsets ---------------------------------------
#define REG_CTRL       0x00
#define REG_STATUS     0x04
#define REG_KLEN       0x08
#define REG_INFO       0x0C
#define REG_INFO2      0x10
#define REG_ICOUNT     0x14
#define REG_OCOUNT     0x18
#define REG_INFO3      0x1C
#define REG_RES_PER_K  0x20
#define CTRL_START     0x1

// ---- AXI DMA register offsets --------------------------------------------
#define MM2S_DMACR     0x00
#define MM2S_DMASR     0x04
#define MM2S_SA        0x18
#define MM2S_SA_MSB    0x1C
#define MM2S_LENGTH    0x28
#define S2MM_DMACR     0x30
#define S2MM_DMASR     0x34
#define S2MM_DA        0x48
#define S2MM_DA_MSB    0x4C
#define S2MM_LENGTH    0x58
#define DMA_CR_RUN     0x1
#define DMA_CR_RESET   0x4

struct fpga_ctx {
    volatile uint32_t *gregs;
    volatile uint32_t *dma;
    volatile uint32_t *tx;
    volatile uint32_t *rx;
    int uio_fd;
    int mem_fd;
    int hw_n;
    int hw_kw;
    int hw_resw;
    int hw_slr;
    int is_hybrid;
};

int  fpga_open(struct fpga_ctx *ctx);
void fpga_close(struct fpga_ctx *ctx);
int  fpga_configure(struct fpga_ctx *ctx);

int fpga_process_tile(struct fpga_ctx *ctx,
                      int tile_base, int H, int W,
                      const uint8_t *in_img,
                      const uint16_t *kenc,
                      int32_t *raw_out);

// ----------------------------------------------------------------------------
// Whole-image runner: drive the FPGA over every tile of the image with one
// single-pass kernel and fill `signed_out[0..H*W-1]` with the decoded
// (pre-display-mapping) signed convolution result. The caller chooses what
// to do with the floats -- map to uint8 via kernel_signed_to_pixel, combine
// with a second pass, or pass through to a pipeline stage.
// ----------------------------------------------------------------------------
struct kernel_def;
int fpga_run_pass(struct fpga_ctx *ctx,
                  const struct kernel_def *kern,
                  const uint8_t *in_img, int H, int W,
                  float *signed_out,
                  const char *progress_label);

// Convenience: run one pass and immediately map to uint8 using the kernel's
// own decode mode. Used by pipelines that need an intermediate image.
int fpga_run_pass_uint8(struct fpga_ctx *ctx,
                        const struct kernel_def *kern,
                        const uint8_t *in_img, int H, int W,
                        uint8_t *uint8_out,
                        const char *progress_label);

#endif  // FPGA_H

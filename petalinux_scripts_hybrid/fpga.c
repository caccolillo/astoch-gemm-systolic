// =============================================================================
// fpga.c -- UIO/mem/AXI plumbing for the stochastic GEMM accelerator.
// =============================================================================
#define _GNU_SOURCE
#include "fpga.h"
#include "gemm_image.h"
#include "kernels.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>

#define UIO_DIR         "/sys/class/uio"
#define UIO_NAME        "stoch_gemm_axis_wrapper"
#define UIO_NAME_HYBRID "stoch_gemm_axis_wrapper_hybrid"

static int find_uio_for(const char *name)
{
    DIR *d = opendir(UIO_DIR);
    if (!d) return -1;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, "uio", 3) != 0) continue;
        char path[256];
        snprintf(path, sizeof(path), "%s/%s/name", UIO_DIR, de->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char nm[128] = {0};
        if (fgets(nm, sizeof(nm), f)) {
            size_t l = strlen(nm);
            if (l > 0 && nm[l-1] == '\n') nm[l-1] = 0;
            if (strstr(nm, name)) {
                fclose(f);
                int idx = atoi(de->d_name + 3);
                closedir(d);
                return idx;
            }
        }
        fclose(f);
    }
    closedir(d);
    return -1;
}

static inline uint32_t rd(volatile uint32_t *base, int off) {
    return base[off/4];
}
static inline void wr(volatile uint32_t *base, int off, uint32_t v) {
    base[off/4] = v;
}

static int dma_poll(volatile uint32_t *dma, int sr_off, const char *name)
{
    for (int i = 0; i < 10000000; i++) {
        uint32_t sr = rd(dma, sr_off);
        if (sr & 0x2) return 0;
        usleep(5);
    }
    fprintf(stderr, "DMA %s timeout, SR=0x%08X\n", name, rd(dma, sr_off));
    return -1;
}

int fpga_open(struct fpga_ctx *ctx)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->uio_fd = -1;
    ctx->mem_fd = -1;

    int uio_idx = find_uio_for(UIO_NAME_HYBRID);
    if (uio_idx < 0) uio_idx = find_uio_for(UIO_NAME);
    if (uio_idx < 0) { fprintf(stderr, "UIO node not found\n"); return -1; }

    char uio_dev[64];
    snprintf(uio_dev, sizeof(uio_dev), "/dev/uio%d", uio_idx);
    ctx->uio_fd = open(uio_dev, O_RDWR);
    if (ctx->uio_fd < 0) { perror("open uio"); return -1; }

    ctx->mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (ctx->mem_fd < 0) { perror("open /dev/mem"); return -1; }

    ctx->gregs = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE,
                      MAP_SHARED, ctx->uio_fd, 0);
    ctx->dma   = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE,
                      MAP_SHARED, ctx->mem_fd, DMA_BASE);
    ctx->tx    = mmap(NULL, BUF_SIZE, PROT_READ|PROT_WRITE,
                      MAP_SHARED, ctx->mem_fd, TX_BUF_PHYS);
    ctx->rx    = mmap(NULL, BUF_SIZE, PROT_READ|PROT_WRITE,
                      MAP_SHARED, ctx->mem_fd, RX_BUF_PHYS);
    if (ctx->gregs == MAP_FAILED || ctx->dma == MAP_FAILED ||
        ctx->tx    == MAP_FAILED || ctx->rx  == MAP_FAILED) {
        perror("mmap");
        return -1;
    }

    // Read hardware configuration.
    uint32_t info  = rd(ctx->gregs, REG_INFO);
    uint32_t info2 = rd(ctx->gregs, REG_INFO2);
    ctx->hw_n     = info & 0xFF;
    ctx->hw_kw    = (info >> 8)  & 0xFF;
    ctx->hw_resw  = (info >> 24) & 0xFF;
    ctx->is_hybrid = (info2 >> 31) & 1;
    ctx->hw_slr    = info2 & 0x00FFFFFF;
    return 0;
}

void fpga_close(struct fpga_ctx *ctx)
{
    if (ctx->gregs && ctx->gregs != MAP_FAILED) munmap((void*)ctx->gregs, MAP_SIZE);
    if (ctx->dma   && ctx->dma   != MAP_FAILED) munmap((void*)ctx->dma,   MAP_SIZE);
    if (ctx->tx    && ctx->tx    != MAP_FAILED) munmap((void*)ctx->tx,    BUF_SIZE);
    if (ctx->rx    && ctx->rx    != MAP_FAILED) munmap((void*)ctx->rx,    BUF_SIZE);
    if (ctx->uio_fd >= 0) close(ctx->uio_fd);
    if (ctx->mem_fd >= 0) close(ctx->mem_fd);
}

int fpga_configure(struct fpga_ctx *ctx)
{
    wr(ctx->dma, MM2S_DMACR, DMA_CR_RESET);
    wr(ctx->dma, S2MM_DMACR, DMA_CR_RESET);
    usleep(1000);

    wr(ctx->gregs, REG_KLEN, K);
    if (ctx->is_hybrid) {
        uint32_t res_per_k = ((uint32_t)ctx->hw_slr + K - 1) / K;
        wr(ctx->gregs, REG_RES_PER_K, res_per_k);
    }
    return 0;
}

int fpga_process_tile(struct fpga_ctx *ctx,
                      int tile_base, int H, int W,
                      const uint8_t *in_img,
                      const uint16_t *kenc,
                      int32_t *raw_out)
{
    int hw_n = ctx->hw_n;
    volatile uint32_t *tx = ctx->tx;
    volatile uint32_t *rx = ctx->rx;
    volatile uint32_t *dma = ctx->dma;
    volatile uint32_t *gregs = ctx->gregs;

    // Build TX buffer: per term k, hw_n a-beats (kernel tap, broadcast) +
    // hw_n b-beats (patch element at position k for each of the hw_n
    // output pixels in this tile).
    memset((void*)tx, 0, BUF_SIZE);
    for (int k = 0; k < K; k++) {
        for (int i = 0; i < hw_n; i++) {
            tx[k*2*hw_n + i] = (uint32_t)kenc[k];

            int p = tile_base + i;
            int pix = 0;
            if (p < H * W) {
                int out_r = p / W;
                int out_c = p % W;
                int rr = out_r + gemm_dr[k];
                int cc = out_c + gemm_dc[k];
                if (rr >= 0 && rr < H && cc >= 0 && cc < W)
                    pix = in_img[rr * W + cc];
            }
            tx[k*2*hw_n + hw_n + i] = (uint32_t)kernel_enc((double)pix / 255.0);
        }
    }
    __sync_synchronize();
    msync((void*)tx, BUF_SIZE, MS_SYNC);

    int tx_bytes = 2 * hw_n * K * 4;
    int rx_bytes = hw_n * hw_n * 4;

    wr(dma, MM2S_DMACR,  DMA_CR_RUN);
    wr(dma, MM2S_SA_MSB, 0);
    wr(dma, MM2S_SA,     (uint32_t)TX_BUF_PHYS);
    wr(dma, MM2S_LENGTH, (uint32_t)tx_bytes);
    if (dma_poll(dma, MM2S_DMASR, "MM2S")) return -1;

    wr(dma, S2MM_DMACR,  DMA_CR_RUN);
    wr(dma, S2MM_DA_MSB, 0);
    wr(dma, S2MM_DA,     (uint32_t)RX_BUF_PHYS);
    wr(dma, S2MM_LENGTH, (uint32_t)rx_bytes);

    wr(gregs, REG_CTRL, CTRL_START);
    if (dma_poll(dma, S2MM_DMASR, "S2MM")) return -1;

    int resw = ctx->hw_resw;
    for (int i = 0; i < hw_n; i++) {
        int32_t cf = (int32_t)rx[i];
        if (resw < 32 && (cf & (1 << (resw - 1))))
            cf |= ~((1 << resw) - 1);
        raw_out[i] = cf;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Whole-image pass runners. Kept in fpga.c (rather than main.c) so pipelines
// can chain them without depending on main's UI code.
// -----------------------------------------------------------------------------
int fpga_run_pass(struct fpga_ctx *ctx,
                  const struct kernel_def *kern,
                  const uint8_t *in_img, int H, int W,
                  float *signed_out,
                  const char *progress_label)
{
    if (kern->mode == DECODE_MAGNITUDE) {
        fprintf(stderr, "internal: fpga_run_pass called with magnitude kernel\n");
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

int fpga_run_pass_uint8(struct fpga_ctx *ctx,
                        const struct kernel_def *kern,
                        const uint8_t *in_img, int H, int W,
                        uint8_t *uint8_out,
                        const char *progress_label)
{
    float *buf = malloc((size_t)H * W * sizeof(float));
    if (!buf) { perror("malloc"); return -1; }
    if (fpga_run_pass(ctx, kern, in_img, H, W, buf, progress_label) < 0) {
        free(buf); return -1;
    }
    for (int p = 0; p < H * W; p++)
        uint8_out[p] = kernel_signed_to_pixel(buf[p], kern->mode);
    free(buf);
    return 0;
}

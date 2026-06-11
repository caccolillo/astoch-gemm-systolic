// =============================================================================
// gemm_test_uio_hybrid.c
// Userspace test program for the HYBRID stochastic GEMM accelerator.
//
// Differences from gemm_test_uio.c (plain-counter version):
//   - Decode formula: pixel = c_flat * K * scale / 2^(WIDTH-1)
//     instead of pixel = c_flat / STREAM_LEN * scale
//   - Detects hybrid mode by reading bit 31 of the INFO2 register.
//   - Reads K_SAR_BITS and SAR_BIT_LEN from INFO3 for diagnostics.
//
// Build:
//   gcc -O2 -o gemm-test-hybrid gemm_test_uio_hybrid.c -lm
// Run:
//   sudo /tmp/gemm-test-hybrid
// =============================================================================
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <errno.h>
#include <sys/ioctl.h>

#define UIO_DIR        "/sys/class/uio"
#define UIO_NAME       "stoch_gemm_axis_wrapper"  // either wrapper variant
#define UIO_NAME_HYBRID "stoch_gemm_axis_wrapper_hybrid"

#define MAP_SIZE       0x1000
#define DMA_BASE       0xA0000000UL
#define GEMM_BASE      0xA0010000UL
#define TX_BUF_PHYS    0x0FF00000UL
#define RX_BUF_PHYS    0x0FF10000UL
#define BUF_SIZE       0x10000

// GEMM registers
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
#define CTRL_IRQ_EN    0x2

// AXI DMA registers
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

#define IMG_DIM        8      // Synthetic test image size (8x8 pixels)
#define K              9      // Convolution kernel size (3x3 = 9 taps)
// Note: the hardware's array size (N x N PEs) is read at runtime from the
// INFO register (hw_n). Do NOT hardcode N here -- it changes with the
// bitstream and used to be 8, is now 22 (or whatever the wrapper VHDL says).

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
        usleep(10);
    }
    fprintf(stderr, "DMA %s timeout, SR=0x%08X\n", name, rd(dma, sr_off));
    return -1;
}

// Bipolar encoding: x in [0,1] -> binary in [0.5*2^W, 2^W-1]
static uint16_t enc(double x) {
    int q = (int)round((x + 1.0) / 2.0 * 65536.0);
    if (q < 0) q = 0;
    if (q > 0xFFFF) q = 0xFFFF;
    return (uint16_t)q;
}

int main(void)
{
    printf("=== Stochastic GEMM HYBRID test (UIO + /dev/mem) ===\n\n");

    int uio_idx = find_uio_for(UIO_NAME_HYBRID);
    if (uio_idx < 0) uio_idx = find_uio_for(UIO_NAME);
    if (uio_idx < 0) { fprintf(stderr, "UIO node not found\n"); return 1; }

    char uio_dev[64];
    snprintf(uio_dev, sizeof(uio_dev), "/dev/uio%d", uio_idx);
    int uio_fd = open(uio_dev, O_RDWR);
    if (uio_fd < 0) { perror("open uio"); return 1; }

    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) { perror("open /dev/mem"); return 1; }

    volatile uint32_t *gregs = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE,
                                     MAP_SHARED, uio_fd, 0);
    volatile uint32_t *dma   = mmap(NULL, MAP_SIZE, PROT_READ|PROT_WRITE,
                                     MAP_SHARED, mem_fd, DMA_BASE);
    volatile uint32_t *tx    = mmap(NULL, BUF_SIZE, PROT_READ|PROT_WRITE,
                                     MAP_SHARED, mem_fd, TX_BUF_PHYS);
    if (gregs == MAP_FAILED || dma == MAP_FAILED || tx == MAP_FAILED) {
        perror("mmap"); return 1;
    }

    // ---- Read configuration registers --------------------------------
    uint32_t info  = rd(gregs, REG_INFO);
    uint32_t info2 = rd(gregs, REG_INFO2);
    uint32_t info3 = rd(gregs, REG_INFO3);

    int hw_n     = info & 0xFF;
    int hw_kw    = (info >> 8)  & 0xFF;
    int hw_cntw  = (info >> 16) & 0xFF;
    int hw_resw  = (info >> 24) & 0xFF;
    int is_hybrid = (info2 >> 31) & 1;
    int hw_slr    = info2 & 0x00FFFFFF;     // STREAM_LEN_RESIDUE
    int hw_ksar   = info3 & 0xFF;
    int hw_sblen  = (info3 >> 8) & 0xFF;

    printf("HW: N=%d KW=%d CNTW=%d RESW=%d\n", hw_n, hw_kw, hw_cntw, hw_resw);
    if (is_hybrid) {
        printf("    HYBRID mode: K_SAR_BITS=%d SAR_BIT_LEN=%d STREAM_LEN_RESIDUE=%d\n",
               hw_ksar, hw_sblen, hw_slr);
    } else {
        printf("    PLAIN COUNTER mode: STREAM_LEN=%d\n", hw_slr);
    }

    // ---- Build TX buffer ---------------------------------------------
    // 8x8 gradient image: c*32 in each column
    int img[8][8];
    for (int r = 0; r < 8; r++)
        for (int c = 0; c < 8; c++)
            img[r][c] = c * 32;

    double kern[K] = {1,2,1, 2,4,2, 1,2,1};
    double kmax = 4.0, kern_sum = 16.0;
    int dr[K] = {-1,-1,-1, 0, 0, 0, 1, 1, 1};
    int dc[K] = {-1, 0, 1,-1, 0, 1,-1, 0, 1};

    // Encode kernel taps once
    uint16_t kenc[K];
    for (int k = 0; k < K; k++) kenc[k] = enc(kern[k] / kmax);

    // Build TX using the HARDWARE N (hw_n), not the compile-time constant.
    // Per term k: hw_n a-beats (kernel taps, all kenc[k]) followed by
    // hw_n b-beats (patch pixels at column i).
    //
    // For hw_n > 8 we zero-pad the columns beyond the 8x8 test image, so
    // those output positions will receive zero-input contributions and
    // produce zero results that we simply won't score against the reference.
    volatile uint32_t *tx32 = tx;
    memset((void*)tx32, 0, BUF_SIZE);   // zero-pad everything first
    int tile_base = 0;  // row 0 of the synthetic image
    for (int k = 0; k < K; k++) {
        for (int i = 0; i < hw_n; i++) {
            int rr = 0 + dr[k];
            int cc = i + dc[k];
            int pix = 0;
            if (rr >= 0 && rr < IMG_DIM && cc >= 0 && cc < IMG_DIM)
                pix = img[rr][cc];
            tx32[k*2*hw_n + i]         = (uint32_t)kenc[k];                  // a: kernel
            tx32[k*2*hw_n + hw_n + i]  = (uint32_t)enc((double)pix/255.0);   // b: patch
        }
    }

    // Flush TX buffer to DDR
    __sync_synchronize();
    msync((void*)tx, BUF_SIZE, MS_SYNC);

    int n_beats  = 2 * hw_n * K;
    int tx_bytes = n_beats * 4;
    int rx_bytes = hw_n * hw_n * 4;
    if (rx_bytes > BUF_SIZE || tx_bytes > BUF_SIZE) {
        fprintf(stderr, "ERROR: hw_n=%d makes buffers too big "
                        "(tx=%d rx=%d > BUF_SIZE=%d)\n",
                        hw_n, tx_bytes, rx_bytes, BUF_SIZE);
        return 1;
    }

    printf("TX: %d beats (%d bytes)\n\n", n_beats, tx_bytes);

    // ---- Reset DMA ---------------------------------------------------
    printf("Resetting DMA...\n");
    wr(dma, MM2S_DMACR, DMA_CR_RESET);
    wr(dma, S2MM_DMACR, DMA_CR_RESET);
    usleep(1000);
    for (int i = 0; i < 100; i++) {
        if (!(rd(dma, MM2S_DMACR) & DMA_CR_RESET) &&
            !(rd(dma, S2MM_DMACR) & DMA_CR_RESET)) break;
        usleep(100);
    }

    // ---- Configure GEMM ----------------------------------------------
    wr(gregs, REG_KLEN, K);
    // Compute res_per_k = ceil(STREAM_LEN_RESIDUE / K) in software.
    // The hardware used to do this division but it broke timing closure
    // (32-deep CARRY8 chain). Now software does it once at startup.
    if (is_hybrid) {
        uint32_t res_per_k = ((uint32_t)hw_slr + K - 1) / K;
        wr(gregs, REG_RES_PER_K, res_per_k);
        printf("Wrote RES_PER_K = %u (STREAM_LEN_RESIDUE=%d / K=%d)\n",
               res_per_k, hw_slr, K);
    }

    // ---- MM2S first, wait, then START --------------------------------
    struct timespec t0, t1;

    wr(dma, MM2S_DMACR,  DMA_CR_RUN);
    wr(dma, MM2S_SA_MSB, 0);
    wr(dma, MM2S_SA,     (uint32_t)TX_BUF_PHYS);
    wr(dma, MM2S_LENGTH, (uint32_t)tx_bytes);
    printf("MM2S started, waiting...\n");
    if (dma_poll(dma, MM2S_DMASR, "MM2S")) return 1;
    printf("MM2S done. ICOUNT=%u\n", rd(gregs, REG_ICOUNT));

    wr(dma, S2MM_DMACR,  DMA_CR_RUN);
    wr(dma, S2MM_DA_MSB, 0);
    wr(dma, S2MM_DA,     (uint32_t)RX_BUF_PHYS);
    wr(dma, S2MM_LENGTH, (uint32_t)rx_bytes);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    wr(gregs, REG_CTRL, CTRL_START);
    printf("START written, polling S2MM...\n");
    if (dma_poll(dma, S2MM_DMASR, "S2MM")) return 1;
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double dt_ms = (t1.tv_sec - t0.tv_sec)*1000.0 +
                   (t1.tv_nsec - t0.tv_nsec)/1e6;
    printf("Done in %.3f ms. STATUS=0x%08X OCOUNT=%u\n",
           dt_ms, rd(gregs, REG_STATUS), rd(gregs, REG_OCOUNT));

    // ---- Read RX (fresh mmap to defeat cache) -----------------------
    int mem_fd2 = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *rx = mmap(NULL, BUF_SIZE, PROT_READ|PROT_WRITE,
                                  MAP_SHARED, mem_fd2, RX_BUF_PHYS);
    if (rx == MAP_FAILED) { perror("re-mmap rx"); return 1; }

    // ---- Decode -----------------------------------------------------
    // Hybrid:  pixel = c_flat * K * 255 * kmax / kern_sum / 2^(WIDTH-1)
    // Plain :  pixel = c_flat * 255 * kmax / kern_sum / STREAM_LEN
    double scale_to_pixel;
    if (is_hybrid) {
        scale_to_pixel = (double)K * 255.0 * kmax / kern_sum
                       / (double)(1 << (hw_kw - 1));
        printf("HW decode (hybrid): pixel = c_flat * %.6f\n", scale_to_pixel);
    } else {
        scale_to_pixel = 255.0 * kmax / kern_sum / (double)hw_slr;
        printf("HW decode (plain): pixel = c_flat * %.6f\n", scale_to_pixel);
    }

    // SW reference -- only compute for the first IMG_DIM (=8) outputs,
    // because the synthetic test image is 8x8. Output positions >= 8
    // received zero-padded operands and have no software reference.
    double sw[IMG_DIM];
    for (int i = 0; i < IMG_DIM; i++) {
        double acc = 0.0;
        for (int k = 0; k < K; k++) {
            int rr = 0 + dr[k];
            int cc = i + dc[k];
            int pix = 0;
            if (rr >= 0 && rr < IMG_DIM && cc >= 0 && cc < IMG_DIM)
                pix = img[rr][cc];
            acc += pix * kern[k] / kern_sum;
        }
        sw[i] = acc;
    }

    printf("\n%-5s  %-12s  %-10s  %-10s  %-10s\n",
           "pixel", "c_flat", "hw_pix", "sw_pix", "err_8bit");
    printf("-----  ------------  ----------  ----------  ----------\n");

    double mse = 0.0;
    for (int i = 0; i < IMG_DIM; i++) {
        int32_t cf = (int32_t)rx[i];
        // Sign-extend from hw_resw bits
        if (hw_resw < 32 && (cf & (1 << (hw_resw-1))))
            cf |= ~((1 << hw_resw) - 1);

        double hw_pix = (double)cf * scale_to_pixel;
        double err = fabs(hw_pix - sw[i]);
        mse += err * err;
        printf("%-5d  %-12d  %-10.2f  %-10.2f  %-10.2f\n",
               i, cf, hw_pix, sw[i], err);
    }
    mse /= IMG_DIM;
    double psnr = (mse > 1e-12) ? 10.0 * log10(255.0*255.0 / mse)
                                : INFINITY;
    printf("\nPSNR (tile 0, first %d outputs of hw_n=%d): %.2f dB\n",
           IMG_DIM, hw_n, psnr);

    // Also dump the zero-padded outputs (positions IMG_DIM..hw_n-1) for
    // sanity: they should be very close to zero since both operand inputs
    // were zero. Anything wildly non-zero here indicates a hardware bug
    // (bus contamination, stale state, etc.).
    if (hw_n > IMG_DIM) {
        printf("\nZero-padded output positions (should all be ~0):\n");
        for (int i = IMG_DIM; i < hw_n; i++) {
            int32_t cf = (int32_t)rx[i];
            if (hw_resw < 32 && (cf & (1 << (hw_resw-1))))
                cf |= ~((1 << hw_resw) - 1);
            printf("  [%2d] c_flat=%d\n", i, cf);
        }
    }

    munmap((void*)gregs, MAP_SIZE);
    munmap((void*)dma, MAP_SIZE);
    munmap((void*)tx, BUF_SIZE);
    munmap((void*)rx, BUF_SIZE);
    close(uio_fd);
    close(mem_fd);
    close(mem_fd2);
    return 0;
}

// =============================================================================
// gemm_test_uio.c  --  Stochastic GEMM accelerator test
// Ultra96-V2 / ZynqMP  --  UIO + /dev/mem  --  no custom kernel module
//
// Hardware map (from Vivado block design):
//   AXI DMA         @ 0xA0000000  (S_AXI_LITE control)
//   GEMM accelerator@ 0xA0010000  (S_AXI_LITE control)
//   TX buffer        @ 0x0FF00000  (DDR, MM2S source)
//   RX buffer        @ 0x0FF10000  (DDR, S2MM destination)
//
// The GEMM IRQ is wired to pl_ps_irq0 (SPI 89).
// DMA interrupts are NOT wired in HW -- we poll DMA completion.
//
// Compile:
//   aarch64-linux-gnu-gcc -O2 -o gemm-test gemm_test_uio.c -lm
// Run as root:
//   sudo gemm-test
// =============================================================================

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>

// ---- Physical addresses ----------------------------------------------------
#define DMA_BASE        0xA0000000UL
#define GEMM_BASE       0xA0010000UL
#define TX_BUF_PHYS     0x0FF00000UL
#define RX_BUF_PHYS     0x0FF10000UL
#define DMA_SIZE        0x10000
#define GEMM_SIZE       0x1000
#define BUF_SIZE        0x10000

// ---- GEMM register offsets -------------------------------------------------
#define REG_CTRL        0x00
#define REG_STATUS      0x04
#define REG_KLEN        0x08
#define REG_INFO        0x0C
#define REG_INFO2       0x10
#define REG_ICOUNT      0x14
#define REG_OCOUNT      0x18
#define CTRL_START      (1u<<0)
#define CTRL_IRQ_EN     (1u<<1)
#define STATUS_DONE     (1u<<1)

// ---- AXI DMA register offsets ----------------------------------------------
#define MM2S_DMACR      0x00
#define MM2S_DMASR      0x04
#define MM2S_SA         0x18
#define MM2S_SA_MSB     0x1C
#define MM2S_LENGTH     0x28
#define S2MM_DMACR      0x30
#define S2MM_DMASR      0x34
#define S2MM_DA         0x48
#define S2MM_DA_MSB     0x4C
#define S2MM_LENGTH     0x58
#define DMA_CR_RUN      (1u<<0)
#define DMA_CR_RESET    (1u<<2)
#define DMA_CR_IOC_IRQEN (1u<<12)
#define DMA_SR_HALTED   (1u<<0)
#define DMA_SR_IDLE     (1u<<1)
#define DMA_SR_IOC      (1u<<12)
#define DMA_SR_ERR_MASK 0x70

// ---- Accelerator parameters ------------------------------------------------
#define N           8
#define WIDTH       16
#define STREAM_LEN  1024
#define K           9
#define POLL_MAX    2000000

// ---- Register helpers ------------------------------------------------------
static inline void wr(volatile uint32_t *b,uint32_t o,uint32_t v){b[o/4]=v;}
static inline uint32_t rd(volatile uint32_t *b,uint32_t o){return b[o/4];}

// ---- Encoding (bipolar-unipolar: x in [0,1] maps to P in [0.5, 1.0]) ------
// The SNG uses: P(out=1) = binary_in / 2^WIDTH
// For a pixel x in [0,1]: encode as (x+1)/2 * 65536
// so P = (x+1)/2, ranging from 0.5 (black) to 1.0 (white).
// This is consistent with the testbench and Python reference scripts.
static uint16_t enc(double x){
    int q=(int)round((x+1.0)/2.0*65536.0);
    if(q<0)q=0; if(q>0xFFFF)q=0xFFFF; return(uint16_t)q;
}

// ---- im2col ----------------------------------------------------------------
static void im2col_encode(const uint8_t *img,int H,int W,uint16_t *out){
    static const int dr[]={-1,-1,-1,0,0,0,1,1,1};
    static const int dc[]={-1,0,1,-1,0,1,-1,0,1};
    for(int k=0;k<K;k++) for(int r=0;r<H;r++) for(int c=0;c<W;c++){
        int sr=r+dr[k],sc=c+dc[k];
        double pix=(sr<0||sr>=H||sc<0||sc>=W)?0.0:img[sr*W+sc]/255.0;
        out[k*H*W+r*W+c]=enc(pix);
    }
}

// ---- Gaussian kernel -------------------------------------------------------
// Kernel [1,2,1,2,4,2,1,2,1], kmax=4 (max tap value).
// Each tap encoded as enc(kern[k]/kmax): values in [0.25, 0.5, 1.0]
// mapped to P in [0.625, 0.75, 1.0].
// km returns kmax for use in kern_sum_P calculation.
static void gauss_enc(uint16_t *ke,double *km){
    double g[9]={1,2,1,2,4,2,1,2,1};
    *km=4.0;  // kmax = max tap value
    for(int i=0;i<9;i++) ke[i]=enc(g[i]/(*km));
}

// ---- Software reference ----------------------------------------------------
// Computes: out[r][c] = sum_k( img[r+dr[k]][c+dc[k]] * kern[k] ) / kern_sum
// Output is in pixel units [0, 255].
static void conv_sw(const uint8_t *img,int H,int W,
                    const double *kern,double kern_sum,double *out){
    static const int dr[]={-1,-1,-1,0,0,0,1,1,1};
    static const int dc[]={-1,0,1,-1,0,1,-1,0,1};
    for(int r=0;r<H;r++) for(int c=0;c<W;c++){
        double acc=0;
        for(int k=0;k<K;k++){
            int sr=r+dr[k],sc=c+dc[k];
            double pix=(sr<0||sr>=H||sc<0||sc>=W)?0.0:(double)img[sr*W+sc];
            acc+=pix*(kern[k]/kern_sum);
        }
        out[r*W+c]=acc;  // range [0,255]
    }
}

// ---- DMA reset with polling ------------------------------------------------
static int dma_reset(volatile uint32_t *dma){
    // Reset both channels
    wr(dma,MM2S_DMACR,DMA_CR_RESET);
    wr(dma,S2MM_DMACR,DMA_CR_RESET);
    // Poll until reset clears (bit 2 returns to 0)
    for(int i=0;i<10000;i++){
        if(!(rd(dma,MM2S_DMACR)&DMA_CR_RESET) &&
           !(rd(dma,S2MM_DMACR)&DMA_CR_RESET)) return 0;
        usleep(10);
    }
    fprintf(stderr,"ERROR: DMA reset timeout\n");
    return -1;
}

// ---- DMA poll for completion -----------------------------------------------
static int dma_poll(volatile uint32_t *dma,uint32_t sr_off,const char *nm){
    for(int i=0;i<POLL_MAX;i++){
        uint32_t sr=rd(dma,sr_off);
        if(sr & DMA_SR_ERR_MASK){
            fprintf(stderr,"ERROR: DMA %s error SR=0x%08X\n",nm,sr);
            return -1;
        }
        if(sr & DMA_SR_IOC) return 0;   // transfer complete
        if(sr & DMA_SR_IDLE) return 0;  // channel idle
    }
    fprintf(stderr,"ERROR: DMA %s timeout SR=0x%08X\n",nm,rd(dma,sr_off));
    return -1;
}

// ============================================================================
int main(void){
    printf("=== Stochastic GEMM test (UIO + /dev/mem) ===\n\n");

    // ---- Open /dev/mem ----
    int memfd=open("/dev/mem",O_RDWR|O_SYNC);
    if(memfd<0){perror("/dev/mem (run as root)");return 1;}

    // ---- Find UIO device for stoch_gemm_axis ----
    int uio_num=-1;
    for(int i=0;i<16;i++){
        char path[64],name[64]; FILE *f;
        snprintf(path,sizeof(path),"/sys/class/uio/uio%d/name",i);
        if(!(f=fopen(path,"r"))) continue;
        if(fgets(name,sizeof(name),f)){
            if(strstr(name,"stoch_gemm")){uio_num=i;}
        }
        fclose(f);
        if(uio_num>=0) break;
    }
    if(uio_num<0){
        fprintf(stderr,"ERROR: stoch_gemm_axis UIO not found.\n"
            "  Check: ls /sys/class/uio/*/name\n"
            "  Try: modprobe uio_pdrv_genirq of_id=generic-uio\n");
        return 1;
    }
    printf("Found stoch_gemm_axis at /dev/uio%d\n",uio_num);

    char uio_path[32];
    snprintf(uio_path,sizeof(uio_path),"/dev/uio%d",uio_num);
    int uio_fd=open(uio_path,O_RDWR);
    if(uio_fd<0){perror(uio_path);return 1;}

    // ---- Map registers ----
    // GEMM control registers via UIO
    volatile uint32_t *gregs=mmap(NULL,GEMM_SIZE,PROT_READ|PROT_WRITE,
                                   MAP_SHARED,uio_fd,0);
    // DMA control registers via /dev/mem
    volatile uint32_t *dma=mmap(NULL,DMA_SIZE,PROT_READ|PROT_WRITE,
                                  MAP_SHARED,memfd,(off_t)DMA_BASE);
    // DMA buffers via /dev/mem
    volatile uint8_t *tx=mmap(NULL,BUF_SIZE,PROT_READ|PROT_WRITE,
                                MAP_SHARED,memfd,(off_t)TX_BUF_PHYS);
    volatile uint8_t *rx=mmap(NULL,BUF_SIZE,PROT_READ|PROT_WRITE,
                                MAP_SHARED,memfd,(off_t)RX_BUF_PHYS);

    if(gregs==MAP_FAILED||dma==MAP_FAILED||
       tx==MAP_FAILED||rx==MAP_FAILED){
        perror("mmap failed"); return 1;
    }

    // ---- Verify hardware ----
    uint32_t info=rd(gregs,REG_INFO);
    uint32_t info2=rd(gregs,REG_INFO2);
    if(info==0||info==0xFFFFFFFF){
        fprintf(stderr,"ERROR: INFO=0x%08X -- bitstream not loaded or AXI broken\n",info);
        return 1;
    }
    int hw_n=info&0xFF;
    printf("HW: N=%d KW=%d CNTW=%d RESW=%d STREAM_LEN=%d\n\n",
           hw_n,(info>>8)&0xFF,(info>>16)&0xFF,(info>>24)&0xFF,(int)info2);

    // ---- Build test image (8x8 gradient + bright square) ----
    const int H=8,W=8;
    uint8_t img[64];
    for(int r=0;r<H;r++) for(int c=0;c<W;c++){
        img[r*W+c]=(uint8_t)(c*32);
        if(r>=2&&r<5&&c>=2&&c<5) img[r*W+c]=240;
    }

    // ---- Encode operands ----
    uint16_t patches[K*H*W],kenc[K];
    double kern[K]={1,2,1,2,4,2,1,2,1},kmax;
    im2col_encode(img,H,W,patches);
    gauss_enc(kenc,&kmax);

    // ---- Build TX buffer (tile 0: first N pixels) ----
    int tile_base=0;
    int n_beats=2*N*K;
    int tx_bytes=n_beats*4;
    int rx_bytes=N*N*4;
    volatile uint32_t *tx32=(volatile uint32_t *)tx;
    memset((void*)rx,0,rx_bytes);
    for(int k=0;k<K;k++) for(int i=0;i<N;i++){
        tx32[k*2*N+i]  =patches[k*H*W+tile_base+i];
        tx32[k*2*N+N+i]=kenc[k];
    }
    // Flush TX buffer to DDR -- DMA reads directly from DDR bypassing cache
    __sync_synchronize();
    msync((void*)tx, BUF_SIZE, MS_SYNC);

    // Verify TX was written correctly -- print first non-zero tap
    printf("TX[k=5,i=0..3]: 0x%04X 0x%04X 0x%04X 0x%04X\n",
           tx32[5*2*N+0], tx32[5*2*N+1], tx32[5*2*N+2], tx32[5*2*N+3]);

    printf("TX: %d beats (%d bytes) @ 0x%08lX\n",
           n_beats,tx_bytes,(unsigned long)TX_BUF_PHYS);
    printf("RX: %d words (%d bytes) @ 0x%08lX\n\n",
           N*N,rx_bytes,(unsigned long)RX_BUF_PHYS);

    // ---- Reset DMA ----
    printf("Resetting DMA...\n");
    if(dma_reset(dma)) return 1;
    printf("DMA reset OK  MM2S_SR=0x%08X  S2MM_SR=0x%08X\n",
           rd(dma,MM2S_DMASR),rd(dma,S2MM_DMASR));

    // ---- Configure GEMM accelerator ----
    wr(gregs,REG_KLEN,(uint32_t)K);

    // ---- Correct sequence per AXI wrapper programming model ----
    // 1. MM2S first: stream ALL operands into the wrapper's abuf/bbuf.
    //    The wrapper buffers them and waits for START.
    // 2. Only after MM2S completes (all operands received) write START.
    // 3. S2MM runs concurrently with the core computation.
    //    Set it up before START so it is ready when results arrive.
    //
    // WARNING: writing START before MM2S completes causes a race --
    // the wrapper resets its input sequencer on START, corrupting
    // operands that are still arriving from the DMA.

    // ---- Step 1: start MM2S and wait for all operands to be received ----
    struct timespec t0,t1;

    wr(dma,MM2S_DMACR,DMA_CR_RUN);
    wr(dma,MM2S_SA_MSB,0);
    wr(dma,MM2S_SA,(uint32_t)TX_BUF_PHYS);
    wr(dma,MM2S_LENGTH,(uint32_t)tx_bytes);

    printf("MM2S started  SR=0x%08X\n",rd(dma,MM2S_DMASR));
    printf("Polling MM2S completion (loading operands into wrapper buffer)...\n");
    if(dma_poll(dma,MM2S_DMASR,"MM2S")) return 1;
    printf("MM2S done     SR=0x%08X  ICOUNT=%u\n",
           rd(dma,MM2S_DMASR), rd(gregs,REG_ICOUNT));

    // ---- Step 2: arm S2MM so it is ready to receive results ----
    wr(dma,S2MM_DMACR,DMA_CR_RUN);
    wr(dma,S2MM_DA_MSB,0);
    wr(dma,S2MM_DA,(uint32_t)RX_BUF_PHYS);
    wr(dma,S2MM_LENGTH,(uint32_t)rx_bytes);
    printf("S2MM armed    SR=0x%08X\n",rd(dma,S2MM_DMASR));

    // ---- Step 3: write START -- core begins consuming buffered operands ----
    // Unmask UIO interrupt first
    uint32_t unmask=1;
    if(write(uio_fd,&unmask,sizeof(unmask))!=sizeof(unmask)){
        perror("UIO unmask"); return 1;
    }
    clock_gettime(CLOCK_MONOTONIC,&t0);
    wr(gregs,REG_CTRL,CTRL_IRQ_EN|CTRL_START);
    printf("START written\n");

    // ---- Step 4: poll S2MM for results ----
    printf("Polling S2MM completion...\n");
    if(dma_poll(dma,S2MM_DMASR,"S2MM")) return 1;

    clock_gettime(CLOCK_MONOTONIC,&t1);
    printf("S2MM done     SR=0x%08X\n",rd(dma,S2MM_DMASR));

    // Memory barrier
    __sync_synchronize();

    // ---- Check GEMM status ----
    uint32_t status=rd(gregs,REG_STATUS);
    uint32_t icount=rd(gregs,REG_ICOUNT);
    uint32_t ocount=rd(gregs,REG_OCOUNT);
    double elapsed=(t1.tv_sec-t0.tv_sec)*1e3+(t1.tv_nsec-t0.tv_nsec)*1e-6;

    printf("\nDone: %.3f ms  STATUS=0x%08X\n",elapsed,status);
    printf("  ICOUNT=%u (expect %d)  OCOUNT=%u (expect %d)\n\n",
           icount,n_beats,ocount,N*N);

    if(!(status&STATUS_DONE))
        fprintf(stderr,"WARN: STATUS_DONE not set -- accelerator may not have finished\n");

    // ---- Parse results ----
    // Result scale: accelerator outputs fixed-point with RESW fractional bits.
    // RESW is bits [31:24] of the INFO register.
    // hw_val = rx32[i] / 2^RESW * kmax * 255
    // Bipolar stochastic decode:
    // Pixels encoded as P_pixel = (pixel/255 + 1)/2  in [0.5, 1.0]
    // Kernel encoded as P_kern  = (kern[k]/kmax + 1)/2
    // E[raw] = STREAM_LEN * P_pixel * kern_sum_P
    // where kern_sum_P = sum_k(P_kern[k]) = 6.5 for gaussian kernel
    // Decode: P_pixel = raw / (STREAM_LEN * kern_sum_P)
    //         pixel   = (P_pixel - 0.5) * 510  (inverts the bipolar encoding)
    int hw_resw = (info >> 24) & 0xFF;
    (void)hw_resw;
    // RTL decode (from stoch_gemm_top.sv):
    //   c_flat = 2*cnt - K*STREAM_LEN  (signed, de-biased by hardware)
    //   real_value = c_flat / STREAM_LEN  in range [-K, +K]
    //   conv_out = real_value * 255 * kmax / kern_sum
    // where kern_sum = sum of kernel taps = 16, kmax = 4.
    double kern_sum = 0.0;
    for(int k=0;k<K;k++) kern_sum += kern[k];  // = 16
    double hw_conv_scale = 255.0 * kmax / kern_sum;
    printf("HW decode: c_flat/STREAM_LEN * %.4f  (kmax=%.1f kern_sum=%.1f)\n\n",
           hw_conv_scale, kmax, kern_sum);

    // Open a fresh file descriptor and mmap for the RX buffer to guarantee
    // we are not reading stale cache -- DMA writes bypass CPU cache.
    int memfd2 = open("/dev/mem", O_RDONLY|O_SYNC);
    volatile int32_t *rx32 = (volatile int32_t *)mmap(
        NULL, BUF_SIZE, PROT_READ, MAP_SHARED, memfd2, (off_t)RX_BUF_PHYS);
    if((void*)rx32 == MAP_FAILED){ perror("mmap rx32"); return 1; }

    // Print raw values for debug
    printf("Raw RX[0..7]: ");
    for(int i=0;i<8;i++) printf("0x%08X ", (uint32_t)rx32[i]);
    printf("\n\n");
    double sw[64];
    double kern_sum=0; for(int i=0;i<K;i++) kern_sum+=kern[i]; // =16
    conv_sw(img,H,W,kern,kern_sum,sw);  // sw values in [0,255]

    printf("%-5s  %-10s  %-10s  %-10s\n","pixel","hw_val","sw_val","err_8bit");
    printf("-----  ----------  ----------  ----------\n");
    double mse=0;
    for(int i=0;i<N;i++){
        // c_flat is signed RESW-bit; sign-extend from RESW bits
        int32_t c_flat = (int32_t)rx32[i];
        // Sign extend if RESW < 32
        int hw_resw2 = (info >> 24) & 0xFF;
        if(hw_resw2 < 32 && (c_flat & (1 << (hw_resw2-1))))
            c_flat |= ~((1 << hw_resw2) - 1);
        double hw_pix = ((double)c_flat / STREAM_LEN) * hw_conv_scale;
        double sw_pix=sw[tile_base+i];
        double err=fabs(hw_pix-sw_pix);
        mse+=err*err;
        printf("%-5d  %-10.2f  %-10.2f  %-10.2f\n",
               tile_base+i,hw_pix,sw_pix,err);
    }
    double psnr=mse>0?10.0*log10(255.0*255.0*N/mse):99.0;
    printf("\nPSNR (tile 0, %d pixels, STREAM_LEN=%d): %.2f dB\n",
           N,(int)info2,psnr);

    // ---- Cleanup ----
    munmap((void*)gregs,GEMM_SIZE);
    munmap((void*)dma,DMA_SIZE);
    munmap((void*)tx,BUF_SIZE);
    munmap((void*)rx,BUF_SIZE);
    munmap((void*)rx32,BUF_SIZE);
    close(uio_fd);
    close(memfd);
    close(memfd2);
    return 0;
}

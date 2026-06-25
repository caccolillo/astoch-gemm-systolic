`timescale 1ns/1ps

// =============================================================================
// tb_stoch_image_hybrid.sv
// Image-processing test harness for the HYBRID stochastic GEMM accelerator.
//
// Adapted from tb_stoch_image.sv (which targets the plain-counter
// stoch_gemm_top) for stoch_gemm_top_hybrid. Differences:
//   1. DUT renamed and ports re-wired: rst -> rst_n (active LOW),
//      start/busy/done -> core_start/core_busy/core_done, a_bin/b_bin/c_flat
//      -> core_a_bin/core_b_bin/core_c_flat, k_idx -> core_kidx,
//      load_k -> core_load_k.
//   2. STREAM_LEN parameter replaced by K_SAR_BITS / SAR_BIT_LEN /
//      STREAM_LEN_RESIDUE (matching the silicon defaults).
//   3. New res_per_k input driven at elaboration -- equivalent to the
//      AXI-Lite RES_PER_K register the silicon version writes from software.
//      Computed as STREAM_LEN_RESIDUE / K = 65536 / 9 = 7282.
//   4. result_meta.txt now contains hybrid-specific scaling info; in
//      particular SCALING = 0.017509, the same factor the silicon C app uses
//      to convert c_flat into pixel values. score_results.py should multiply
//      by SCALING rather than divide by STREAM_LEN.
//
// File formats (kernel.txt, patches.txt, meta_tb.txt, gemm_out.txt) are
// unchanged -- prep_im2col.py output is compatible without modification.
//
// Pipeline role (middle stage):
//   prep_im2col.py  ->  [patches.txt, kernel.txt, meta.txt]  ->  THIS TB
//   THIS TB         ->  gemm_out.txt + result_meta.txt  ->  score_results.py
//
// Array usage for a single-filter convolution
//   stoch_gemm_top_hybrid computes C[i][j] = sum_k A[i][k] * B[k][j] over an
//   NxN tile. A convolution by ONE 3x3 filter is a 1x9 * 9xP matrix product.
//   To use the 8x8 array efficiently we BROADCAST the kernel onto all N rows
//   of A and place N different image patches on the N columns of B. Each
//   tile yields N output pixels (every row identical; we read row 0). P
//   output pixels therefore take ceil(P/N) tiles.
//
// Hybrid cycle budget per tile (defaults: K_SAR_BITS=8, K=9, SAR_BIT_LEN=32,
// STREAM_LEN_RESIDUE=65536, RES_PER_K=7282):
//   SAR     = K_SAR_BITS * K * SAR_BIT_LEN    = 8 * 9 * 32   = 2,304 cycles
//   Residue = K * RES_PER_K                   = 9 * 7282     = 65,538 cycles
//   Total per tile (+ overhead)                              ~ 67,860 cycles
// At 5 ns/cycle: ~340 us simulated per tile. A 64x64 image at N=8 (512 tiles)
// is ~174 ms simulated -- well within the 10-second timeout below.
//
// Reset: synchronous active-LOW. Clock: 200 MHz (5 ns).
// =============================================================================

module tb_stoch_image_hybrid;

    // ---- Must match prep_im2col.py -----------------------------------------
    localparam int N          = 8;
    localparam int WIDTH      = 16;
    localparam int LFSR_W     = 16;
    localparam int K          = 9;       // 3x3 kernel

    // ---- Hybrid converter parameters (match the silicon defaults) ----------
    // Identical to what runs on the Ultra96-V2 N=22 build; only N differs.
    localparam int K_SAR_BITS         = 8;
    localparam int SAR_BIT_LEN        = 32;
    localparam int STREAM_LEN_RESIDUE = 65536;
    localparam int KMAX               = 64;

    // Image dimensions: 64x64 synthetic image -> 4096 output pixels.
    // Override on command line with +H= +W= if you preprocess a different
    // size; defaults match prep_im2col.py --size 64.
    localparam int H_DEF = 64;
    localparam int W_DEF = 64;

    localparam real CLK_PERIOD_NS = 5.0;            // 200 MHz

    // Derived widths (mirror stoch_gemm_top_hybrid)
    localparam int RESW = WIDTH + 2;

    // ---- DUT signals -------------------------------------------------------
    logic                       clk, rst_n;
    logic                       core_start;
    logic [$clog2(KMAX+1)-1:0]  k_len;
    logic [31:0]                res_per_k;
    logic [N*WIDTH-1:0]         core_a_bin, core_b_bin;
    logic                       core_busy, core_done, core_load_k;
    logic [$clog2(KMAX)-1:0]    core_kidx;
    logic signed [N*N*RESW-1:0] core_c_flat;

    stoch_gemm_top_hybrid #(
        .N                  (N),
        .WIDTH              (WIDTH),
        .LFSR_W             (LFSR_W),
        .K_SAR_BITS         (K_SAR_BITS),
        .SAR_BIT_LEN        (SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE (STREAM_LEN_RESIDUE),
        .KMAX               (KMAX),
        .RESW               (RESW)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .core_start  (core_start),
        .k_len       (k_len),
        .res_per_k   (res_per_k),
        .core_busy   (core_busy),
        .core_done   (core_done),
        .core_kidx   (core_kidx),
        .core_load_k (core_load_k),
        .core_a_bin  (core_a_bin),
        .core_b_bin  (core_b_bin),
        .core_c_flat (core_c_flat)
    );

    initial clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // ---- Storage for the preprocessed data ---------------------------------
    localparam int MAXPIX = H_DEF * W_DEF;          // 4096
    logic [WIDTH-1:0] patches [K*MAXPIX];           // im2col matrix, flat
    logic [WIDTH-1:0] kernel  [K];                  // 3x3 filter, flat
    int n_out;                                      // actual output-pixel count

    // Result store: one signed numerator per output pixel.
    longint result [MAXPIX];

    // ---- Operand feeder ----------------------------------------------------
    // For the current tile, present kernel term core_kidx on EVERY a-lane
    // (broadcast), and patch[k][tile_base + lane] on each b-lane. Registered
    // for stable setup; driven from core_kidx. The 1-cycle register latency
    // is harmless because the hybrid core asserts core_load_k for a full
    // cycle in S_SAR_TERM_LOAD (1 cycle before S_SAR_TERM_RUN), which gives
    // the registered operand exactly the right time to settle.
    int  tile_base;
    int  ksel;
    logic [N*WIDTH-1:0] a_nx, b_nx;

    always_comb begin
        ksel = int'(core_kidx);
        a_nx = '0;
        b_nx = '0;
        if (ksel < K) begin
            for (int i = 0; i < N; i++) begin
                // A: kernel tap ksel broadcast to all rows.
                a_nx[i*WIDTH +: WIDTH] = kernel[ksel];
                // B: patch element ksel for the pixel on this lane/column.
                if (tile_base + i < n_out)
                    b_nx[i*WIDTH +: WIDTH] = patches[ksel*n_out + tile_base + i];
                else
                    b_nx[i*WIDTH +: WIDTH] = '0;     // tail padding
            end
        end
    end

    // Active-LOW reset: clear operands while rst_n is asserted (low).
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            core_a_bin <= '0;
            core_b_bin <= '0;
        end else begin
            core_a_bin <= a_nx;
            core_b_bin <= b_nx;
        end
    end

    // ---- Test sequence -----------------------------------------------------
    integer fin, fout, code;
    int     n_tiles, t, p;
    logic signed [RESW-1:0] res_num;
    realtime t0, t1;
    real     total_ns;
    longint  total_cycles;
    int      meta_width;
    int      meta_H, meta_W, meta_K, meta_nout;
    string   datadir;
    string   meta_path;
    string   kfile, pfile;
    string   outdir;

    // Decode scaling: matches the silicon C code which uses
    //   pixel = c_flat * 0.017509
    // This factor folds together the SC normalisation, the SAR weighting,
    // and the residue contribution. It IS K-dependent (because RES_PER_K
    // changes with K), so this value is correct ONLY for K=9 at the default
    // hybrid parameters. If you change K, recalibrate by running a known
    // reference convolution and computing pixel/c_flat.
    localparam real SCALING_FACTOR = 0.017509;

    initial begin
        // ---- Resolve the data directory ------------------------------------
        // DEFAULT is "." -- the simulator's CURRENT WORKING DIRECTORY.
        // Override at run time: -testplusarg datadir=/some/path
        if (!$value$plusargs("datadir=%s", datadir))
            datadir = "/home/caccolillo/astoch-gemm-systolic/stoch_gemm_hybrid/stoch_imgtest";
        $display("data directory (input) : %s", datadir);

        if (!$value$plusargs("outdir=%s", outdir))
            outdir = "/home/caccolillo/astoch-gemm-systolic/stoch_gemm_hybrid/stoch_imgtest";
        $display("output directory       : %s", outdir);
        $display("HYBRID mode: K_SAR_BITS=%0d SAR_BIT_LEN=%0d STREAM_LEN_RESIDUE=%0d",
                 K_SAR_BITS, SAR_BIT_LEN, STREAM_LEN_RESIDUE);

        // ---- Read meta_tb.txt : "H W K WIDTH n_out" ------------------------
        meta_path = {datadir, "/meta_tb.txt"};
        fin = $fopen(meta_path, "r");
        if (fin == 0) begin
            $display("FATAL: cannot open %s", meta_path);
            $display("  -> run prep_im2col.py first, and check the datadir");
            $display("     default in this testbench matches your folder.");
            $finish;
        end
        meta_H = H_DEF; meta_W = W_DEF; meta_K = K;
        meta_width = WIDTH; meta_nout = MAXPIX;
        code = $fscanf(fin, "%d %d %d %d %d",
                       meta_H, meta_W, meta_K, meta_width, meta_nout);
        $fclose(fin);
        if (code != 5) begin
            $display("FATAL: %s malformed (got %0d of 5 fields)",
                     meta_path, code);
            $finish;
        end
        n_out = meta_nout;
        $display("meta: %0dx%0d  K=%0d  WIDTH=%0d  n_out=%0d",
                 meta_H, meta_W, meta_K, meta_width, n_out);

        // ---- Load kernel + patches -----------------------------------------
        kfile = {datadir, "/kernel.txt"};
        fin = $fopen(kfile, "r");
        if (fin == 0) begin
            $display("FATAL: cannot open %s", kfile);
            $finish;
        end
        for (p = 0; p < K; p++) begin
            code = $fscanf(fin, "%h", kernel[p]);
            if (code != 1) begin
                $display("FATAL: kernel.txt short -- only %0d of %0d taps", p, K);
                $finish;
            end
        end
        $fclose(fin);

        pfile = {datadir, "/patches.txt"};
        fin = $fopen(pfile, "r");
        if (fin == 0) begin
            $display("FATAL: cannot open %s", pfile);
            $finish;
        end
        for (p = 0; p < K*n_out; p++) begin
            code = $fscanf(fin, "%h", patches[p]);
            if (code != 1) begin
                $display("FATAL: patches.txt short -- only %0d of %0d entries",
                         p, K*n_out);
                $finish;
            end
        end
        $fclose(fin);

        $display("loaded kernel.txt (%0d taps) and patches.txt (%0d x %0d)",
                 K, K, n_out);
        $display("  kernel[0..2] = %h %h %h  (sanity: should be varied, non-8000)",
                 kernel[0], kernel[1], kernel[2]);
        $display("  patches[mid] = %h          (sanity: a real pixel value)",
                 patches[(K*n_out)/2]);

        // ---- Reset (active LOW) and set up runtime parameters --------------
        rst_n      = 1'b0;
        core_start = 1'b0;
        k_len      = K;
        res_per_k  = STREAM_LEN_RESIDUE / K;   // = 7282 for default params
        tile_base  = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("res_per_k = %0d  (= STREAM_LEN_RESIDUE/K = %0d/%0d)",
                 res_per_k, STREAM_LEN_RESIDUE, K);

        // ---- Process the image tile by tile --------------------------------
        n_tiles = (n_out + N - 1) / N;        // ceil(n_out / N)
        $display("processing %0d output pixels in %0d tiles of %0d ...",
                 n_out, n_tiles, N);

        t0 = $realtime;
        for (t = 0; t < n_tiles; t++) begin
            tile_base = t * N;

            // Ensure the previous tile's done pulse has cleared.
            while (core_done == 1'b1) @(posedge clk);

            // Assert core_start and HOLD until DUT raises core_busy.
            core_start = 1'b1;
            while (core_busy == 1'b0) @(posedge clk);
            core_start = 1'b0;

            // Wait for this tile to complete.
            while (core_done == 1'b0) @(posedge clk);
            @(posedge clk);

            // Every row of the result is identical (kernel broadcast); read
            // row 0. Column i holds output pixel tile_base + i.
            for (p = 0; p < N; p++) begin
                if (tile_base + p < n_out) begin
                    res_num = core_c_flat[(0*N + p)*RESW +: RESW];
                    result[tile_base + p] = longint'(res_num);
                end
            end

            if ((t % 4) == 0)
                $display("  tile %0d / %0d done", t, n_tiles);
        end
        t1 = $realtime;

        // ---- Write gemm_out.txt --------------------------------------------
        fout = $fopen({outdir, "/gemm_out.txt"}, "w");
        if (fout == 0) begin
            $display("FATAL: cannot open %s/gemm_out.txt for writing", outdir);
            $finish;
        end
        for (p = 0; p < n_out; p++)
            $fwrite(fout, "%0d\n", result[p]);
        $fclose(fout);

        // ---- Write result_meta.txt with HYBRID scaling info ----------------
        // SCALING is the multiplier from c_flat to real pixel value, matching
        // the silicon C app. score_results.py should be updated to use:
        //   pixel = c_flat * SCALING
        // instead of the plain version's pixel = c_flat / STREAM_LEN.
        // STREAM_LEN is also written for backwards compatibility but should
        // be treated as informational only.
        fout = $fopen({outdir, "/result_meta.txt"}, "w");
        if (fout != 0) begin
            $fwrite(fout, "MODE HYBRID\n");
            $fwrite(fout, "K_SAR_BITS %0d\n",         K_SAR_BITS);
            $fwrite(fout, "SAR_BIT_LEN %0d\n",        SAR_BIT_LEN);
            $fwrite(fout, "STREAM_LEN_RESIDUE %0d\n", STREAM_LEN_RESIDUE);
            $fwrite(fout, "RES_PER_K %0d\n",          res_per_k);
            $fwrite(fout, "K %0d\n",                  K);
            $fwrite(fout, "N %0d\n",                  N);
            $fwrite(fout, "WIDTH %0d\n",              WIDTH);
            $fwrite(fout, "SCALING %0.6f\n",          SCALING_FACTOR);
            // Informational: effective per-term cycle budget for any scorer
            // that still wants a single "stream length" number to display.
            $fwrite(fout, "STREAM_LEN %0d\n",
                    K_SAR_BITS*SAR_BIT_LEN + STREAM_LEN_RESIDUE);
            $fclose(fout);
        end

        // ---- Timing summary ------------------------------------------------
        total_ns     = t1 - t0;
        total_cycles = longint'(total_ns / CLK_PERIOD_NS + 0.5);
        $display("-------------------------------------------------------");
        $display("Stochastic GEMM HYBRID image run complete");
        $display("  output image  : %0dx%0d", meta_H, meta_W);
        $display("  output pixels : %0d", n_out);
        $display("  tiles         : %0d   (K_SAR_BITS=%0d, K=%0d, RES_PER_K=%0d)",
                 n_tiles, K_SAR_BITS, K, res_per_k);
        $display("  clock         : 200 MHz (5.0 ns)");
        $display("  total cycles  : %0d", total_cycles);
        $display("  wall-clock    : %0.1f us simulated", total_ns / 1000.0);
        $display("  per pixel     : %0.1f ns simulated", total_ns / real'(n_out));
        $display("  per tile      : %0.1f us simulated",
                 (total_ns / 1000.0) / real'(n_tiles));
        $display("  wrote         : %s/gemm_out.txt", outdir);
        $display("  scaling       : pixel = c_flat * %0.6f", SCALING_FACTOR);
        $display("-------------------------------------------------------");
        $display("next: python3 score_results.py");

        $finish;
    end

    // Safety timeout. Hybrid tiles are ~8x longer than plain (~68k cycles vs
    // ~8k), so 64x64 at N=8 (512 tiles) takes ~174 ms simulated. Bumped to
    // 10 s for safety -- comfortably allows up to ~256x256 images.
    initial begin
        #10_000_000_000;
        $display("FAIL: timeout -- image too large for this run?");
        $display("  Hint: each hybrid tile takes ~340 us simulated.");
        $display("        For a 64x64 image at N=8 that's ~174 ms total.");
        $display("        Reduce H_DEF/W_DEF or extend this timeout.");
        $finish;
    end

endmodule

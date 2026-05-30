`timescale 1ns/1ps

// =============================================================================
// tb_stoch_image.sv
// Image-processing test harness for the stochastic GEMM accelerator.
//
// Pipeline role (middle stage):
//   prep_im2col.py  ->  [patches.txt, kernel.txt, meta.txt]  ->  THIS TB
//   THIS TB         ->  gemm_out.txt  ->  score_results.py
//
// What it does
//   Reads the im2col activation matrix and the 3x3 filter produced by
//   prep_im2col.py, streams them through stoch_gemm_top one 8x8 tile at a
//   time, and writes every output pixel's raw GEMM numerator to gemm_out.txt.
//
// Array usage for a single-filter convolution
//   stoch_gemm_top computes C[i][j] = sum_k A[i][k] * B[k][j] over an NxN
//   tile. A convolution by ONE 3x3 filter is a 1x9 * 9xP matrix product. To
//   use the 8x8 array efficiently we BROADCAST the kernel onto all N rows of
//   A and place N different image patches on the N columns of B. Each tile
//   then yields N output pixels (every row of the result is identical; we
//   read row 0). P output pixels therefore take ceil(P/N) tiles.
//
// File formats
//   patches.txt : n_out columns x K rows of WIDTH-bit hex, row-major
//                 (all of row k, then all of row k+1, ...).
//   kernel.txt  : K lines of WIDTH-bit hex (the 3x3 filter, flattened).
//   gemm_out.txt: one signed decimal per line = the de-biased numerator for
//                 output pixel p; real value = numerator / STREAM_LEN.
//
// Reset: synchronous active-HIGH. Clock: 200 MHz (5 ns), matching the timing
// study in tb_stoch_gemm_top.sv.
// =============================================================================

module tb_stoch_image;

    // ---- Must match prep_im2col.py -----------------------------------------
    localparam int N          = 8;
    localparam int WIDTH      = 16;
    localparam int LFSR_W     = 16;
    localparam int STREAM_LEN = 1024*8;   // accuracy / speed knob
    localparam int KW         = 16;
    localparam int K          = 9;      // 3x3 kernel

    // Image dimensions: a 64x64 synthetic image -> 4096 output pixels.
    // Override on the command line with +H= +W= if you preprocess a different
    // size; defaults here match prep_im2col.py --size 64.
    localparam int H_DEF = 64;
    localparam int W_DEF = 64;

    localparam real CLK_PERIOD_NS = 5.0;            // 200 MHz

    // Derived widths (mirror stoch_gemm_top).
    localparam int CNTW = $clog2((1<<KW)-1) + $clog2(STREAM_LEN + 1) + 1;
    localparam int RESW = CNTW + 2;

    // ---- DUT signals -------------------------------------------------------
    logic                 clk, rst;
    logic                 start;
    logic [KW-1:0]         k_len;
    logic [N*WIDTH-1:0]    a_bin, b_bin;
    logic                  load_k, busy, done;
    logic [KW-1:0]         k_idx;
    logic [N*N*RESW-1:0]   c_flat;

    stoch_gemm_top #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .STREAM_LEN(STREAM_LEN), .KW(KW)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .k_len(k_len),
        .a_bin(a_bin), .b_bin(b_bin),
        .load_k(load_k), .k_idx(k_idx),
        .busy(busy), .done(done), .c_flat(c_flat)
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
    // For the current tile, present kernel term k on EVERY a-lane (broadcast),
    // and patch[k][tile_base + lane] on each b-lane. Registered for stable
    // setup; driven from k_idx exactly as in tb_stoch_gemm_top.sv.
    int  tile_base;        // index of the first output pixel in this tile
    int  ksel;
    logic [N*WIDTH-1:0] a_nx, b_nx;

    always_comb begin
        ksel = int'(k_idx);
        a_nx = '0;
        b_nx = '0;
        if (ksel < K) begin
            for (int i = 0; i < N; i++) begin
                // A: kernel tap ksel broadcast to all rows.
                a_nx[i*WIDTH +: WIDTH] = kernel[ksel];
                // B: patch element ksel for the pixel on this lane/column.
                // Row k of the im2col matrix occupies n_out consecutive
                // entries (the file is row-major with stride n_out).
                if (tile_base + i < n_out)
                    b_nx[i*WIDTH +: WIDTH] = patches[ksel*n_out + tile_base + i];
                else
                    b_nx[i*WIDTH +: WIDTH] = '0;     // tail padding
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            a_bin <= '0;
            b_bin <= '0;
        end else begin
            a_bin <= a_nx;
            b_bin <= b_nx;
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
    string   datadir;        // input data dir  (".", i.e. xsim run dir)
    string   meta_path;      // datadir + "/meta_tb.txt"
    string   kfile, pfile;   // datadir + "/kernel.txt" / "/patches.txt"
    string   outdir;         // output dir (absolute -- see initial block)

    initial begin
        // ---- Resolve the data directory ------------------------------------
        // DEFAULT is "." -- the simulator's CURRENT WORKING DIRECTORY.
        //
        // The data files (meta_tb.txt, patches.txt, kernel.txt) must be COPIED
        // into xsim's run directory before simulating, e.g.:
        //   cp <project>/stoch_imgtest/*  \
        //      <project>/project_1.sim/sim_image/behav/xsim/
        // Opening by bare "./name" removes ALL path-resolution ambiguity --
        // xsim cannot mis-resolve a file that sits in its own run directory.
        //
        // It can still be overridden at run time with a plusarg:
        //     xsim ... -testplusarg datadir=/some/other/path
        if (!$value$plusargs("datadir=%s", datadir))
            datadir = "/home/caccolillo/BIT_SERIAL_STOCHASTIC/stoch_imgtest";
        $display("data directory (input) : %s", datadir);

        // ---- Resolve the OUTPUT directory ----------------------------------
        // Inputs are read from xsim's run dir (datadir="."), supplied there by
        // the project's sim_image fileset. OUTPUTS, however, are written to a
        // fixed ABSOLUTE path so score_results.py finds them with no copy-back.
        // $fopen(...,"w") with an absolute path to a writable folder is
        // reliable (unlike relative reads, which xsim resolves unpredictably).
        //
        // >>> EDIT THIS PATH if your project lives elsewhere. <<<
        // Overridable at run time:  -testplusarg outdir=/some/path
        if (!$value$plusargs("outdir=%s", outdir))
            outdir = "/home/caccolillo/BIT_SERIAL_STOCHASTIC/stoch_imgtest";
        $display("output directory       : %s", outdir);
        $display("  (inputs from xsim run dir; outputs to the absolute path)");

        // ---- Read meta_tb.txt : "H W K WIDTH n_out" (integers only) --------
        meta_path = {datadir, "/meta_tb.txt"};
        fin = $fopen(meta_path, "r");
        // xsim returns a NEGATIVE descriptor for a successful $fopen(...,"r");
        // failure is specifically a return of 0. The valid test is "== 0",
        // NOT "<= 0" (which would wrongly reject every successful open).
        if (fin == 0) begin
            $display("FATAL: cannot open %s", meta_path);
            $display("  -> run prep_im2col.py first, and check the absolute");
            $display("     path hard-coded as the datadir default in this");
            $display("     testbench matches your stoch_imgtest folder.");
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
        // NOTE: $readmemh in xsim does not reliably accept a run-time
        // constructed string ({datadir,"/..."}) as its filename -- it silently
        // fails to open the file and leaves the array uninitialised. We load
        // the hex files explicitly with $fopen + $fscanf("%h"), the same
        // mechanism that works for meta_tb.txt above.
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

        // ---- Reset ---------------------------------------------------------
        rst = 1; start = 0; k_len = K; tile_base = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- Process the image tile by tile --------------------------------
        n_tiles = (n_out + N - 1) / N;        // ceil(n_out / N)
        $display("processing %0d output pixels in %0d tiles of %0d ...",
                 n_out, n_tiles, N);

        t0 = $realtime;
        for (t = 0; t < n_tiles; t++) begin
            tile_base = t * N;

            // Ensure the previous tile's done pulse has cleared.
            while (done == 1'b1) @(posedge clk);

            // Assert start and HOLD it until the DUT acknowledges by raising
            // busy -- this avoids any delta-cycle race on sampling start.
            start = 1;
            while (busy == 1'b0) @(posedge clk);
            start = 0;

            // Wait for this tile to complete.
            while (done == 1'b0) @(posedge clk);
            @(posedge clk);

            // Every row of the result is identical (kernel broadcast); read
            // row 0. Column i holds output pixel tile_base + i.
            for (p = 0; p < N; p++) begin
                if (tile_base + p < n_out) begin
                    res_num = c_flat[(0*N + p)*RESW +: RESW];
                    result[tile_base + p] = longint'(res_num);
                end
            end

            if ((t % 4) == 0)
                $display("  tile %0d / %0d done", t, n_tiles);
        end
        t1 = $realtime;

        // ---- Write gemm_out.txt --------------------------------------------
        // NOTE: $fopen(...,"w") returns a multi-channel descriptor (MCD), not
        // a small positive FD. A valid MCD can have its top bit set, so a
        // signed "<= 0" test can wrongly reject it. Failure is specifically
        // a return of 0 -- so test "== 0".
        fout = $fopen({outdir, "/gemm_out.txt"}, "w");
        if (fout == 0) begin
            $display("FATAL: cannot open %s/gemm_out.txt for writing", outdir);
            $finish;
        end
        for (p = 0; p < n_out; p++)
            $fwrite(fout, "%0d\n", result[p]);
        $fclose(fout);

        // ---- Write result_meta.txt : the STREAM_LEN actually used ----------
        // score_results.py reads this so the de-bias divisor always matches
        // the RTL run -- no manual sync of a hard-coded constant.
        fout = $fopen({outdir, "/result_meta.txt"}, "w");
        if (fout != 0) begin
            $fwrite(fout, "STREAM_LEN %0d\n", STREAM_LEN);
            $fclose(fout);
        end

        // ---- Timing summary ------------------------------------------------
        total_ns     = t1 - t0;
        total_cycles = longint'(total_ns / CLK_PERIOD_NS + 0.5);
        $display("-------------------------------------------------------");
        $display("Stochastic GEMM image run complete");
        $display("  output image  : %0dx%0d", meta_H, meta_W);
        $display("  output pixels : %0d", n_out);
        $display("  tiles         : %0d   (STREAM_LEN=%0d, K=%0d)",
                 n_tiles, STREAM_LEN, K);
        $display("  clock         : 200 MHz (5.0 ns)");
        $display("  total cycles  : %0d", total_cycles);
        $display("  wall-clock    : %0.1f us", total_ns / 1000.0);
        $display("  per pixel     : %0.1f ns", total_ns / real'(n_out));
        $display("  wrote         : %s/gemm_out.txt", outdir);
        $display("-------------------------------------------------------");
        $display("next: python3 score_results.py");

        $finish;
    end

    // Safety timeout (scaled for a full image; raise if STREAM_LEN is large).
    initial begin
        #2_000_000_000;
        $display("FAIL: timeout -- image too large for this run?");
        $finish;
    end

endmodule
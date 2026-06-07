// =============================================================================
// tb_stoch_gemm_hybrid.sv
// Testbench for stoch_gemm_top_hybrid + stoch_systolic_array_hybrid + stoch_pe_hybrid.
//
// What it does
//   1. Generates a synthetic Gaussian-blur convolution operand set (K=9
//      3x3 kernel taps and N=8 patches per term) directly in the testbench,
//      OR optionally loads patches/kernel from $readmemh files.
//   2. Drives the hybrid GEMM top via its core_start / k_len / core_a_bin
//      / core_b_bin interface, simulating what the AXI-Stream wrapper would
//      do in real hardware.
//   3. Waits for core_done, reads N*N c_flat values out of core_c_flat,
//      and writes them to gemm_hybrid_out.txt as signed decimal numbers,
//      one per line, in row-major (i*N+j) order.
//   4. Also writes meta info to result_meta.txt so the Python scorer knows
//      what STREAM_LEN_RESIDUE was used at sim time.
//
// To switch from synthetic to file-based stimulus, define USE_FILE_STIMULUS
// at compile time. The files are expected at stoch_imgtest/patches.txt
// and stoch_imgtest/kernel.txt (same format as the original tb_stoch_image.sv).
// =============================================================================

`timescale 1ns/1ps

module tb_stoch_gemm_hybrid;

    // ---- Parameters (must match the DUT) ---------------------------------
    localparam int N                  = 8;
    localparam int WIDTH              = 16;
    localparam int K                  = 9;
    localparam int K_SAR_BITS         = 8;
    localparam int SAR_BIT_LEN        = 32;
    localparam int STREAM_LEN_RESIDUE = 65536;
    localparam int RESW               = WIDTH + 2;

    localparam time CLK_PERIOD = 10ns;

    // ---- DUT signals -----------------------------------------------------
    logic                          clk;
    logic                          rst_n;
    logic                          core_start;
    logic [$clog2(64+1)-1:0]       k_len;
    logic                          core_busy;
    logic                          core_done;
    logic [$clog2(64)-1:0]         core_kidx;
    logic                          core_load_k;
    logic [N*WIDTH-1:0]            core_a_bin;
    logic [N*WIDTH-1:0]            core_b_bin;
    logic signed [N*N*RESW-1:0]    core_c_flat;

    // ---- Clock -----------------------------------------------------------
    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ---- DUT -------------------------------------------------------------
    stoch_gemm_top_hybrid #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(WIDTH),
        .K_SAR_BITS(K_SAR_BITS),
        .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE),
        .KMAX(64), .RESW(RESW)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .core_start (core_start),
        .k_len      (k_len),
        .core_busy  (core_busy),
        .core_done  (core_done),
        .core_kidx  (core_kidx),
        .core_load_k(core_load_k),
        .core_a_bin (core_a_bin),
        .core_b_bin (core_b_bin),
        .core_c_flat(core_c_flat)
    );

    // ---- Operand storage -------------------------------------------------
    // For each term k, store the K a-operands and K b-operands.
    logic [WIDTH-1:0] a_table [K][N];
    logic [WIDTH-1:0] b_table [K][N];

    // Drive a_bin/b_bin based on the current term index.
    always_comb begin
        for (int li = 0; li < N; li++) begin
            core_a_bin[li*WIDTH +: WIDTH] = a_table[core_kidx][li];
            core_b_bin[li*WIDTH +: WIDTH] = b_table[core_kidx][li];
        end
    end

    // ---- Encoding helpers ------------------------------------------------
    function automatic logic [WIDTH-1:0] enc(input real x);
        // x in [-1, +1] -> binary_in = round((x+1)/2 * 2^WIDTH)
        real q;
        int  qi;
        q = (x + 1.0) / 2.0 * (real'(1 << WIDTH));
        qi = int'(q);
        if (qi < 0)                       qi = 0;
        else if (qi > ((1 << WIDTH) - 1)) qi = (1 << WIDTH) - 1;
        return WIDTH'(qi);
    endfunction

    // ---- Stimulus --------------------------------------------------------
    // Test image: 8x8 horizontal gradient with c*32 in each column.
    // Convolved with 3x3 Gaussian kernel [1,2,1;2,4,2;1,2,1] / 16.
    int img [8][8];
    real kern [K];
    real kmax;
    real pix_norm;
    real expected [N];

    initial begin
        // Build the test image.
        for (int r = 0; r < 8; r++)
            for (int c = 0; c < 8; c++)
                img[r][c] = c * 32;

        // Kernel taps (normalised by kmax=4 so each tap in [0, 1]).
        kmax = 4.0;
        kern[0] = 1.0/kmax;  kern[1] = 2.0/kmax;  kern[2] = 1.0/kmax;
        kern[3] = 2.0/kmax;  kern[4] = 4.0/kmax;  kern[5] = 2.0/kmax;
        kern[6] = 1.0/kmax;  kern[7] = 2.0/kmax;  kern[8] = 1.0/kmax;

        pix_norm = 255.0;

        // Build operand tables for tile = row 0 (output pixels 0..7).
        // a (broadcast across rows) = kernel tap k.
        // b (per column) = patch pixel for output i and tap k.
        begin
            int dr [9] = '{-1,-1,-1, 0, 0, 0, 1, 1, 1};
            int dc [9] = '{-1, 0, 1,-1, 0, 1,-1, 0, 1};
            for (int k = 0; k < K; k++) begin
                for (int li = 0; li < N; li++) begin
                    int rr, cc, pix;
                    rr = 0 + dr[k];
                    cc = li + dc[k];
                    if (rr < 0 || rr >= 8 || cc < 0 || cc >= 8) pix = 0;
                    else                                         pix = img[rr][cc];
                    a_table[k][li] = enc(kern[k]);        // broadcast
                    b_table[k][li] = enc(real'(pix) / pix_norm);
                end
            end
        end

        // Software reference (for the printout only; the Python scorer
        // will recompute it as well).
        for (int i = 0; i < N; i++) begin
            real acc;
            int dr [9] = '{-1,-1,-1, 0, 0, 0, 1, 1, 1};
            int dc [9] = '{-1, 0, 1,-1, 0, 1,-1, 0, 1};
            acc = 0.0;
            for (int k = 0; k < K; k++) begin
                int rr, cc, pix;
                rr = 0 + dr[k];
                cc = i + dc[k];
                if (rr < 0 || rr >= 8 || cc < 0 || cc >= 8) pix = 0;
                else                                         pix = img[rr][cc];
                acc = acc + kern[k] * (real'(pix) / pix_norm);
            end
            expected[i] = acc;
        end

        // Run the tile.
        rst_n      = 0;
        core_start = 0;
        k_len      = K;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("------------------------------------------------------------");
        $display(" Stochastic GEMM HYBRID test");
        $display("   N=%0d  K=%0d  WIDTH=%0d", N, K, WIDTH);
        $display("   K_SAR_BITS=%0d  SAR_BIT_LEN=%0d", K_SAR_BITS, SAR_BIT_LEN);
        $display("   STREAM_LEN_RESIDUE=%0d", STREAM_LEN_RESIDUE);
        $display("   Expected tile cycles:");
        $display("     SAR    = %0d", K_SAR_BITS * K * SAR_BIT_LEN);
        $display("     RES    = %0d", STREAM_LEN_RESIDUE);
        $display("     total ~= %0d", K_SAR_BITS * K * SAR_BIT_LEN + STREAM_LEN_RESIDUE);
        $display("------------------------------------------------------------");

        @(posedge clk);
        core_start <= 1;
        @(posedge clk);
        core_start <= 0;

        // Wait for done.
        wait (core_done == 1'b1);
        @(posedge clk);

        // Read results and write to file.
        begin
            int fout;
            int errors;
            real psnr_mse;
            real hw_pix, sw_pix, err_pix;
            logic signed [RESW-1:0] cv;

            fout = $fopen("gemm_hybrid_out.txt", "w");
            if (fout == 0) begin $display("FATAL: cannot open output file"); $finish; end

            errors = 0;
            psnr_mse = 0.0;
            $display("");
            $display(" pixel   c_flat   hw_pix    sw_pix    abs_err");
            for (int i = 0; i < N; i++) begin
                cv = core_c_flat[(0*N+i)*RESW +: RESW];  // row 0, col i
                $fwrite(fout, "%0d\n", $signed(cv));
                // Mapping back to a real "pixel" value for printout:
                //   real_value = c_flat * scale
                //   where scale is the inverse of the encoding chain.
                // The hybrid's internal scaling places the bipolar sum into
                // [-2^(WIDTH-1), 2^(WIDTH-1)-1]. To convert back to a sum
                // of bipolar products: divide by (2^(WIDTH-1) / K).
                // hw_pix is the bipolar SUM of products over K terms.
                // cv/2^(WIDTH-1) is the per-term average; multiply by K
                // to get the sum. expected[i] already IS the sum
                // (sum_k(kern_k/kmax * pix_k/255)), so no extra K factor.
                hw_pix = real'(cv) / real'(1 << (WIDTH-1)) * real'(K);
                sw_pix = expected[i];
                err_pix = (hw_pix > sw_pix) ? (hw_pix - sw_pix) : (sw_pix - hw_pix);
                psnr_mse = psnr_mse + err_pix * err_pix;
                $display(" %4d   %8d   %7.4f   %7.4f   %7.4f",
                         i, $signed(cv), hw_pix, sw_pix, err_pix);
            end
            $fclose(fout);

            // Also write the meta file the python scorer needs.
            fout = $fopen("result_meta.txt", "w");
            $fwrite(fout, "STREAM_LEN %0d\n", STREAM_LEN_RESIDUE);
            $fwrite(fout, "K %0d\n", K);
            $fwrite(fout, "WIDTH %0d\n", WIDTH);
            $fwrite(fout, "N %0d\n", N);
            $fwrite(fout, "K_SAR_BITS %0d\n", K_SAR_BITS);
            $fwrite(fout, "SAR_BIT_LEN %0d\n", SAR_BIT_LEN);
            $fclose(fout);

            psnr_mse = psnr_mse / real'(N);
            if (psnr_mse > 0.0) begin
                real psnr;
                psnr = 10.0 * $ln(real'(K)*real'(K) / psnr_mse) / $ln(10.0);
                $display("");
                $display(" tile PSNR (vs bipolar sum range [-K,+K]) = %0.2f dB", psnr);
            end else begin
                $display(" tile error = 0 (perfect match)");
            end

            $display(" wrote gemm_hybrid_out.txt + result_meta.txt");
            $display("------------------------------------------------------------");
        end

        $finish;
    end

    // Safety timeout.
    initial begin
        #(CLK_PERIOD * (STREAM_LEN_RESIDUE + K * K_SAR_BITS * SAR_BIT_LEN) * 4);
        $display("FATAL: testbench timeout");
        $finish;
    end

endmodule

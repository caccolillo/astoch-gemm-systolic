// =============================================================================
// tb_s2b_hybrid.sv
// Three-way comparison testbench for stochastic-to-binary converters at
// WIDTH=16, fixed (deterministic) per-conversion latency.
//
// DUTs (all driven by the SAME master stochastic stream)
//   1. s2b_counter  -- plain bit counter for HYBRID_TOTAL cycles
//                      (matches the hybrid's total latency for fair comparison)
//   2. s2b_sar      -- original SAR with geometric doubling
//                      ... NOTE: at WIDTH=16 this is *very* slow, so we run
//                      it with a small START_LEN so the sim completes in
//                      finite time. It will obviously be less accurate.
//   3. s2b_hybrid   -- new SAR + residue counter hybrid
//
// Sweep
//   At WIDTH=16 a full 65,536-point sweep would take hours. Use STEP to
//   subsample: STEP=256 -> 256 evenly spaced points. STEP=1 (full sweep)
//   only practical for WIDTH<=12.
//
// Output
//   s2b_hybrid_log.csv
//   header: input,cnt_out,cnt_err,sar_out,sar_err,hybrid_out,hybrid_err
// =============================================================================
`timescale 1ns/1ps

module tb_s2b_hybrid;

    // ---- Sweep / accuracy knobs ------------------------------------------
    localparam int WIDTH       = 16;

    // Hybrid configuration: 8 SAR bits, 8 residue bits.
    localparam int K_SAR_BITS         = 8;
    localparam int SAR_BIT_LEN        = 32;
    localparam int STREAM_LEN_RESIDUE = 65536;
    // Total cycles per hybrid conversion (used as time budget for others).
    localparam int HYBRID_TOTAL = K_SAR_BITS * SAR_BIT_LEN + STREAM_LEN_RESIDUE;

    // Plain SAR (original geometric doubling). Keep START_LEN small at
    // WIDTH=16 or it takes forever; total length = START_LEN*(2^WIDTH-1).
    localparam int SAR_START_LEN   = 1;   // sim-friendly; not statistically meaningful
    localparam int SAR_TOTAL_LEN   = SAR_START_LEN * ((1<<WIDTH) - 1);
    localparam int SAR_MAX_LEN     = 1 << $clog2(SAR_TOTAL_LEN + 1);

    // Plain counter total length = HYBRID_TOTAL for fair comparison.
    localparam int CNT_TOTAL_LEN   = HYBRID_TOTAL;
    localparam int CNT_W           = $clog2(CNT_TOTAL_LEN + 1);

    // Sweep stride: at WIDTH=16, 256 points is enough to see the curve.
    localparam int STEP    = (WIDTH >= 12) ? (1 << (WIDTH - 8)) : 1;
    localparam int N_STEPS = ((1<<WIDTH) + STEP - 1) / STEP;

    localparam time CLK_PERIOD = 10ns;

    // ---- Signals ---------------------------------------------------------
    logic               clk;
    logic               rst_n;
    logic [WIDTH-1:0]   input_fed;
    logic [WIDTH-1:0]   target_seed;
    logic [WIDTH-1:0]   sar_seed;
    logic [WIDTH-1:0]   hybrid_seed;
    logic               sng_enable;
    logic               stoch_target;

    logic                  cnt_start;
    logic                  cnt_done;
    logic [CNT_W-1:0]      cnt_raw;
    logic [WIDTH-1:0]      cnt_out;

    logic                  sar_start;
    logic                  sar_valid;
    logic [WIDTH-1:0]      sar_out;

    logic                  hybrid_start;
    logic                  hybrid_valid;
    logic [WIDTH-1:0]      hybrid_out;

    // ---- Clock -----------------------------------------------------------
    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ---- Master SNG (drives every DUT) -----------------------------------
    sng #(.WIDTH(WIDTH)) u_master_sng (
        .clk(clk), .rst_n(rst_n), .enable(sng_enable),
        .binary_in(input_fed), .seed(target_seed), .stoch_out(stoch_target)
    );

    // ---- Plain counter ---------------------------------------------------
    s2b_counter #(.STREAM_LEN(CNT_TOTAL_LEN)) u_cnt (
        .clk(clk), .rst_n(rst_n), .start(cnt_start),
        .stoch_in(stoch_target), .binary_out(cnt_raw), .done(cnt_done)
    );
    // Scale cnt_raw to WIDTH bits:
    always_comb begin
        logic [63:0] tmp;
        tmp     = (64'(cnt_raw) * 64'((1 << WIDTH) - 1) + 64'(CNT_TOTAL_LEN/2))
                / 64'(CNT_TOTAL_LEN);
        cnt_out = tmp[WIDTH-1:0];
    end

    // ---- Original SAR ----------------------------------------------------
    s2b_sar #(.WIDTH(WIDTH), .START_LEN(SAR_START_LEN), .MAX_LEN(SAR_MAX_LEN)) u_sar (
        .clk(clk), .rst_n(rst_n), .start(sar_start),
        .stoch_target(stoch_target), .sng_seed(sar_seed),
        .binary_out(sar_out), .valid(sar_valid)
    );

    // ---- Hybrid ----------------------------------------------------------
    s2b_hybrid #(
        .WIDTH(WIDTH),
        .K_SAR_BITS(K_SAR_BITS),
        .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE)
    ) u_hybrid (
        .clk(clk), .rst_n(rst_n), .start(hybrid_start),
        .stoch_target(stoch_target), .sng_seed(hybrid_seed),
        .binary_out(hybrid_out), .valid(hybrid_valid)
    );

    // ---- Latched done flags ---------------------------------------------
    logic cnt_done_l, sar_valid_l, hybrid_valid_l;
    logic clear_l;
    always_ff @(posedge clk) begin
        if (!rst_n || clear_l) begin
            cnt_done_l     <= 0;
            sar_valid_l    <= 0;
            hybrid_valid_l <= 0;
        end else begin
            if (cnt_done)     cnt_done_l     <= 1;
            if (sar_valid)    sar_valid_l    <= 1;
            if (hybrid_valid) hybrid_valid_l <= 1;
        end
    end

    // ---- Test loop -------------------------------------------------------
    int fout;
    int num_steps;
    longint sar_sq, cnt_sq, hybrid_sq;
    int sar_max, cnt_max, hybrid_max;

    initial begin
        rst_n          = 0;
        input_fed      = 0;
        target_seed    = 16'h1DE3;
        sar_seed       = 16'hE2A1;
        hybrid_seed    = 16'h4B5C;
        sng_enable     = 0;
        cnt_start      = 0;
        sar_start      = 0;
        hybrid_start   = 0;
        clear_l        = 0;
        sar_sq    = 0; cnt_sq    = 0; hybrid_sq    = 0;
        sar_max   = 0; cnt_max   = 0; hybrid_max   = 0;
        num_steps = 0;

        repeat(5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fout = $fopen("s2b_hybrid_log.csv", "w");
        if (fout == 0) begin $display("FATAL: cannot open log"); $finish; end
        $fwrite(fout, "input,cnt_out,cnt_err,sar_out,sar_err,hybrid_out,hybrid_err\n");

        $display("\n================================================================");
        $display(" HYBRID SWEEP -- WIDTH=%0d, fixed latency comparison", WIDTH);
        $display("   HYBRID total cycles      : %0d   (SAR %0d bits x %0d + residue %0d)",
                 HYBRID_TOTAL, K_SAR_BITS, SAR_BIT_LEN, STREAM_LEN_RESIDUE);
        $display("   Plain counter cycles     : %0d   (matched)", CNT_TOTAL_LEN);
        $display("   Original SAR cycles      : %0d   (START_LEN=%0d -- short sim demo)",
                 SAR_TOTAL_LEN, SAR_START_LEN);
        $display("   sweep stride / N_STEPS   : %0d / %0d", STEP, N_STEPS);
        $display("================================================================");

        for (int idx = 0; idx < (1<<WIDTH); idx += STEP) begin
            int sar_err, cnt_err, hybrid_err;

            input_fed = idx[WIDTH-1:0];

            // Reset all DUTs.
            sng_enable   = 0;
            cnt_start    = 0;
            sar_start    = 0;
            hybrid_start = 0;
            clear_l      = 1;
            rst_n        = 0;
            repeat(5) @(posedge clk);
            rst_n   = 1;
            repeat(2) @(posedge clk);
            clear_l = 0;

            // Start: SNG running, then pulse all three start signals.
            sng_enable = 1;
            @(posedge clk);
            cnt_start    = 1;
            sar_start    = 1;
            hybrid_start = 1;
            @(posedge clk);
            cnt_start    = 0;
            sar_start    = 0;
            hybrid_start = 0;

            // Wait until ALL THREE are done.
            begin
                int timeout_ctr;
                timeout_ctr = 0;
                while (!cnt_done_l || !sar_valid_l || !hybrid_valid_l) begin
                    @(posedge clk);
                    timeout_ctr++;
                    if (timeout_ctr > (HYBRID_TOTAL + SAR_TOTAL_LEN) * 8) begin
                        $display("TIMEOUT idx=%0d c=%b s=%b h=%b", idx,
                                 cnt_done_l, sar_valid_l, hybrid_valid_l);
                        $finish;
                    end
                end
            end

            sng_enable = 0;

            sar_err    = (sar_out    >= input_fed) ? int'(sar_out)    - int'(input_fed) : int'(input_fed) - int'(sar_out);
            cnt_err    = (cnt_out    >= input_fed) ? int'(cnt_out)    - int'(input_fed) : int'(input_fed) - int'(cnt_out);
            hybrid_err = (hybrid_out >= input_fed) ? int'(hybrid_out) - int'(input_fed) : int'(input_fed) - int'(hybrid_out);

            sar_sq    += sar_err    * sar_err;
            cnt_sq    += cnt_err    * cnt_err;
            hybrid_sq += hybrid_err * hybrid_err;
            if (sar_err    > sar_max)    sar_max    = sar_err;
            if (cnt_err    > cnt_max)    cnt_max    = cnt_err;
            if (hybrid_err > hybrid_max) hybrid_max = hybrid_err;
            num_steps++;

            $fwrite(fout, "%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    input_fed, cnt_out, cnt_err, sar_out, sar_err,
                    hybrid_out, hybrid_err);

            if (num_steps <= 16 || (num_steps & 31) == 0)
                $display(" step=%4d in=%6d  cnt=%6d(%4d)  sar=%6d(%4d)  hybrid=%6d(%4d)",
                         num_steps, input_fed, cnt_out, cnt_err,
                         sar_out, sar_err, hybrid_out, hybrid_err);
        end

        $fclose(fout);

        $display("================================================================");
        $display(" SUMMARY  (%0d sweep points, WIDTH=%0d)", num_steps, WIDTH);
        $display("   Counter (%0d cy) : max=%0d  rmse=%.2f",
                 CNT_TOTAL_LEN, cnt_max,    $sqrt(real'(cnt_sq)/num_steps));
        $display("   SAR     (%0d cy) : max=%0d  rmse=%.2f",
                 SAR_TOTAL_LEN, sar_max,    $sqrt(real'(sar_sq)/num_steps));
        $display("   Hybrid  (%0d cy) : max=%0d  rmse=%.2f",
                 HYBRID_TOTAL,  hybrid_max, $sqrt(real'(hybrid_sq)/num_steps));
        $display("================================================================");
        $display(" wrote s2b_hybrid_log.csv");
        $display("================================================================\n");
        $finish;
    end

    // Safety timeout for the whole sim.
    initial begin
        #(CLK_PERIOD * (HYBRID_TOTAL + SAR_TOTAL_LEN) * N_STEPS * 4);
        $display("FATAL: global timeout");
        $finish;
    end

endmodule

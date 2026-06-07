// =============================================================================
// tb_s2b_compare.sv
// Head-to-head fair comparison of:
//   * s2b_counter -- plain bit counter
//   * s2b_sar     -- successive-approximation converter (progressive window)
//
// Test method
//   Both converters are driven by the SAME master SNG and receive the SAME
//   stochastic bit stream simultaneously. Each conversion runs for the SAME
//   total number of clock cycles -- determined by the SAR's progressive
//   window total START_LEN * (2^WIDTH - 1). The plain counter runs for the
//   same total length so the comparison is per-cycle fair.
//
// Sweep
//   Every WIDTH-bit input value 0..2^WIDTH-1 is run once. Each row of the
//   output log records:
//      input, sar_out, sar_err, counter_out, counter_err
//
// Output
//   s2b_compare_log.csv  (header + one row per input value)
//   Read by score_s2b_compare.py to plot the two error curves.
//
// Parameters tuned to match: at WIDTH=16, START_LEN*255 cycles per conversion.
// Default WIDTH=8 for fast sim; override on the command line for the full
// 16-bit sweep when ready.
// =============================================================================

`timescale 1ns/1ps

module tb_s2b_compare;

    // ---- Sweep / accuracy knobs -------------------------------------------
    // WIDTH=8 gives 256 sweep steps (~5s sim).
    // WIDTH=16 gives 65536 steps and is the production sweep but is slow.
    localparam int WIDTH     = 10;
    localparam int START_LEN = 128;    // SAR MSB window (small for fast first-run sanity test)
    // Total cycles per conversion (used for the plain counter too).
    localparam int TOTAL_LEN = START_LEN * ((1<<WIDTH) - 1);
    // CNT_W must hold count up to TOTAL_LEN
    localparam int CNT_W     = $clog2(TOTAL_LEN + 1);
    localparam int MAX_LEN   = 1 << (CNT_W);

    // Sweep stride. STEP=1 covers every input value; STEP>1 gives a
    // statistically representative subsample. For WIDTH>=12 the full sweep
    // is too slow, so default to a 256-point subsample.
    localparam int STEP = (WIDTH >= 12) ? (1 << (WIDTH - 8)) : 1;
    localparam int N_STEPS = ((1<<WIDTH) + STEP - 1) / STEP;

    localparam time CLK_PERIOD = 10ns;

    // ---- DUT signals -------------------------------------------------------
    logic             clk;
    logic             rst_n;
    logic [WIDTH-1:0] input_fed;
    logic [WIDTH-1:0] target_seed;
    logic [WIDTH-1:0] sar_seed;
    logic             sng_enable;
    logic             stoch_target;

    // SAR
    logic             sar_start;
    logic             sar_valid;
    logic [WIDTH-1:0] sar_out;

    // Counter
    logic                  cnt_start;
    logic                  cnt_done;
    logic [CNT_W-1:0]      cnt_raw;
    logic [WIDTH-1:0]      cnt_out;   // scaled to WIDTH bits

    // Latched done flags -- the DUTs assert their done/valid for a single
    // cycle; latch them so the wait loop can see them without race.
    logic sar_valid_latched;
    logic cnt_done_latched;
    logic clear_latches;

    always_ff @(posedge clk) begin
        if (!rst_n || clear_latches) begin
            sar_valid_latched <= 1'b0;
            cnt_done_latched  <= 1'b0;
        end else begin
            if (sar_valid) sar_valid_latched <= 1'b1;
            if (cnt_done)  cnt_done_latched  <= 1'b1;
        end
    end

    // ---- Clock -------------------------------------------------------------
    initial begin
        clk = 0; forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ---- Master SNG (drives BOTH converters) ------------------------------
    sng #(.WIDTH(WIDTH)) u_master_sng (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (sng_enable),
        .binary_in(input_fed),
        .seed     (target_seed),
        .stoch_out(stoch_target)
    );

    // ---- SAR converter ----------------------------------------------------
    s2b_sar #(
        .WIDTH    (WIDTH),
        .START_LEN(START_LEN),
        .MAX_LEN  (MAX_LEN)
    ) u_sar (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (sar_start),
        .stoch_target(stoch_target),
        .sng_seed    (sar_seed),
        .binary_out  (sar_out),
        .valid       (sar_valid)
    );

    // ---- Plain counter, same total integration ---------------------------
    s2b_counter #(
        .STREAM_LEN(TOTAL_LEN)
    ) u_counter (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (cnt_start),
        .stoch_in  (stoch_target),
        .binary_out(cnt_raw),
        .done      (cnt_done)
    );

    // Scale the counter's raw count back to a WIDTH-bit value:
    //   cnt_raw is in [0, TOTAL_LEN]
    //   binary equivalent = round(cnt_raw / TOTAL_LEN * (2^WIDTH - 1))
    // Implement as cnt_raw * (2^WIDTH - 1) / TOTAL_LEN with integer math.
    always_comb begin
        // Use a 64-bit intermediate to avoid overflow at high WIDTH/TOTAL_LEN.
        logic [63:0] tmp;
        tmp     = (64'(cnt_raw) * 64'((1 << WIDTH) - 1) + 64'(TOTAL_LEN/2)) / 64'(TOTAL_LEN);
        cnt_out = tmp[WIDTH-1:0];
    end

    // ---- Output log file --------------------------------------------------
    int   fout;
    int   sar_err, cnt_err;
    int   sar_total_sq, cnt_total_sq;   // for RMSE
    int   sar_max, cnt_max;
    int   num_steps;

    initial begin
        rst_n        = 0;
        input_fed    = 0;
        target_seed  = 8'h1D;
        sar_seed     = 8'hE2;
        sng_enable   = 0;
        sar_start    = 0;
        cnt_start    = 0;
        clear_latches = 0;
        sar_total_sq = 0;
        cnt_total_sq = 0;
        sar_max      = 0;
        cnt_max      = 0;
        num_steps    = 0;

        repeat(5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Open the CSV.
        fout = $fopen("s2b_compare_log.csv", "w");
        if (fout == 0) begin
            $display("FATAL: cannot open s2b_compare_log.csv");
            $finish;
        end
        $fwrite(fout, "input,sar_out,sar_err,counter_out,counter_err\n");

        $display("\n================================================================");
        $display(" S2B COMPARISON SWEEP");
        $display("   WIDTH       : %0d", WIDTH);
        $display("   START_LEN   : %0d (SAR MSB window)", START_LEN);
        $display("   TOTAL_LEN   : %0d cycles (matched plain-counter length)",
                 TOTAL_LEN);
        $display("   sweep stride: %0d  (over 0..%0d)", STEP, (1<<WIDTH)-1);
        $display("   sweep steps : %0d", N_STEPS);
        $display("================================================================");

        // Sweep at fixed stride (STEP declared at module scope).
        for (int idx = 0; idx < (1<<WIDTH); idx += STEP) begin
            input_fed = idx[WIDTH-1:0];

            // Reset both DUTs per step -- hold reset for several clocks to
            // guarantee internal FSMs return to IDLE.
            // Clear the latched done flags before starting the new conversion.
            sng_enable    = 0;
            sar_start     = 0;
            cnt_start     = 0;
            clear_latches = 1;
            rst_n         = 0;
            repeat(5) @(posedge clk);
            rst_n = 1;
            repeat(2) @(posedge clk);

            // Drop clear_latches so the next done pulse will latch.
            clear_latches = 0;
            // Now arm everything in the same clock edge.
            // sng_enable goes high BEFORE start, so the SNG is producing
            // valid bits when the counter first samples.
            sng_enable = 1;
            @(posedge clk);
            sar_start  = 1;
            cnt_start  = 1;
            @(posedge clk);
            sar_start  = 0;
            cnt_start  = 0;

            // Wait until both converters complete with a hard timeout.
            // We poll the LATCHED versions because sar_valid/cnt_done are
            // one-cycle pulses and would be missed by a per-clock poll.
            begin
                int timeout_ctr;
                timeout_ctr = 0;
                while (!sar_valid_latched || !cnt_done_latched) begin
                    @(posedge clk);
                    timeout_ctr++;
                    if (timeout_ctr > TOTAL_LEN * 4) begin
                        $display("TIMEOUT idx=%0d sar_v_l=%b cnt_d_l=%b after %0d cycles (TOTAL_LEN=%0d)", idx, sar_valid_latched, cnt_done_latched, timeout_ctr, TOTAL_LEN);
                        $display("  in=%0d stoch=%b sng_en=%b rst_n=%b sar_out=%0d cnt_raw=%0d", input_fed, stoch_target, sng_enable, rst_n, sar_out, cnt_raw);
                        $finish;
                    end
                end
            end

            sng_enable = 0;

            sar_err = (sar_out >= input_fed)
                    ? int'(sar_out) - int'(input_fed)
                    : int'(input_fed) - int'(sar_out);
            cnt_err = (cnt_out >= input_fed)
                    ? int'(cnt_out) - int'(input_fed)
                    : int'(input_fed) - int'(cnt_out);

            sar_total_sq += sar_err * sar_err;
            cnt_total_sq += cnt_err * cnt_err;
            if (sar_err > sar_max) sar_max = sar_err;
            if (cnt_err > cnt_max) cnt_max = cnt_err;
            num_steps += 1;

            $fwrite(fout, "%0d,%0d,%0d,%0d,%0d\n",
                    input_fed, sar_out, sar_err, cnt_out, cnt_err);

            // Print first 16 steps, then every 8th for log brevity
            if (idx < 16 || (idx & 7) == 0)
                $display(" idx=%4d  in=%3d  sar=%3d (err=%3d)  cnt=%3d (err=%3d)",
                         idx, input_fed, sar_out, sar_err, cnt_out, cnt_err);
        end

        $fclose(fout);

        $display("================================================================");
        $display(" SUMMARY (over %0d sweep points)", num_steps);
        $display("   SAR     : max_err=%0d  rmse=%.2f",
                 sar_max, $sqrt(real'(sar_total_sq)/real'(num_steps)));
        $display("   COUNTER : max_err=%0d  rmse=%.2f",
                 cnt_max, $sqrt(real'(cnt_total_sq)/real'(num_steps)));
        $display(" wrote s2b_compare_log.csv");
        $display("================================================================\n");
        $finish;
    end

    // Safety timeout.
    initial begin
        #(CLK_PERIOD * TOTAL_LEN * (1<<WIDTH) * 4);
        $display("FATAL: timeout");
        $finish;
    end

endmodule

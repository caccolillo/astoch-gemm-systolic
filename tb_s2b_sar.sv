// =============================================================================
// File Name     : tb_s2b_sar.sv
// Description   : Sweep testbench for s2b_sar (SAR stochastic-to-binary
//                 converter with progressive variable-window scaling).
//                 Drives the converter via a master SNG, sweeps input values
//                 0..2^WIDTH-1, and reports the absolute conversion error.
//
// Updated from the original to match the revised s2b_sar interface:
//   OLD: .STREAM_LEN(N)          -- fixed window per bit
//   NEW: .START_LEN(N)           -- window for the MSB (doubles each step)
//        .MAX_LEN(M)             -- ceiling on the window growth
//
// START_LEN / MAX_LEN choice:
//   The progressive window scheme uses START_LEN for the MSB and doubles it
//   each bit step. Total integration per conversion:
//     sum_{k=0}^{WIDTH-1} START_LEN * 2^k  = START_LEN * (2^WIDTH - 1)
//   For WIDTH=8: total = START_LEN * 255.
//   The original testbench used STREAM_LEN=65536*40=2,621,440 as a fixed
//   window. Matching the same total work: START_LEN = 2621440/255 ~= 10280.
//   We round to START_LEN=8192 (a clean power-of-two-friendly value) so the
//   doubling stays aligned. MAX_LEN must be >= START_LEN << (WIDTH-1) =
//   8192 * 128 = 1,048,576 -- use 2097152 (2^21) for headroom.
//
// Sweep direction: 0 to 2^WIDTH-1 ascending (original was backwards and
//   included an out-of-range index=256 for WIDTH=8).
// =============================================================================

`timescale 1ns/1ps

module tb_sar_only_sweep;

    localparam int WIDTH      = 8;
    localparam int START_LEN  = 8192;           // MSB integration window
    localparam int MAX_LEN    = 2097152;         // 2^21; >= START_LEN<<(WIDTH-1)
    localparam time CLK_PERIOD = 10ns;

    // Global testbench controls
    logic             clk;
    logic             rst_n;
    logic [WIDTH-1:0] input_fed;
    logic [WIDTH-1:0] target_sng_seed;
    logic [WIDTH-1:0] sar_sng_seed;
    logic             sng_enable;

    // Master stochastic bitstream
    logic             stoch_target;

    // SAR converter interface
    logic             sar_start;
    logic             sar_valid;
    logic [WIDTH-1:0] sar_binary_out;

    // Error tracking
    int               abs_error;
    int               total_error;
    int               max_error;
    int               num_steps;

    // =========================================================================
    // Clock generator
    // =========================================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // =========================================================================
    // Master SNG (feeds the SAR input stream)
    // =========================================================================
    sng #(.WIDTH(WIDTH)) u_master_target_sng (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (sng_enable),
        .binary_in(input_fed),
        .seed     (target_sng_seed),
        .stoch_out(stoch_target)
    );

    // =========================================================================
    // SAR converter under test
    // =========================================================================
    s2b_sar #(
        .WIDTH    (WIDTH),
        .START_LEN(START_LEN),
        .MAX_LEN  (MAX_LEN)
    ) u_sar_converter (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (sar_start),
        .stoch_target(stoch_target),
        .sng_seed    (sar_sng_seed),
        .binary_out  (sar_binary_out),
        .valid       (sar_valid)
    );

    // =========================================================================
    // Sweep loop
    // =========================================================================
    initial begin
        rst_n           = 1'b0;
        input_fed       = '0;
        target_sng_seed = 8'h1D;
        sar_sng_seed    = 8'hE2;
        sng_enable      = 1'b0;
        sar_start       = 1'b0;
        total_error     = 0;
        max_error       = 0;
        num_steps       = 0;

        repeat(5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        $display("\n================================================================");
        $display("  SAR S2B SWEEP  WIDTH=%0d  START_LEN=%0d  MAX_LEN=%0d",
                 WIDTH, START_LEN, MAX_LEN);
        $display("  Total integration per conversion: %0d cycles",
                 START_LEN * ((1<<WIDTH)-1));
        $display("================================================================");
        $display("  INPUT | SAR OUT | ABS ERROR");
        $display("----------------------------------------------------------------");

        // Sweep 0..2^WIDTH-1 inclusive, ascending.
        for (int idx = 0; idx < (1<<WIDTH); idx++) begin

            input_fed = idx[WIDTH-1:0];

            // Reset per step to keep SNG properties aligned.
            rst_n = 1'b0;
            #(CLK_PERIOD);
            rst_n = 1'b1;
            @(posedge clk);

            // Arm the system.
            sng_enable = 1'b1;
            sar_start  = 1'b1;
            @(posedge clk);
            sar_start  = 1'b0;

            // Wait for conversion to complete.
            while (!sar_valid) @(posedge clk);

            sng_enable = 1'b0;

            // Compute error.
            abs_error = (sar_binary_out >= input_fed)
                      ? int'(sar_binary_out) - int'(input_fed)
                      : int'(input_fed)      - int'(sar_binary_out);

            total_error += abs_error;
            num_steps   += 1;
            if (abs_error > max_error) max_error = abs_error;

            $display("   %3d  |   %3d   |   %3d", input_fed, sar_binary_out, abs_error);
        end

        $display("================================================================");
        $display("  SUMMARY  steps=%0d  max_err=%0d  mean_err=%.2f",
                 num_steps, max_error, real'(total_error)/real'(num_steps));
        $display("================================================================\n");
        $finish;
    end

    // Safety timeout: START_LEN*(2^WIDTH-1) per step, 256 steps + overhead.
    // At 10 ns/cycle: 8192*255*256*10ns = ~5.4 seconds -- allow generous margin.
    initial begin
        #(CLK_PERIOD * START_LEN * ((1<<WIDTH)-1) * (1<<WIDTH) * 4);
        $display("FATAL: simulation timeout -- check SAR FSM");
        $finish;
    end

endmodule

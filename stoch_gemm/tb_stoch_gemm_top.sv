`timescale 1ns/1ps

// =============================================================================
// tb_stoch_gemm_top.sv
// Self-checking testbench for stoch_gemm_top.
//
// Stochastic computing is APPROXIMATE: the result of an L-bit bipolar GEMM
// has a statistical error ~ O(1/sqrt(L)). The testbench therefore does NOT
// check for an exact match -- it computes the ideal real-valued GEMM and
// checks that every stochastic output lands within a tolerance band.
//
// Reset convention: synchronous, active-HIGH.
//
// Value encoding
//   Real operands a, b are chosen in [-1, +1]. They are offset-encoded for
//   the SNG as  bin = round((x+1)/2 * 2^WIDTH), clamped to [0, 2^WIDTH-1].
//   The DUT returns, per element, the signed numerator (2*cnt - K*L); the
//   real result estimate is numerator / STREAM_LEN.
// =============================================================================

module tb_stoch_gemm_top;

    // ---- Tunable knobs ------------------------------------------------------
    // STREAM_LEN  : stochastic bits streamed per contraction term. Sets the
    //               conversion time (~ K * STREAM_LEN cycles per tile) AND the
    //               accuracy: stochastic error scales ~ 1/sqrt(STREAM_LEN), so
    //               4x the stream length roughly halves the error. Must stay
    //               below the DUT LFSR period (default LFSR_W=16 -> 65535).
    // TOL         : absolute pass/fail threshold per output element. This is a
    //               CHECK only -- it does not change accuracy. Tightening TOL
    //               without also raising STREAM_LEN will make the test fail.
    //               Rough guide at K=6, WIDTH=8: STREAM_LEN 1024 -> err ~0.24,
    //               4096 -> ~0.12, 16384 -> ~0.06. WIDTH=8 quantises operands
    //               to 1/256, which floors achievable error near ~0.03-0.05.
    // K           : contraction depth exercised by this test.
    localparam int  N          = 8;
    localparam int  WIDTH      = 16;
    localparam int  STREAM_LEN = 1024;
    localparam real TOL        = 0.25;
    localparam int  KW         = 16;
    localparam int  K          = 6;

    // ---- Clock --------------------------------------------------------------
    // Target a 200 MHz fabric clock -> 5.0 ns period. This is a plausible
    // target on the Ultra96-V2 ZU3EG: the stochastic PE is shallow logic (one
    // XNOR + a counter increment), so the critical path is the SNG LFSR
    // feedback or the ~CNTW-bit counter carry chain -- both comfortable at
    // 5 ns. NOTE: simulation cannot prove f_max; only a Vivado static-timing
    // report can. CLK_PERIOD_NS is used purely to translate the measured
    // cycle count into a wall-clock conversion time.
    localparam real CLK_PERIOD_NS = 5.0;            // 200 MHz
    localparam real CLK_FREQ_MHZ  = 1000.0 / CLK_PERIOD_NS;

    // Mirror the DUT's derived widths.
    localparam int CNTW = $clog2((1<<KW)-1) + $clog2(STREAM_LEN + 1) + 1;
    localparam int RESW = CNTW + 2;

    logic                 clk, rst;
    logic                 start;
    logic [KW-1:0]         k_len;
    logic [N*WIDTH-1:0]    a_bin, b_bin;
    logic                  load_k, busy, done;
    logic [KW-1:0]         k_idx;
    logic [N*N*RESW-1:0]   c_flat;

    stoch_gemm_top #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(16), .STREAM_LEN(STREAM_LEN), .KW(KW)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .k_len(k_len),
        .a_bin(a_bin), .b_bin(b_bin),
        .load_k(load_k), .k_idx(k_idx), .busy(busy), .done(done), .c_flat(c_flat)
    );

    initial clk = 0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // ---- Real-valued operand storage ---------------------------------------
    // A[i][k], B[k][j] as reals in [-1, +1].
    real a_real [N][K];
    real b_real [K][N];
    real c_ideal [N][N];

    // Offset-encode a real x in [-1,1] to a WIDTH-bit unsigned SNG input.
    function automatic logic [WIDTH-1:0] enc (input real x);
        real scaled;
        int  q;
        logic [WIDTH-1:0] r;
        scaled = (x + 1.0) / 2.0 * (2.0 ** WIDTH);
        q = $rtoi(scaled);
        if (q < 0)              q = 0;
        if (q > (2**WIDTH) - 1) q = (2**WIDTH) - 1;
        r = q[WIDTH-1:0];
        return r;
    endfunction

    // ---- Operand feeder ----------------------------------------------------
    // The DUT exposes 'k_idx' = the contraction term it currently wants. The
    // feeder presents that term, registered for stable setup. The encoded
    // values are first gathered into a plain bit vector, then assigned in one
    // shot -- this avoids Icarus quirks with logic-typed indices into unpacked
    // arrays and with array part-selects inside an always block.
    int             ksel;
    logic [N*WIDTH-1:0] a_bin_nx, b_bin_nx;

    always_comb begin
        ksel     = int'(k_idx);
        a_bin_nx = '0;
        b_bin_nx = '0;
        if (ksel < K) begin
            for (int i = 0; i < N; i++) begin
                a_bin_nx[i*WIDTH +: WIDTH] = enc(a_real[i][ksel]);
                b_bin_nx[i*WIDTH +: WIDTH] = enc(b_real[ksel][i]);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            a_bin <= '0;
            b_bin <= '0;
        end else begin
            a_bin <= a_bin_nx;
            b_bin <= b_bin_nx;
        end
    end

    // ---- Test sequence -----------------------------------------------------
    real    est, ideal, err, worst;
    int     fails;
    integer raw_seed;

    // ---- Conversion-time measurement ---------------------------------------
    // t_start / t_done capture simulation time (ns) at the launch and at the
    // 'done' pulse. cycles is the elapsed count derived from CLK_PERIOD_NS.
    realtime t_start, t_done;
    real     elapsed_ns;
    longint  cycles;
    real     throughput_macs;   // multiply-accumulates per second

    initial begin
        raw_seed = 32'h1234_5678;

        // Random real operands in [-1, 1]. Kept modest in magnitude so the
        // K-term sum stays well inside the representable range.
        for (int i = 0; i < N; i++)
            for (int k = 0; k < K; k++)
                a_real[i][k] = (($random(raw_seed) % 1000) / 1000.0) * 0.8;
        for (int k = 0; k < K; k++)
            for (int j = 0; j < N; j++)
                b_real[k][j] = (($random(raw_seed) % 1000) / 1000.0) * 0.8;

        // Ideal real GEMM reference.
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                c_ideal[i][j] = 0.0;
                for (int k = 0; k < K; k++)
                    c_ideal[i][j] = c_ideal[i][j]
                                  + a_real[i][k] * b_real[k][j];
            end

        // Reset (synchronous, active-high).
        rst = 1; start = 0; k_len = K;
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // Launch. Timestamp the cycle 'start' is sampled so the conversion
        // window is measured from the FSM actually leaving S_IDLE.
        start   = 1;
        @(posedge clk);
        t_start = $realtime;
        start   = 0;


        // Wait for completion, and timestamp the 'done' pulse.
        wait (done == 1'b1);
        t_done  = $realtime;
        @(posedge clk);

        // ---- Check every element within tolerance --------------------------
        // Error of an L-bit bipolar estimate is ~ a few / sqrt(L). The pass
        // threshold TOL is set in the tunable-knobs block at the top of the
        // file; raise STREAM_LEN if you tighten it.
        worst = 0.0;
        fails = 0;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                logic signed [RESW-1:0] num;
                num   = c_flat[(i*N + j)*RESW +: RESW];
                est   = real'(num) / real'(STREAM_LEN);
                ideal = c_ideal[i][j];
                err   = (est > ideal) ? (est - ideal) : (ideal - est);
                if (err > worst) worst = err;
                if (err > TOL) begin
                    fails++;
                    if (fails <= 12)
                        $display("OUT-OF-TOL C[%0d][%0d]: est %0.4f ideal %0.4f err %0.4f",
                                 i, j, est, ideal, err);
                end
            end

        // ---- Conversion-time report ----------------------------------------
        elapsed_ns = t_done - t_start;
        cycles     = longint'(elapsed_ns / CLK_PERIOD_NS + 0.5);
        // One tile performs N*N*K multiply-accumulate operations.
        throughput_macs = (elapsed_ns > 0.0)
                        ? (real'(N*N*K) / (elapsed_ns * 1.0e-9))
                        : 0.0;

        $display("-------------------------------------------------------");
        $display("Stochastic GEMM  N=%0d K=%0d STREAM_LEN=%0d", N, K, STREAM_LEN);
        $display("worst absolute error = %0.4f   (tolerance = %0.4f)",
                 worst, TOL);
        if (fails == 0)
            $display("PASS: all %0d elements within tolerance.", N*N);
        else
            $display("FAIL: %0d / %0d elements out of tolerance.", fails, N*N);
        $display("-------------------------------------------------------");
        $display("Conversion time (start -> done):");
        $display("  clock          : %0.1f MHz  (%0.2f ns period)",
                 CLK_FREQ_MHZ, CLK_PERIOD_NS);
        $display("  cycles         : %0d", cycles);
        $display("  wall-clock     : %0.1f ns  (%0.3f us)",
                 elapsed_ns, elapsed_ns / 1000.0);
        $display("  per result     : %0.2f ns/element (%0d elements)",
                 elapsed_ns / real'(N*N), N*N);
        $display("  throughput     : %0.3f GMAC/s  (%0d MACs / tile)",
                 throughput_macs / 1.0e9, N*N*K);
        $display("-------------------------------------------------------");

        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: timeout.");
        $finish;
    end

endmodule

`timescale 1ns/1ps

// =============================================================================
// stoch_gemm_top.sv
// Top-level FULLY STOCHASTIC GEMM accelerator: a bank of Stochastic Number
// Generators (the supplied sng.sv), a diagonal skew network, an N x N
// stochastic systolic array (XNOR multiply + counters), and a control FSM.
//
// Computes one output tile  C[N][N] = A[N][K] * B[K][N]  in the BIPOLAR
// stochastic domain, then converts the per-PE '1's counts back to numeric
// GEMM values.
//
// Target: Xilinx Zynq UltraScale+ ZU3EG (Avnet Ultra96-V2), Vivado 2022.2.
// Reset : synchronous, ACTIVE-HIGH ('rst').
//
// =============================================================================
// BIPOLAR ENCODING
// -----------------------------------------------------------------------------
// The supplied sng.sv emits a UNIPOLAR bit: stoch_out = (lfsr < binary_in),
// so P(bit=1) = binary_in / 2^WIDTH. We use it for a BIPOLAR stream simply by
// reinterpreting the value: a unipolar probability p corresponds to the
// bipolar value  v = 2p - 1  in [-1, +1]. Concretely, to encode a signed
// operand x in [-1, +1] choose
//     binary_in = round( (x + 1)/2 * 2^WIDTH ).
// So binary_in = 2^(WIDTH-1) encodes x = 0, binary_in = 0 encodes x ~ -1, and
// binary_in = 2^WIDTH-1 encodes x ~ +1. The caller supplies binary_in already
// in this offset form on a_bin / b_bin; no SNG change is needed.
//
// DECORRELATION
// -----------------------------------------------------------------------------
// Stochastic multiply is only correct when the two operand streams are
// independent. Every SNG instance is therefore given a DISTINCT seed (derived
// from a base seed XORed with the lane index). Sharing seeds would correlate
// streams and destroy accuracy.
//
// PRODUCT / ACCUMULATION SEMANTICS
// -----------------------------------------------------------------------------
// XNOR of two bipolar streams is their product. Each PE counts product '1's.
// For ONE term over L = STREAM_LEN bits, count c maps to  v = (2c - L)/L.
// Over K terms PE(i,j) sees K*L bits with grand count 'cnt'; the true GEMM
// element is
//     C[i][j] = (2*cnt - K*L) / L          (real value, range [-K, K]).
// This block outputs the DE-BIASED fixed-point numerator  (2*cnt - K*L) on
// c_flat as a signed value; divide by STREAM_LEN externally (or treat c_flat
// as Q-format with an implied /L) to get the real result. The de-bias is done
// once here, centrally -- the PEs stay pure counters.
//
// STREAMING SCHEDULE
// -----------------------------------------------------------------------------
// One tile = K contraction terms, each needing a fresh L-bit stream. The FSM
// therefore runs K "sub-streams" of L cycles. At the start of each sub-stream
// it presents the next K-slice of binary operands (a_bin[i]=A[i][k] offset-
// encoded, b_bin[j]=B[k][j] offset-encoded) and the SNG bank generates L bits
// for it. The PE counters integrate across all K*L bits automatically.
//
// HANDSHAKE
// -----------------------------------------------------------------------------
//   1. Pulse 'start' with 'k_len' = contraction depth K.
//   2. For each of the K terms the FSM raises 'load_k' for one cycle: supply
//      that term's binary operands on a_bin / b_bin (offset-encoded).
//   3. The FSM streams L stochastic bits per term; PEs XNOR-and-count.
//   4. After K*L bits + a drain for the skew/array pipeline, 'done' pulses and
//      c_flat holds the de-biased signed results.
//
// PARAMETERS
//   N          : array size (rows = cols). Default 8.
//   WIDTH      : SNG / operand bit-width. Default 8 (matches sng.sv).
//   STREAM_LEN : stochastic bits per contraction term. Default 256.
//   KW         : bit-width of k_len (max contraction depth = 2^KW-1).
//   SEED_BASE  : base LFSR seed; per-lane seeds are SEED_BASE ^ lane_index.
//
// PORTS
//   clk, rst : clock, synchronous active-HIGH reset
//   start    : pulse to launch a tile
//   k_len    : contraction depth K (>= 1)
//   a_bin    : N offset-encoded operands, a_bin[i] = enc(A[i][k])
//   b_bin    : N offset-encoded operands, b_bin[j] = enc(B[k][j])
//   load_k   : 1-cycle pulse -- present the next term's operands now
//   busy     : high from start to done
//   done     : one-cycle pulse when the tile is ready
//   c_flat   : flattened N*N signed results. element(i,j) is the de-biased
//              numerator (2*cnt - K*L); real value = element / STREAM_LEN.
//              c_flat[(i*N+j)*RESW +: RESW]
// =============================================================================

module stoch_gemm_top #(
    parameter int N          = 8,
    parameter int WIDTH      = 8,
    // LFSR width for the SNG bank. MUST exceed $clog2(STREAM_LEN) so the
    // pseudo-random sequence does not repeat within one stream -- an LFSR that
    // cycles inside a stream makes phase-correlation between lanes persist and
    // corrupts the stochastic product. Default 16 (period 65535) comfortably
    // covers STREAM_LEN up to ~32k. Must be >= WIDTH.
    parameter int LFSR_W     = 16,
    parameter int STREAM_LEN = 256,
    parameter int KW         = 16,
    parameter logic [LFSR_W-1:0] SEED_BASE = 16'hACE1,
    // Derived widths -- declared here so they are visible in the port list.
    //   CNTW : per-PE counter, must hold up to K_max * STREAM_LEN.
    //   RESW : de-biased signed result width (numerator 2*cnt - K*L).
    localparam int CNTW = $clog2((1<<KW)-1) + $clog2(STREAM_LEN + 1) + 1,
    localparam int RESW = CNTW + 2
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 start,
    input  logic [KW-1:0]         k_len,
    input  logic [N*WIDTH-1:0]    a_bin,
    input  logic [N*WIDTH-1:0]    b_bin,
    output logic                  load_k,
    output logic [KW-1:0]         k_idx,
    output logic                  busy,
    output logic                  done,
    output logic [N*N*RESW-1:0]   c_flat
);

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,    // waiting for start
        S_FLUSH,   // one cycle: clear skew pipe + array
        S_LOAD,    // cycle 1: assert load_k so the caller presents operands
        S_LATCH,   // cycle 2: operand bus is now stable -> latch it
        S_STREAM,  // STREAM_LEN cycles: SNGs emit, PEs XNOR-and-count
        S_DRAIN,   // flush skew + array pipeline
        S_DONE     // one-cycle done pulse
    } state_t;

    state_t state;

    // Drain: deepest path is the bottom-right PE -- operands skewed by (N-1)
    // then (N-1) hops along each axis -> 2*(N-1); +1 for the multiply/count
    // register, +1 margin.
    localparam int DRAIN = 2*(N-1) + 2;

    localparam int LENW = $clog2(STREAM_LEN + 1);
    localparam int DRNW = $clog2(DRAIN + 1);

    logic [LENW-1:0] bit_cnt;     // bit index within the current sub-stream
    logic [KW-1:0]   term_cnt;    // which contraction term (0..K-1)

    // Expose the current contraction-term index. It is valid from the S_LOAD
    // request cycle through the whole sub-stream, so a consumer (e.g. an
    // im2col address generator) can use it to present the right operands.
    assign k_idx = term_cnt;
    logic [KW-1:0]   k_reg;       // latched K
    logic [DRNW-1:0] drain_cnt;   // drain counter

    // Array control.
    logic arr_en;
    logic arr_clr;
    logic pipe_flush;
    logic sng_en;                 // SNG bank generate-enable

    // Latched per-term binary operands feeding the SNG bank.
    logic [N*WIDTH-1:0] a_bin_q, b_bin_q;

    // -------------------------------------------------------------------------
    // SNG bank: 2*N instances (N for the A edge, N for the B edge).
    // Each lane gets a distinct seed so the streams are decorrelated.
    // sng.sv is used UNMODIFIED.
    // -------------------------------------------------------------------------
    logic [N-1:0] a_stoch, b_stoch;

    genvar li;
    generate
        for (li = 0; li < N; li++) begin : g_sng
            // Distinct, guaranteed-nonzero seeds, spaced widely apart in the
            // seed space so the lanes' LFSR streams are well decorrelated.
            localparam logic [LFSR_W-1:0] SEED_A =
                (SEED_BASE ^ LFSR_W'((li + 1) * 17)) | LFSR_W'(1);
            localparam logic [LFSR_W-1:0] SEED_B =
                (SEED_BASE ^ LFSR_W'((li + 1 + N) * 31)) | LFSR_W'(1);

            // The SNG compares an LFSR_W-bit LFSR against an LFSR_W-bit value.
            // The WIDTH-bit operand is placed in the HIGH bits so that
            //   P(bit=1) = binary_in / 2^LFSR_W = operand / 2^WIDTH,
            // i.e. the operand keeps its intended probability while the wide
            // LFSR (long period) avoids intra-stream repetition.
            logic [LFSR_W-1:0] a_cmp, b_cmp;
            assign a_cmp = { a_bin_q[li*WIDTH +: WIDTH], {(LFSR_W-WIDTH){1'b0}} };
            assign b_cmp = { b_bin_q[li*WIDTH +: WIDTH], {(LFSR_W-WIDTH){1'b0}} };

            sng #(.WIDTH(LFSR_W)) u_sng_a (
                .clk       (clk),
                .rst_n     (~rst),                       // sng.sv is active-low
                .enable    (sng_en),
                .binary_in (a_cmp),
                .seed      (SEED_A),
                .stoch_out (a_stoch[li])
            );

            sng #(.WIDTH(LFSR_W)) u_sng_b (
                .clk       (clk),
                .rst_n     (~rst),
                .enable    (sng_en),
                .binary_in (b_cmp),
                .seed      (SEED_B),
                .stoch_out (b_stoch[li])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Diagonal skew staircases (1-bit lanes).
    // Row i of the A-edge delayed by i cycles, column j of B-edge by j cycles.
    // a_pipe[i][d] = the bit that entered lane i exactly d cycles ago; lane i
    // tapped at depth i. Lane 0 is a pass-through.
    //
    // A 'valid' bit rides each staircase alongside the operand: v*_pipe carries
    // the same per-lane skew, so the valid that reaches the array edge is
    // aligned with the operand bits it accompanies. The array then propagates
    // valid diagonally through the PEs (see stoch_pe.sv), giving every PE a
    // correctly-aligned K*L-cycle counting window.
    // -------------------------------------------------------------------------
    logic a_pipe  [N][N];
    logic b_pipe  [N][N];
    logic va_pipe [N][N];
    logic vb_pipe [N][N];

    logic [N-1:0] a_skewed, b_skewed;
    logic [N-1:0] va_skewed, vb_skewed;

    // 'valid_in' is high exactly on the cycles a genuine product bit is being
    // generated (the SNG streaming cycles). It is the same on every lane.
    logic valid_in;
    assign valid_in = sng_en;

    integer ri, di;
    always_ff @(posedge clk) begin
        if (rst || pipe_flush) begin
            for (ri = 0; ri < N; ri++)
                for (di = 0; di < N; di++) begin
                    a_pipe[ri][di]  <= 1'b0;
                    b_pipe[ri][di]  <= 1'b0;
                    va_pipe[ri][di] <= 1'b0;
                    vb_pipe[ri][di] <= 1'b0;
                end
        end else if (arr_en) begin
            for (ri = 0; ri < N; ri++) begin
                a_pipe[ri][0]  <= a_stoch[ri];
                b_pipe[ri][0]  <= b_stoch[ri];
                va_pipe[ri][0] <= valid_in;
                vb_pipe[ri][0] <= valid_in;
                for (di = 1; di < N; di++) begin
                    a_pipe[ri][di]  <= a_pipe[ri][di-1];
                    b_pipe[ri][di]  <= b_pipe[ri][di-1];
                    va_pipe[ri][di] <= va_pipe[ri][di-1];
                    vb_pipe[ri][di] <= vb_pipe[ri][di-1];
                end
            end
        end
    end

    always_comb begin
        for (int i = 0; i < N; i++) begin
            a_skewed[i]  = a_pipe[i][i];
            b_skewed[i]  = b_pipe[i][i];
            va_skewed[i] = va_pipe[i][i];
            vb_skewed[i] = vb_pipe[i][i];
        end
    end

    // -------------------------------------------------------------------------
    // Stochastic systolic array.
    // -------------------------------------------------------------------------
    logic [N*N*CNTW-1:0] cnt_flat;

    stoch_systolic_array #(
        .N(N), .CNTW(CNTW)
    ) u_array (
        .clk      (clk),
        .rst      (rst),
        .run      (arr_en),
        .clr      (arr_clr),
        .a_left   (a_skewed),
        .b_top    (b_skewed),
        .v_left   (va_skewed),
        .v_top    (vb_skewed),
        .cnt_flat (cnt_flat)
    );

    // -------------------------------------------------------------------------
    // Control FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            bit_cnt   <= '0;
            term_cnt  <= '0;
            k_reg     <= '0;
            drain_cnt <= '0;
            a_bin_q   <= '0;
            b_bin_q   <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        k_reg     <= k_len;
                        bit_cnt   <= '0;
                        term_cnt  <= '0;
                        drain_cnt <= '0;
                        state     <= S_FLUSH;
                    end
                end

                // One cycle: clear skew pipe + array counters.
                S_FLUSH: begin
                    state <= S_LOAD;
                end

                // Cycle 1: request operands from the caller (load_k high).
                S_LOAD: begin
                    state <= S_LATCH;
                end

                // Cycle 2: the operand bus has settled -> latch it.
                S_LATCH: begin
                    a_bin_q <= a_bin;
                    b_bin_q <= b_bin;
                    bit_cnt <= '0;
                    state   <= S_STREAM;
                end

                // Stream STREAM_LEN bits for this term.
                S_STREAM: begin
                    if (bit_cnt == LENW'(STREAM_LEN - 1)) begin
                        bit_cnt <= '0;
                        if (term_cnt == k_reg - 1'b1) begin
                            // All K terms streamed -> drain.
                            drain_cnt <= '0;
                            state     <= S_DRAIN;
                        end else begin
                            term_cnt <= term_cnt + 1'b1;
                            state    <= S_LOAD;   // fetch next term
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                // Flush the skew + array pipeline.
                S_DRAIN: begin
                    if (drain_cnt == DRNW'(DRAIN - 1)) begin
                        state <= S_DONE;
                    end else begin
                        drain_cnt <= drain_cnt + 1'b1;
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Control / handshake outputs.
    // -------------------------------------------------------------------------
    always_comb begin
        arr_en     = 1'b0;
        arr_clr    = 1'b0;
        pipe_flush = 1'b0;
        sng_en     = 1'b0;
        load_k     = 1'b0;
        busy       = 1'b1;
        done       = 1'b0;

        case (state)
            S_IDLE: begin
                busy = 1'b0;
            end

            S_FLUSH: begin
                pipe_flush = 1'b1;
                arr_clr    = 1'b1;
            end

            S_LOAD: begin
                // Tell the caller to present this term's operands.
                load_k = 1'b1;
            end

            S_STREAM: begin
                arr_en = 1'b1;   // advance skew pipe + PE counters
                sng_en = 1'b1;   // SNGs emit a bit this cycle
            end

            S_DRAIN: begin
                arr_en = 1'b1;   // keep skew + array pipeline moving
            end

            S_DONE: begin
                done = 1'b1;
            end

            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // Output de-bias: raw count -> signed GEMM numerator.
    //   numerator = 2*cnt - K*STREAM_LEN     (real value = numerator/STREAM_LEN)
    // -------------------------------------------------------------------------
    logic signed [RESW-1:0] bias;
    assign bias = $signed({1'b0, k_reg}) * $signed(RESW'(STREAM_LEN));

    genvar ci;
    generate
        for (ci = 0; ci < N*N; ci++) begin : g_debias
            logic [CNTW-1:0]        raw;
            logic signed [RESW-1:0] num;
            assign raw = cnt_flat[ci*CNTW +: CNTW];
            assign num = (RESW'($signed({1'b0, raw})) <<< 1) - bias;
            assign c_flat[ci*RESW +: RESW] = num;
        end
    endgenerate

endmodule

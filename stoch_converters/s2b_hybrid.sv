// =============================================================================
// s2b_hybrid.sv
// Hybrid SAR + residue-counter stochastic-to-binary converter.
//
// Idea
//   Stochastic computing's noise floor scales as 1/sqrt(L), so a plain counter
//   needs L proportional to 2^(2*WIDTH) cycles for +/-1 LSB accuracy. For
//   WIDTH=16 that's 4.3 billion cycles -- impractical. A pure SAR has the
//   same issue: the LSB decision needs the same number of samples that a
//   plain counter would need to reach that precision.
//
//   This module splits the work in two:
//     STAGE 1 -- a SAR resolves the top K_SAR_BITS using successive
//                approximation. Cost is O(K_SAR_BITS * SAR_BIT_LEN).
//     STAGE 2 -- two counters then run in parallel for STREAM_LEN_RESIDUE
//                cycles: one counting the target stochastic stream, one
//                counting the internal SNG locked at the SAR's value. Their
//                difference is the residue, which is mapped to the bottom
//                (WIDTH - K_SAR_BITS) bits.
//
// Cycle budget example for WIDTH=16, K_SAR_BITS=8:
//     SAR:       8 * 32   =     256 cycles
//     Residue:                 65536 cycles  (gives ~8 bits of LSB precision)
//     ---------------------------------------
//     Total:                  ~65792 cycles  (~660 us at 100 MHz)
//
//   Compare to plain 16-bit counter: 2^32 cycles (~43 s).  ~65000x faster.
//
// Interface
//   start         : pulse one cycle to begin conversion
//   stoch_target  : the stochastic stream being converted
//   sng_seed      : seed for the internal feedback SNG
//   binary_out    : WIDTH-bit binary value, valid when 'valid' is high
//   valid         : pulses one cycle when conversion is done
//
// Parameters
//   WIDTH               : total output bit-width (e.g. 16)
//   K_SAR_BITS          : how many top bits to resolve via SAR (e.g. 8)
//   SAR_BIT_LEN         : cycles per SAR bit decision (e.g. 32)
//   STREAM_LEN_RESIDUE  : cycles spent counting target & feedback in stage 2
//
// Notes
//   - The internal SNG is the same shape as in sng.sv and s2b_sar.sv.
//   - Stage 2 uses *both* a target counter and a feedback counter sampling
//     simultaneously: subtracting them removes the SAR's coarse value and
//     leaves only the residue. This makes the residue calculation
//     independent of the SAR's absolute accuracy.
//   - K_SAR_BITS=0 degenerates to a plain counter; K_SAR_BITS=WIDTH degenerates
//     to a plain SAR.
// =============================================================================

module s2b_hybrid #(
    parameter int WIDTH              = 16,
    parameter int K_SAR_BITS         = 8,
    parameter int SAR_BIT_LEN        = 32,
    parameter int STREAM_LEN_RESIDUE = 65536
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    input  logic              stoch_target,
    input  logic [WIDTH-1:0]  sng_seed,
    output logic [WIDTH-1:0]  binary_out,
    output logic              valid
);

    // ---- Derived sizes ----------------------------------------------------
    localparam int K_LSB     = WIDTH - K_SAR_BITS;   // bits decided in stage 2
    localparam int SAR_LEN_W = $clog2(SAR_BIT_LEN + 1);
    localparam int RES_LEN_W = $clog2(STREAM_LEN_RESIDUE + 1);
    // Counters must hold up to STREAM_LEN_RESIDUE 1-bits each.
    localparam int CNT_W     = RES_LEN_W;
    // Signed residue: |target - feedback| can reach STREAM_LEN_RESIDUE.
    localparam int RES_W     = CNT_W + 1;

    // =====================================================================
    // STAGE 1: SAR resolving the top K_SAR_BITS
    // =====================================================================

    // SAR working register: bits [WIDTH-1 : K_LSB] are the SAR's output.
    // Bits below K_LSB are always 0 during SAR (we don't decide them).
    logic [WIDTH-1:0] sar_reg;
    logic [WIDTH-1:0] trial_value;

    // Bit index being decided. Starts at WIDTH-1 (MSB), decrements down to
    // K_LSB (the first bit handled by stage 2).
    logic [$clog2(WIDTH+1)-1:0] bit_idx;

    // Trial value during SAR: keep already-decided bits, set current bit = 1,
    // clear all lower bits.
    always_comb begin
        trial_value = sar_reg;
        trial_value[bit_idx] = 1'b1;
        for (int i = 0; i < WIDTH; i++)
            if (i < bit_idx) trial_value[i] = 1'b0;
    end

    // =====================================================================
    // Internal feedback SNG (shared by stage 1 and stage 2)
    // =====================================================================
    logic [WIDTH-1:0] lfsr;
    logic             feedback_bit;
    logic             feedback_stream;
    logic             sng_run;

    // LFSR tap masks for common WIDTHs (max-period polynomials).
    localparam logic [WIDTH-1:0] TAP_MASK =
        (WIDTH == 8)  ? WIDTH'('hB8)    :
        (WIDTH == 10) ? WIDTH'('h240)   :
        (WIDTH == 12) ? WIDTH'('hE08)   :
        (WIDTH == 16) ? WIDTH'('hD008)  :
                        WIDTH'((1 << (WIDTH-1)) | 1'b1);

    assign feedback_bit = ^(lfsr & TAP_MASK);

    always_ff @(posedge clk) begin
        if (!rst_n)
            lfsr <= (sng_seed == '0) ? {{(WIDTH-1){1'b0}}, 1'b1} : sng_seed;
        else if (sng_run)
            lfsr <= {lfsr[WIDTH-2:0], feedback_bit};
    end

    // Stage 1: compare against trial_value. Stage 2: compare against sar_reg.
    logic [WIDTH-1:0] compare_value;
    assign feedback_stream = sng_run ? (lfsr < compare_value) : 1'b0;

    // =====================================================================
    // Counters: count 1-bits in target stream and feedback stream
    // Used for both stage 1 (per-bit window) and stage 2 (residue window)
    // =====================================================================
    logic [CNT_W-1:0] cnt_target;
    logic [CNT_W-1:0] cnt_feedback;
    logic [CNT_W-1:0] elapsed;
    logic             counters_run;
    logic             counters_clear;

    always_ff @(posedge clk) begin
        if (!rst_n || counters_clear) begin
            cnt_target   <= '0;
            cnt_feedback <= '0;
            elapsed      <= '0;
        end else if (counters_run) begin
            if (stoch_target)    cnt_target   <= cnt_target   + 1'b1;
            if (feedback_stream) cnt_feedback <= cnt_feedback + 1'b1;
            elapsed              <= elapsed + 1'b1;
        end
    end

    // =====================================================================
    // FSM
    // =====================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_SAR_RUN,      // run SAR bit window
        S_SAR_COMMIT,   // commit current SAR bit
        S_RES_RUN,      // stage 2: count residue
        S_RES_FINISH,   // compute final binary
        S_DONE
    } state_t;
    state_t state;

    // Decision sign: did the target stream beat the feedback stream?
    // For unipolar streams, sar_reg gets bit=1 if target > feedback.
    logic decide_one;
    assign decide_one = ($signed({1'b0, cnt_target}) >
                         $signed({1'b0, cnt_feedback}));

    // Stage 2: signed residue.
    logic signed [RES_W-1:0] residue;
    assign residue = $signed({1'b0, cnt_target}) -
                     $signed({1'b0, cnt_feedback});

    // SAR window length tracker (cycles per bit, fixed at SAR_BIT_LEN).
    logic [SAR_LEN_W-1:0] sar_window_left;

    // =====================================================================
    // Output computation:
    //   final_value = (sar_reg) + residue_mapped
    //   where residue_mapped scales the residue from STREAM_LEN_RESIDUE
    //   into LSB units. Specifically:
    //     residue_mapped = residue * (2^WIDTH) / STREAM_LEN_RESIDUE
    //   For a power-of-two STREAM_LEN_RESIDUE this is a left shift.
    //
    //   We compute it generically with a 64-bit multiply-divide, which the
    //   tools will reduce to shifts when STREAM_LEN_RESIDUE is a power of 2.
    // =====================================================================
    logic signed [63:0] residue_scaled;
    logic signed [63:0] final_value;

    always_comb begin
        residue_scaled = ($signed({{(64-RES_W){residue[RES_W-1]}}, residue})
                          * 64'(1 << WIDTH))
                          / 64'(STREAM_LEN_RESIDUE);
        final_value    = $signed({{(64-WIDTH){1'b0}}, sar_reg}) + residue_scaled;
        // Clamp to [0, 2^WIDTH - 1]
        if (final_value < 0)
            final_value = 0;
        else if (final_value > 64'((1 << WIDTH) - 1))
            final_value = 64'((1 << WIDTH) - 1);
    end

    // =====================================================================
    // FSM logic
    // =====================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            sar_reg         <= '0;
            bit_idx         <= WIDTH - 1;
            sar_window_left <= '0;
            valid           <= 1'b0;
            binary_out      <= '0;
            sng_run         <= 1'b0;
            counters_run    <= 1'b0;
            counters_clear  <= 1'b1;
            compare_value   <= '0;
        end else begin
            valid <= 1'b0;

            unique case (state)

                // ---------- IDLE: wait for start ----------
                S_IDLE: begin
                    counters_run   <= 1'b0;
                    counters_clear <= 1'b1;
                    sng_run        <= 1'b0;
                    if (start) begin
                        sar_reg         <= '0;
                        bit_idx         <= WIDTH - 1;
                        sar_window_left <= SAR_BIT_LEN[SAR_LEN_W-1:0];
                        // If K_SAR_BITS==0, skip SAR entirely.
                        if (K_SAR_BITS == 0) begin
                            compare_value <= '0;
                            state         <= S_RES_RUN;
                        end else begin
                            state         <= S_SAR_RUN;
                        end
                    end
                end

                // ---------- SAR: count for SAR_BIT_LEN cycles ----------
                S_SAR_RUN: begin
                    counters_clear <= 1'b0;
                    counters_run   <= 1'b1;
                    sng_run        <= 1'b1;
                    compare_value  <= trial_value;
                    if (sar_window_left == 0) begin
                        counters_run <= 1'b0;
                        sng_run      <= 1'b0;
                        state        <= S_SAR_COMMIT;
                    end else begin
                        sar_window_left <= sar_window_left - 1'b1;
                    end
                end

                // ---------- SAR: commit current bit ----------
                S_SAR_COMMIT: begin
                    sar_reg[bit_idx] <= decide_one;
                    counters_clear   <= 1'b1;
                    sar_window_left  <= SAR_BIT_LEN[SAR_LEN_W-1:0];
                    if (bit_idx == K_LSB[$clog2(WIDTH+1)-1:0]) begin
                        // Done with SAR; advance to residue stage.
                        // sar_reg already holds the committed bits; the bits
                        // below K_LSB remain 0 (we did not decide them).
                        state <= S_RES_RUN;
                    end else begin
                        bit_idx <= bit_idx - 1'b1;
                        state   <= S_SAR_RUN;
                    end
                end

                // ---------- Stage 2: residue counting ----------
                S_RES_RUN: begin
                    counters_clear <= 1'b0;
                    counters_run   <= 1'b1;
                    sng_run        <= 1'b1;
                    // Lock the feedback SNG at the SAR's value.
                    compare_value  <= sar_reg;
                    if (elapsed >= STREAM_LEN_RESIDUE[CNT_W-1:0] - 1) begin
                        counters_run <= 1'b0;
                        sng_run      <= 1'b0;
                        state        <= S_RES_FINISH;
                    end
                end

                // ---------- Compute final binary out ----------
                S_RES_FINISH: begin
                    binary_out <= final_value[WIDTH-1:0];
                    state      <= S_DONE;
                end

                // ---------- Done: pulse valid ----------
                S_DONE: begin
                    valid <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule

// =============================================================================
// stoch_pe_hybrid.sv
// Hybrid-capable Processing Element for the stochastic systolic array.
//
// Compared to the plain-counter PE this module adds the per-PE state needed
// for a hybrid SAR + residue stochastic-to-binary conversion. The FSM that
// sequences SAR bits, K terms and the residue stage lives in
// stoch_gemm_top_hybrid.sv and broadcasts control signals to ALL PEs in
// lockstep, so this module is FSM-free.
//
// Per-PE local state
//   - One internal feedback SNG (LFSR) producing 'fb_stream' at probability
//     trial_value / 2^WIDTH, where trial_value is built combinationally
//     from sar_reg and the broadcast bit_idx.
//   - Two counters: cnt_xnor counts XNOR=1 events on the target stream,
//     cnt_fb counts 1s on the internal feedback stream.
//   - A sar_reg holding the bits decided so far by the SAR.
//   - At commit_pulse the PE writes bit_idx of sar_reg with the sign of
//     (cnt_xnor - cnt_fb).
//
// External control (all driven by the shared FSM)
//   start       : pulse at the very start of a tile -- clear sar_reg and counters
//   clear_cnts  : clear cnt_xnor and cnt_fb at the start of each SAR window
//                 and at the start of the residue stage
//   accumulate  : counter enable; high for the duration of each window
//   commit      : pulse at the end of each SAR window -- update sar_reg[bit_idx]
//   bit_idx     : which bit of sar_reg the SAR is currently deciding
//                 (only meaningful when 'sar_phase' is high)
//   sar_phase   : high during SAR phase (feedback SNG compares against trial),
//                 low during residue phase (feedback compares against sar_reg)
//   finalise    : pulse at the very end -- latch c_flat and assert done
//
// Outputs
//   c_flat      : final signed result for this PE
//   done        : registered single-cycle pulse synchronous with finalise
// =============================================================================

module stoch_pe_hybrid #(
    parameter int WIDTH               = 16,
    parameter int RESW                = WIDTH + 2,
    parameter int STREAM_LEN_RESIDUE  = 65536,
    parameter logic [WIDTH-1:0] SEED  = 16'hACE1
) (
    input  logic                clk,
    input  logic                rst_n,

    // Streams (from external SNGs in stoch_systolic_array.sv)
    input  logic                v_in,
    input  logic                a_stream,
    input  logic                b_stream,

    // Broadcast control from the top FSM
    input  logic                start,        // begin a new tile
    input  logic                clear_cnts,   // start of each window
    input  logic                accumulate,   // counter enable
    input  logic                commit,       // end of a SAR bit window
    input  logic [$clog2(WIDTH+1)-1:0] bit_idx, // which SAR bit
    input  logic                sar_phase,    // 1 during SAR, 0 during residue
    input  logic                finalise,     // end of tile

    // Outputs
    output logic signed [RESW-1:0] c_flat,
    output logic                done
);

    // ---- Counter widths ---------------------------------------------------
    // cnt_xnor must hold the max number of XNOR=1 events seen during any one
    // window. Worst case during residue stage: STREAM_LEN_RESIDUE.
    localparam int CNT_W = $clog2(STREAM_LEN_RESIDUE + 1);

    // ---- XNOR product (target stream for the converter) ------------------
    logic xnor_bit;
    always_comb begin
        if (v_in) xnor_bit = ~(a_stream ^ b_stream);
        else      xnor_bit = 1'b0;
    end

    // ---- Per-PE SAR register ---------------------------------------------
    logic [WIDTH-1:0] sar_reg;

    // Trial value used during the SAR phase:
    //   - Keep bits above bit_idx (already decided)
    //   - Set bit_idx to 1 (the trial)
    //   - Clear bits below bit_idx (pending)
    // During residue phase the feedback SNG is locked at sar_reg directly.
    logic [WIDTH-1:0] trial_value;
    always_comb begin
        for (int i = 0; i < WIDTH; i++) begin
            if (i > bit_idx)
                trial_value[i] = sar_reg[i];
            else if (i == bit_idx)
                trial_value[i] = 1'b1;
            else
                trial_value[i] = 1'b0;
        end
    end

    logic [WIDTH-1:0] compare_value;
    assign compare_value = sar_phase ? trial_value : sar_reg;

    // ---- Internal feedback SNG (LFSR comparator) -------------------------
    logic [WIDTH-1:0] lfsr;
    logic             lfsr_msb;
    logic             fb_stream;

    // Galois LFSR tap masks (max-length sequences)
    localparam logic [WIDTH-1:0] TAP_MASK =
        (WIDTH == 8)  ? WIDTH'('hB8)   :
        (WIDTH == 10) ? WIDTH'('h240)  :
        (WIDTH == 12) ? WIDTH'('hE08)  :
        (WIDTH == 16) ? WIDTH'('hD008) :
                        WIDTH'((1 << (WIDTH-1)) | 1'b1);

    assign lfsr_msb = ^(lfsr & TAP_MASK);

    always_ff @(posedge clk) begin
        if (!rst_n)            lfsr <= (SEED == '0) ? {{(WIDTH-1){1'b0}}, 1'b1} : SEED;
        else if (start)        lfsr <= (SEED == '0) ? {{(WIDTH-1){1'b0}}, 1'b1} : SEED;
        else if (accumulate)   lfsr <= {lfsr[WIDTH-2:0], lfsr_msb};
    end

    assign fb_stream = accumulate ? (lfsr < compare_value) : 1'b0;

    // ---- Counters --------------------------------------------------------
    logic [CNT_W-1:0] cnt_xnor, cnt_fb;
    always_ff @(posedge clk) begin
        if (!rst_n || start || clear_cnts) begin
            cnt_xnor <= '0;
            cnt_fb   <= '0;
        end else if (accumulate) begin
            if (xnor_bit)  cnt_xnor <= cnt_xnor + 1'b1;
            if (fb_stream) cnt_fb   <= cnt_fb   + 1'b1;
        end
    end

    // ---- SAR commit ------------------------------------------------------
    // Decide the bit's value from the sign of (cnt_xnor - cnt_fb).
    // If target counted higher than the trial, the true probability is
    // above the trial -> keep the bit set. Otherwise clear it.
    logic signed [CNT_W:0] diff;
    assign diff = $signed({1'b0, cnt_xnor}) - $signed({1'b0, cnt_fb});

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            sar_reg <= '0;
        end else if (commit) begin
            sar_reg[bit_idx] <= (diff >= 0);
        end
    end

    // ---- Final combine ---------------------------------------------------
    // After residue stage:  final = (sar_reg << K_LSB) + scaled_residue
    // where scaled_residue = diff * (2^WIDTH / STREAM_LEN_RESIDUE) and the
    // K_LSB shift is the residue-stage scaling factor.
    //
    // For implementation simplicity we keep the result already in WIDTH-bit
    // space (sar_reg lives at the top of WIDTH; the residue counter delivers
    // the bottom). The natural combination is:
    //   binary_out = sar_reg + scaled_diff
    // where scaled_diff has been pre-scaled so its magnitude is small
    // (no more than a few LSBs of sar_reg). Then sign-centre and extend.

    // 2^WIDTH / STREAM_LEN_RESIDUE  -- when STREAM_LEN_RESIDUE is a power of
    // two, this is a shift by (WIDTH - log2(STREAM_LEN_RESIDUE)). For the
    // default WIDTH=16, STREAM_LEN_RESIDUE=65536 the factor is 1.
    localparam int LOG2_RES = $clog2(STREAM_LEN_RESIDUE);
    localparam int SHIFT    = WIDTH - LOG2_RES;     // can be 0, positive or negative

    logic signed [CNT_W+WIDTH:0] residue_scaled;
    always_comb begin
        if (SHIFT == 0)
            residue_scaled = {{(WIDTH){diff[CNT_W]}}, diff};
        else if (SHIFT > 0)
            residue_scaled = {{(WIDTH-SHIFT){diff[CNT_W]}}, diff, {(SHIFT){1'b0}}};
        else
            residue_scaled = {{(WIDTH+1){diff[CNT_W]}}, diff} >>> (-SHIFT);
    end

    // Combine: sum sar_reg (zero-extended) with residue_scaled, then sign-centre
    // by subtracting the midpoint 2^(WIDTH-1).
    logic signed [RESW-1:0] sar_plus_res;
    logic signed [RESW-1:0] centred;
    always_comb begin
        sar_plus_res = $signed({{(RESW-WIDTH){1'b0}}, sar_reg})
                     + $signed(residue_scaled[RESW-1:0]);
        centred      = sar_plus_res - $signed({{(RESW-WIDTH){1'b0}}, {1'b1, {(WIDTH-1){1'b0}}}});
    end

    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            c_flat <= '0;
            done   <= 1'b0;
        end else if (finalise) begin
            c_flat <= centred;
            done   <= 1'b1;
        end else begin
            done <= 1'b0;
        end
    end

endmodule

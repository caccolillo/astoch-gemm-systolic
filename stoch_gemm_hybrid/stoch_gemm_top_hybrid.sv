// =============================================================================
// stoch_gemm_top_hybrid.sv
// Top-level for the hybrid-converter stochastic GEMM.
//
// Drives the systolic array through a sequence:
//
//   IDLE -- wait for core_start
//
//   SAR PHASE (one outer iteration per SAR bit from MSB down to K_LSB):
//     for sar_bit in [WIDTH-1 .. K_LSB]:
//       PEs see sar_phase=1 and bit_idx=sar_bit
//       for term k in [0..K-1]:
//         drive a_bin/b_bin from operand buffers term k
//         hold accumulate=1 for SAR_BIT_LEN cycles
//       pulse commit                       -- every PE updates sar_reg[bit_idx]
//       pulse clear_cnts                   -- reset counters for the next bit
//
//   RESIDUE PHASE (single outer iteration):
//     PEs see sar_phase=0 (feedback locked at sar_reg)
//     for term k in [0..K-1]:
//       drive a_bin/b_bin from operand buffers term k
//       hold accumulate=1 for (STREAM_LEN_RESIDUE / K) cycles  -- evenly split
//     pulse finalise                       -- every PE latches c_flat
//
//   DONE -- assert core_done so the AXI-Stream wrapper can stream out c_flat
//
// Cycle budget (defaults WIDTH=16, K_SAR_BITS=8, K=9, SAR_BIT_LEN=32,
// STREAM_LEN_RESIDUE=65536):
//   SAR     = K_SAR_BITS * K * SAR_BIT_LEN          = 8 * 9 * 32 = 2304 cy
//   Residue = STREAM_LEN_RESIDUE                    = 65536 cy
//   Total                                             = ~67840 cy
// At 100 MHz: ~680 us per tile.
//
// Interface (compatible with stoch_gemm_axis.sv)
//   core_start      : pulse 1 cycle to begin a tile
//   core_busy       : high during the entire tile
//   core_done       : pulse 1 cycle when c_flat is valid
//   core_kidx       : current term index (0..K-1) -- wrapper uses it to drive
//                     a_bin/b_bin from abuf/bbuf
//   core_load_k     : pulse for the wrapper telling it to advance to the
//                     next term within the inner K loop
//   core_a_bin, core_b_bin : current term's operand vectors (from wrapper)
//   core_c_flat     : final flattened output (N*N*RESW bits)
// =============================================================================

module stoch_gemm_top_hybrid #(
    parameter int N                  = 8,
    parameter int WIDTH              = 16,
    parameter int LFSR_W             = 16,
    parameter int K_SAR_BITS         = 8,                  // SAR resolves top 8 bits
    parameter int SAR_BIT_LEN        = 32,                 // cycles per SAR bit per term
    parameter int STREAM_LEN_RESIDUE = 65536,              // residue stage total
    parameter int KMAX               = 64,                 // max K supported
    parameter int RESW               = WIDTH + 2
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // Control
    input  logic                          core_start,
    input  logic [$clog2(KMAX+1)-1:0]     k_len,            // 1..KMAX
    input  logic [31:0]                   res_per_k,        // SLR/K written by SW
    output logic                          core_busy,
    output logic                          core_done,

    // Operand interface to AXI-Stream wrapper
    output logic [$clog2(KMAX)-1:0]       core_kidx,
    output logic                          core_load_k,
    input  logic [N*WIDTH-1:0]            core_a_bin,
    input  logic [N*WIDTH-1:0]            core_b_bin,

    // Flattened output to wrapper
    output logic signed [N*N*RESW-1:0]    core_c_flat
);

    // ---- Internal signals to the array -----------------------------------
    logic                       arr_v_in;
    logic                       arr_start;
    logic                       arr_clear_cnts;
    logic                       arr_accumulate;
    logic                       arr_commit;
    logic [$clog2(WIDTH+1)-1:0] arr_bit_idx;
    logic                       arr_sar_phase;
    logic                       arr_finalise;
    logic                       arr_pe_done;

    stoch_systolic_array_hybrid #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .RESW(RESW), .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE)
    ) u_array (
        .clk         (clk),
        .rst_n       (rst_n),
        .v_in        (arr_v_in),
        .a_bin       (core_a_bin),
        .b_bin       (core_b_bin),
        .start       (arr_start),
        .clear_cnts  (arr_clear_cnts),
        .accumulate  (arr_accumulate),
        .commit      (arr_commit),
        .bit_idx     (arr_bit_idx),
        .sar_phase   (arr_sar_phase),
        .finalise    (arr_finalise),
        .c_flat_flat (core_c_flat),
        .pe_done     (arr_pe_done)
    );

    // ---- FSM and loop counters -------------------------------------------
    localparam int K_LSB  = WIDTH - K_SAR_BITS;
    localparam int RES_PER_K = STREAM_LEN_RESIDUE / (1);  // residue total cycles
                                                          // (we run STREAM_LEN_RESIDUE/K per term)

    typedef enum logic [3:0] {
        S_IDLE,
        S_START_TILE,
        S_SAR_BIT_START,
        S_SAR_TERM_LOAD,
        S_SAR_TERM_RUN,
        S_SAR_COMMIT,
        S_RES_TERM_LOAD,
        S_RES_TERM_RUN,
        S_FINALISE,
        S_DONE
    } state_t;
    // ----------------------------------------------------------------------
    // MAX_FANOUT 128: the FSM state register fans out to a clock-enable pin
    // on every counter register inside all N*N PEs (6181 endpoints for N=22).
    // 128 is the sweet spot for this design+device combo. Tighter values
    // were tried and rejected:
    //   - MAX_FANOUT 64 via LATE-order XDC: pushed wire utilisation to
    //     88.5%, route_design failed (Route 35-5).
    //   - MAX_FANOUT 64 via synth attribute: built fine but spread placement
    //     too far, made WNS WORSE (-0.272 vs -0.153 at 128) because the
    //     484:1 output mux path through PE c_flat -> reg_m_tdata_reg now
    //     dominates and is sensitive to placement spread.
    // The takeaway: more replication isn't always better. 128 leaves the
    // FSM-to-PE paths quiet enough that the 484:1 mux is the real ceiling.
    (* MAX_FANOUT = 128 *) state_t state;

    // MAX_FANOUT 128: bit_ctr is the SAR-bit counter, written every
    // SAR_BIT_LEN cycles during the SAR phase. Like the FSM state, it
    // distributes broadly to PE counter-enable logic and was the next
    // high-fanout signal to surface after the FSM was capped (12 of 20
    // worst paths at -0.159 ns at 300 MHz before this attribute).
    (* MAX_FANOUT = 128 *) logic [$clog2(WIDTH+1)-1:0]  bit_ctr;   // current SAR bit (counts down)
    logic [$clog2(KMAX)-1:0]     k_ctr;     // current term (0..k_len-1)
    logic [16:0]                 cyc_ctr;   // cycles within the current window
                                            // 17 bits covers STREAM_LEN_RESIDUE up to 131071
                                            // (was 32 bits; reduced to shorten the
                                            //  carry chain in the FSM transition compare)

    // Pre-registered comparison targets for the FSM transition conditions.
    // The original tests were "cyc_ctr + 1 == SAR_BIT_LEN" and
    // "cyc_ctr + 1 == res_per_k", both 32-bit add+compare cascades that
    // failed timing at 300 MHz (5 CARRY8 chain + 2 LUT6). Pre-computing
    // TARGET-1 outside the FSM hot path, and comparing cyc_ctr to it as a
    // narrow 17-bit equality, collapses the compare to a few LUT6 levels.
    localparam logic [16:0] SAR_BIT_LEN_M1 = SAR_BIT_LEN[16:0] - 17'd1;
    logic       [16:0]      res_per_k_m1;

    // Per-term residue window length (split STREAM_LEN_RESIDUE across K terms).
    // For K=9 and STREAM_LEN_RESIDUE=65536: ~7281 cycles per term.
    // res_per_k is now driven by an AXI register written by software.
    // This removes the runtime divider that was blocking timing closure
    // (32-deep CARRY8 chain) and shifts the SLR/K computation to userspace,
    // which only does it once at startup.

    // Default signal assignments each cycle
    always_comb begin
        arr_v_in        = (state == S_SAR_TERM_RUN) || (state == S_RES_TERM_RUN);
        arr_start       = (state == S_START_TILE);
        arr_clear_cnts  = (state == S_SAR_BIT_START) || (state == S_RES_TERM_LOAD && k_ctr == 0);
        arr_accumulate  = (state == S_SAR_TERM_RUN) || (state == S_RES_TERM_RUN);
        arr_commit      = (state == S_SAR_COMMIT);
        arr_finalise    = (state == S_FINALISE);
        arr_bit_idx     = bit_ctr;
        arr_sar_phase   = (state == S_SAR_BIT_START) ||
                          (state == S_SAR_TERM_LOAD) ||
                          (state == S_SAR_TERM_RUN)  ||
                          (state == S_SAR_COMMIT);
        core_busy       = (state != S_IDLE) && (state != S_DONE);
        core_done       = (state == S_DONE);
        core_kidx       = k_ctr;
        core_load_k     = (state == S_SAR_TERM_LOAD) || (state == S_RES_TERM_LOAD);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            bit_ctr <= '0;
            k_ctr   <= '0;
            cyc_ctr <= '0;
        end else begin
            unique case (state)

                S_IDLE: begin
                    if (core_start) begin
                        state   <= S_START_TILE;
                        bit_ctr <= WIDTH - 1;
                        k_ctr   <= '0;
                        cyc_ctr <= '0;
                    end
                end

                S_START_TILE: begin
                    // One-cycle global clear pulse for all PEs.
                    state <= (K_SAR_BITS == 0) ? S_RES_TERM_LOAD : S_SAR_BIT_START;
                    k_ctr <= '0;
                end

                S_SAR_BIT_START: begin
                    // One-cycle pulse to clear counters for this SAR bit.
                    state   <= S_SAR_TERM_LOAD;
                    k_ctr   <= '0;
                    cyc_ctr <= '0;
                end

                S_SAR_TERM_LOAD: begin
                    // One-cycle "load operand k" -- wrapper updates a_bin/b_bin
                    // from abuf[k]/bbuf[k] in response to core_load_k.
                    state   <= S_SAR_TERM_RUN;
                    cyc_ctr <= '0;
                end

                S_SAR_TERM_RUN: begin
                    cyc_ctr <= cyc_ctr + 1'b1;
                    if (cyc_ctr == SAR_BIT_LEN_M1) begin
                        // Finished window for this term.
                        if (k_ctr + 1'b1 == k_len) begin
                            // Last term -- commit the SAR bit.
                            state <= S_SAR_COMMIT;
                        end else begin
                            k_ctr <= k_ctr + 1'b1;
                            state <= S_SAR_TERM_LOAD;
                        end
                    end
                end

                S_SAR_COMMIT: begin
                    // One-cycle pulse to commit sar_reg[bit_ctr] in all PEs.
                    if (bit_ctr == K_LSB[$clog2(WIDTH+1)-1:0]) begin
                        // Done with SAR. Move on to residue.
                        state <= S_RES_TERM_LOAD;
                        k_ctr <= '0;
                    end else begin
                        bit_ctr <= bit_ctr - 1'b1;
                        state   <= S_SAR_BIT_START;
                    end
                end

                S_RES_TERM_LOAD: begin
                    state   <= S_RES_TERM_RUN;
                    cyc_ctr <= '0;
                end

                S_RES_TERM_RUN: begin
                    cyc_ctr <= cyc_ctr + 1'b1;
                    if (cyc_ctr == res_per_k_m1) begin
                        if (k_ctr + 1'b1 == k_len) begin
                            // All K terms run for the residue stage. Finalise.
                            state <= S_FINALISE;
                        end else begin
                            k_ctr <= k_ctr + 1'b1;
                            state <= S_RES_TERM_LOAD;
                        end
                    end
                end

                S_FINALISE: begin
                    // One-cycle pulse for PEs to latch their c_flat.
                    state <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // --------------------------------------------------------------------
    // Pre-register res_per_k - 1 so the FSM compare is a simple equality
    // against a register, not an inline 32-bit add+compare. res_per_k only
    // changes when software writes it via AXI-Lite before core_start, so
    // this register is just tracking a slow-moving input.
    // --------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n)
            res_per_k_m1 <= '0;
        else
            res_per_k_m1 <= res_per_k[16:0] - 17'd1;
    end

endmodule

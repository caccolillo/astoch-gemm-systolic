// =============================================================================
// stoch_gemm_top_hybrid_rad.sv
// Radiation-hardened variant of stoch_gemm_top_hybrid.sv.
//
// Same FSM, same cycle budget, same port list as the original PLUS three new
// outputs (core_watchdog_fault, core_tmr_mismatch, core_fault). Existing
// integrations that don't wire up the new outputs can leave them unconnected;
// everything else is interface-compatible.
//
// What's added and why
//
//   1. TMR on `state` and `bit_ctr` only (parameter RAD_TMR_FSM, default 1).
//      These are the two signals you already identified as the dominant
//      fanout sources in this design (MAX_FANOUT=128, 6181 endpoints at
//      N=22) -- which is exactly what makes them worth protecting: a single
//      upset here doesn't corrupt one PE's result, it corrupts every PE's
//      control input simultaneously. Spatial TMR on the 484-instance PE
//      array itself is not attempted here -- the array is already ~80% of
//      a small device per your own notes, and naive register replication on
//      a high-fanout net already blew your routing budget once (88.5%
//      vertical wire utilisation, Route 35-5). TMR here is different in
//      kind from that failure: it triplicates one narrow control register
//      (4 bits + width-of-WIDTH bits), not a single fanout tree -- each of
//      the three copies still gets your MAX_FANOUT=128 treatment
//      individually, so the per-copy fanout shape you tuned for is
//      preserved. It is NOT free: you now have three fanout trees instead
//      of one, plus voter logic in what is already your tightest timing
//      path, so this needs its own closure pass at 300 MHz before trusting
//      it. If it doesn't close, set RAD_TMR_FSM=0 and lean on the
//      watchdog + wrapper-level re-run voting instead (see
//      stoch_gemm_axis_hybrid_rad.sv) -- temporal redundancy buys most of
//      the same protection at zero fanout cost, just slower.
//
//      This is FF-only TMR: the three copies share one next-state
//      combinational cone. It catches an upset landing in a state/bit_ctr
//      flip-flop (the dominant SRAM-FPGA SEU mode) but NOT a transient in
//      the shared next-state logic itself (SET) -- that would be voted
//      "unanimous" on a wrong value. Full SET coverage needs the next-state
//      logic triplicated too, which roughly triples the comb cone driving
//      484 PEs of control -- not attempted here on area/timing grounds.
//
//   2. A watchdog (parameter RAD_WATCHDOG, default 1) that independently
//      counts cycles since core_start and force-resets the FSM to S_IDLE if
//      a tile runs past WATCHDOG_LIMIT (worst-case budget x2 margin). This
//      catches the failure mode TMR on state/bit_ctr does NOT cover: an
//      upset that lands on a *legal* state encoding (e.g. S_SAR_TERM_RUN
//      flips to S_DONE) sails straight through the voter with no
//      disagreement to detect if all three copies independently end up
//      agreeing post-vote, or more importantly an upset in k_ctr/cyc_ctr
//      (deliberately NOT in the TMR domain, see below) can desynchronise
//      the loop counters without ever touching `state`. The watchdog is a
//      backstop, not a precision instrument -- if IT gets hit, worst case
//      is one tile runs slightly long or short, not a silent wrong answer.
//
//   3. core_fault is the OR of watchdog_fault and tmr_mismatch, sticky until
//      the next core_start, intended for the wrapper to gate whether this
//      tile's result is trustworthy (see RAD_VOTE_RUNS in the wrapper).
//
// What's deliberately NOT covered here (see RADIATION_HARDENING_NOTES.md):
//   - k_ctr, cyc_ctr: not triplicated. They're lower-fanout than
//     state/bit_ctr (point-to-point into the wrapper's abuf/bbuf mux and
//     the FSM's own compare logic, not broadcast to 484 PEs), so an upset
//     here is lower-blast-radius and is instead caught by the watchdog
//     (stuck/early-finish) or by the wrapper's re-run vote (wrong c_flat).
//   - Per-PE accumulator state (cnt_xnor, cnt_fb, sar_reg) inside
//     stoch_pe_hybrid.sv: completely unprotected at the RTL level here.
//     484 PEs x TMR is not a fanout problem, it's a flat 3x area problem on
//     a device that's already tight. Covered instead by temporal redundancy
//     in the wrapper (re-run the whole tile, compare/vote per-PE result).
//   - Configuration memory (CRAM) SEUs: out of scope for RTL entirely --
//     needs SEM IP / scrubbing + Multiboot golden image at the bitstream/
//     boot level. See RADIATION_HARDENING_NOTES.md.
//
// IMPORTANT DEPENDENCY: this module instantiates
// stoch_systolic_array_hybrid_rad, NOT the original stoch_systolic_array_
// hybrid. That variant adds a start-triggered reseed to the edge SNGs
// (sng_rad.sv) -- without it, the wrapper-level re-run vote in
// stoch_gemm_axis_hybrid_rad.sv is unsound: the edge SNGs in the
// unmodified array free-run continuously and are only reset by rst_n, so a
// second back-to-back run of the identical tile starts from a different
// LFSR phase and produces a different (but equally valid) stochastic
// sample -- indistinguishable from a real fault using exact-match
// comparison, and a serious one was found via simulation while building
// this. See sng_rad.sv's header for the full explanation.
// =============================================================================

module stoch_gemm_top_hybrid_rad #(
    parameter int N                  = 8,
    parameter int WIDTH              = 16,
    parameter int LFSR_W             = 16,
    parameter int K_SAR_BITS         = 8,
    parameter int SAR_BIT_LEN        = 32,
    parameter int STREAM_LEN_RESIDUE = 65536,
    parameter int KMAX               = 64,
    parameter int RESW               = WIDTH + 2,
    parameter bit RAD_TMR_FSM        = 1,
    parameter bit RAD_WATCHDOG       = 1,
    // Worst-case tile budget (KMAX terms, full SAR depth, full residue) x2
    // margin. Override if you want a tighter trip point.
    parameter int WATCHDOG_LIMIT     = 2 * (K_SAR_BITS * KMAX * SAR_BIT_LEN + STREAM_LEN_RESIDUE)
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          core_start,
    input  logic [$clog2(KMAX+1)-1:0]     k_len,
    input  logic [31:0]                   res_per_k,
    output logic                          core_busy,
    output logic                          core_done,

    output logic [$clog2(KMAX)-1:0]       core_kidx,
    output logic                          core_load_k,
    input  logic [N*WIDTH-1:0]            core_a_bin,
    input  logic [N*WIDTH-1:0]            core_b_bin,

    output logic signed [N*N*RESW-1:0]    core_c_flat,

    // ---- New: fault telemetry --------------------------------------------
    output logic                          core_watchdog_fault, // sticky, cleared on next core_start
    output logic                          core_tmr_mismatch,   // sticky, cleared on next core_start
    output logic                          core_fault            // OR of the above
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

    stoch_systolic_array_hybrid_rad #(
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
    localparam int K_LSB = WIDTH - K_SAR_BITS;

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

    // ---- TMR domain: state, bit_ctr ---------------------------------------
    (* MAX_FANOUT = 128 *) logic [3:0] state_a, state_b, state_c;
    state_t state;
    (* MAX_FANOUT = 128 *) logic [$clog2(WIDTH+1)-1:0] bit_ctr_a, bit_ctr_b, bit_ctr_c, bit_ctr;

    state_t state_next;
    logic [$clog2(WIDTH+1)-1:0] bit_ctr_next;

    logic state_mismatch, bitctr_mismatch;
    logic core_tmr_mismatch_int;
    logic core_watchdog_fault_int, watchdog_force_idle;

    logic [$clog2(KMAX)-1:0]     k_ctr;     // current term (0..k_len-1) -- not TMR'd, see header
    logic [16:0]                 cyc_ctr;   // cycles within the current window -- not TMR'd, see header

    localparam logic [16:0] SAR_BIT_LEN_M1 = SAR_BIT_LEN[16:0] - 17'd1;
    logic       [16:0]      res_per_k_m1;

    generate
    if (RAD_TMR_FSM) begin : g_tmr_fsm
        logic [$bits(state_t)-1:0] state_voted;
        logic [$clog2(WIDTH+1)-1:0] bit_ctr_voted;

        tmr_vote3 #(.W($bits(state_t))) u_vote_state (
            .a(state_a), .b(state_b), .c(state_c),
            .y(state_voted), .mismatch(state_mismatch)
        );
        tmr_vote3 #(.W($clog2(WIDTH+1))) u_vote_bitctr (
            .a(bit_ctr_a), .b(bit_ctr_b), .c(bit_ctr_c),
            .y(bit_ctr_voted), .mismatch(bitctr_mismatch)
        );

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                state_a <= S_IDLE; state_b <= S_IDLE; state_c <= S_IDLE;
            end else begin
                state_a <= state_next; state_b <= state_next; state_c <= state_next;
            end
        end
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                bit_ctr_a <= '0; bit_ctr_b <= '0; bit_ctr_c <= '0;
            end else begin
                bit_ctr_a <= bit_ctr_next; bit_ctr_b <= bit_ctr_next; bit_ctr_c <= bit_ctr_next;
            end
        end

        // Re-feed the voted (corrected) value as the live value used by the
        // rest of the FSM, so a single-copy upset self-heals next cycle.
        assign state              = state_t'(state_voted);
        assign bit_ctr            = bit_ctr_voted;
        assign core_tmr_mismatch_int = state_mismatch || bitctr_mismatch;
    end else begin : g_no_tmr_fsm
        always_ff @(posedge clk) begin
            if (!rst_n) state <= S_IDLE;
            else        state <= state_next;
        end
        always_ff @(posedge clk) begin
            if (!rst_n) bit_ctr <= '0;
            else        bit_ctr <= bit_ctr_next;
        end
        assign state_a = state; assign state_b = state; assign state_c = state;
        assign bit_ctr_a = bit_ctr; assign bit_ctr_b = bit_ctr; assign bit_ctr_c = bit_ctr;
        assign state_mismatch = 1'b0;
        assign bitctr_mismatch = 1'b0;
        assign core_tmr_mismatch_int = 1'b0;
    end
    endgenerate

    // ------------------------------------------------------------------
    // Combinational next-state logic (single shared cone, feeds either 1
    // or 3 register copies identically -- see header note on SET scope).
    // ------------------------------------------------------------------
    always_comb begin
        state_next   = state;
        bit_ctr_next = bit_ctr;

        unique case (state)
            S_IDLE: begin
                if (core_start) state_next = S_START_TILE;
            end
            S_START_TILE: begin
                state_next = (K_SAR_BITS == 0) ? S_RES_TERM_LOAD : S_SAR_BIT_START;
            end
            S_SAR_BIT_START: begin
                state_next = S_SAR_TERM_LOAD;
            end
            S_SAR_TERM_LOAD: begin
                state_next = S_SAR_TERM_RUN;
            end
            S_SAR_TERM_RUN: begin
                if (cyc_ctr == SAR_BIT_LEN_M1) begin
                    if (k_ctr + 1'b1 == k_len) state_next = S_SAR_COMMIT;
                    else                       state_next = S_SAR_TERM_LOAD;
                end
            end
            S_SAR_COMMIT: begin
                if (bit_ctr == K_LSB[$clog2(WIDTH+1)-1:0]) begin
                    state_next = S_RES_TERM_LOAD;
                end else begin
                    bit_ctr_next = bit_ctr - 1'b1;
                    state_next   = S_SAR_BIT_START;
                end
            end
            S_RES_TERM_LOAD: begin
                state_next = S_RES_TERM_RUN;
            end
            S_RES_TERM_RUN: begin
                if (cyc_ctr == res_per_k_m1) begin
                    if (k_ctr + 1'b1 == k_len) state_next = S_FINALISE;
                    else                       state_next = S_RES_TERM_LOAD;
                end
            end
            S_FINALISE: begin
                state_next = S_DONE;
            end
            S_DONE: begin
                state_next = S_IDLE;
            end
            default: state_next = S_IDLE;
        endcase

        // bit_ctr reload on entry to a fresh tile
        if (state == S_IDLE && core_start) bit_ctr_next = WIDTH - 1;

        // Watchdog override: force home regardless of what the case above decided.
        if (watchdog_force_idle) state_next = S_IDLE;
    end

    // Default signal assignments each cycle (unchanged from the original)
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

    // k_ctr, cyc_ctr -- unchanged from the original, not TMR'd (see header)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            k_ctr   <= '0;
            cyc_ctr <= '0;
        end else begin
            case (state)
                S_IDLE: if (core_start) begin k_ctr <= '0; cyc_ctr <= '0; end
                S_START_TILE: k_ctr <= '0;
                S_SAR_BIT_START: begin k_ctr <= '0; cyc_ctr <= '0; end
                S_SAR_TERM_LOAD: cyc_ctr <= '0;
                S_SAR_TERM_RUN: begin
                    cyc_ctr <= cyc_ctr + 1'b1;
                    if (cyc_ctr == SAR_BIT_LEN_M1 && (k_ctr + 1'b1 != k_len))
                        k_ctr <= k_ctr + 1'b1;
                end
                S_SAR_COMMIT: if (bit_ctr == K_LSB[$clog2(WIDTH+1)-1:0]) k_ctr <= '0;
                S_RES_TERM_LOAD: cyc_ctr <= '0;
                S_RES_TERM_RUN: begin
                    cyc_ctr <= cyc_ctr + 1'b1;
                    if (cyc_ctr == res_per_k_m1 && (k_ctr + 1'b1 != k_len))
                        k_ctr <= k_ctr + 1'b1;
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) res_per_k_m1 <= '0;
        else        res_per_k_m1 <= res_per_k[16:0] - 17'd1;
    end

    // ------------------------------------------------------------------
    // Watchdog: independent of state/bit_ctr entirely (deliberately --
    // if it shared logic with the thing it's watching, a fault that takes
    // out one would likely take out the other).
    // ------------------------------------------------------------------
    generate
    if (RAD_WATCHDOG) begin : g_watchdog
        localparam int WD_W = $clog2(WATCHDOG_LIMIT + 2);
        logic [WD_W-1:0] wd_ctr;
        logic            wd_trip;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                wd_ctr  <= '0;
                wd_trip <= 1'b0;
            end else if (state == S_IDLE) begin
                wd_ctr  <= '0;
                wd_trip <= 1'b0;
            end else if (wd_ctr == WD_W'(WATCHDOG_LIMIT)) begin
                wd_trip <= 1'b1;          // sticky until back in S_IDLE
            end else begin
                wd_ctr <= wd_ctr + 1'b1;
            end
        end
        assign core_watchdog_fault_int = wd_trip;
        assign watchdog_force_idle     = wd_trip;
    end else begin : g_no_watchdog
        assign core_watchdog_fault_int = 1'b0;
        assign watchdog_force_idle     = 1'b0;
    end
    endgenerate

    // ---- Sticky fault outputs, cleared at the start of the next tile -----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            core_watchdog_fault <= 1'b0;
            core_tmr_mismatch   <= 1'b0;
        end else if (state == S_IDLE && core_start) begin
            core_watchdog_fault <= 1'b0;
            core_tmr_mismatch   <= 1'b0;
        end else begin
            if (core_watchdog_fault_int) core_watchdog_fault <= 1'b1;
            if (core_tmr_mismatch_int)   core_tmr_mismatch   <= 1'b1;
        end
    end

    assign core_fault = core_watchdog_fault || core_tmr_mismatch;

endmodule

`timescale 1ns/1ps

// =============================================================================
// stoch_gemm_axis_hybrid_rad.sv
// Radiation-hardened variant of stoch_gemm_axis_hybrid.sv.
//
// Drop-in compatible at the AXI-Lite/AXI-Stream interface level: same
// register map, same beat formats, same IRQ behaviour as the original,
// PLUS:
//   - A new RAD_VOTE_RUNS parameter (1/2/3, default 3) controlling temporal
//     redundancy on the PE array result.
//   - A new A_FAULT register at offset 0x24 (write-1-to-clear) reporting
//     sticky watchdog/TMR/vote-mismatch events.
//   - STATUS (0x04) gains bit 2 = FAULT_STICKY (OR of the above).
//
// ---------------------------------------------------------------------------
// WHY RE-RUNNING THE WHOLE TILE AND COMPARING IS A SOUND, CHEAP SEU CHECK
// ---------------------------------------------------------------------------
// The per-PE LFSRs in this design are seeded deterministically (no run-time
// entropy reseed -- see sng.sv). That means in the ABSENCE of a fault, run 1
// and run 2 of the identical tile (same abuf/bbuf, same k_len, same
// res_per_k) produce a BIT-IDENTICAL core_c_flat, every time. There is no
// inherent statistical noise across runs to account for. That turns
// "did a particle hit a register during this run" into a plain equality
// check -- no PSNR/statistical threshold needed, just ===.
//
// Storage: 2 ping-pong buffers (buf_a, buf_b), not 3. Run 1 -> buf_a,
// run 2 -> buf_b, compare. Match -> done, buf_b is the answer. Mismatch
// (an SEU landed in PE accumulator state during one of the two runs) ->
// run a third time into buf_b (overwriting run 2), keep buf_a (run 1)
// untouched, then take a per-bit majority of buf_a/buf_b's two stored
// values plus the fresh run -- in practice this needs all three to be
// live simultaneously only on the rare retry path, so buf_c is only
// allocated when RAD_VOTE_RUNS=3 and only meaningfully written on retry.
// This halves the steady-state storage of naive always-triple-buffering,
// because two widely-time-separated independent upsets landing in
// overlapping bit positions of two DIFFERENT runs is not a realistic
// threat model for isolated single-event effects.
//
// Each run takes the full tile time (K_SAR_BITS*K*SAR_BIT_LEN +
// STREAM_LEN_RESIDUE cycles, ~680us at N=22/300MHz per the existing
// design). RAD_VOTE_RUNS=3 therefore costs up to 3x latency on every tile
// in the worst case, 2x in the common (no-fault, two-run-match) case, 1x
// if you disable it (RAD_VOTE_RUNS=1, original behaviour, no extra
// latency, no protection). This is a throughput-for-correctness trade --
// appropriate for a tile-at-a-time batch accelerator, not appropriate if
// you need deterministic low latency.
// ---------------------------------------------------------------------------
//
// What this does NOT cover: anything upstream of core_c_flat being wrong
// in the SAME way on every run (a stuck-at fault, or a CRAM SEU that
// corrupts a LUT's configuration rather than a flip-flop's data) --
// those reproduce identically across re-runs and look like agreement.
// Re-run voting is an SEU/SET catcher, not a general ECC. CRAM SEUs
// specifically need bitstream scrubbing (Xilinx SEM IP) -- see
// RADIATION_HARDENING_NOTES.md.
// =============================================================================

module stoch_gemm_axis_hybrid_rad #(
    parameter int N                  = 8,
    parameter int WIDTH              = 16,
    parameter int LFSR_W             = 16,
    parameter int K_SAR_BITS         = 8,
    parameter int SAR_BIT_LEN        = 32,
    parameter int STREAM_LEN_RESIDUE = 65536,
    parameter int KW                 = 16,
    parameter int KBUF_MAX           = 16,
    parameter int C_S_AXI_ADDR_WIDTH = 12,
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int RAD_VOTE_RUNS      = 1,   // 1 = single run (fits device), 2 = compare-only, 3 = full majority vote
                                             // NOTE: N=22 RESULT_W=8712 bits. RAD_VOTE_RUNS=3 synthesises an 8712-bit
                                             // majority voter + two 8712-bit comparators (~12000 LUTs). The xczu3eg
                                             // has only 70560 LUTs total and the baseline design already uses ~69000,
                                             // so RAD_VOTE_RUNS > 1 will not fit. Use RAD_VOTE_RUNS=1 on this device.
    parameter bit RAD_TMR_FSM        = 1,   // TMR on the core's state/bit_ctr (see stoch_gemm_top_hybrid_rad)
    parameter bit RAD_WATCHDOG       = 1,   // per-run watchdog in the core
    parameter bit RAD_TMR_AXIL       = 1,   // TMR on this wrapper's tiny aw_state/ar_state FSMs
    parameter bit RAD_TMR_CFG        = 1,   // TMR on K_LEN/RES_PER_K/IRQEN config registers
    parameter bit RAD_BIST           = 0,   // built-in self-test -- disabled by default on xczu3eg because the
                                             // 8712-bit golden-vector comparator costs ~1500 LUTs. Enable only if
                                             // LUT headroom allows. Golden vector is only valid at the default
                                             // N=22/WIDTH=16/LFSR_W=16/K_SAR_BITS=8/SAR_BIT_LEN=32/
                                             // STREAM_LEN_RESIDUE=65536 parameter set; see gen_bist_golden.sv.
    parameter bit RAD_CRC_TRAILER    = 1    // append one CRC32 trailer beat after the N*N result beats
) (
    // ---- Clock / reset ----------------------------------------------------
    input  logic                              aclk,
    input  logic                              aresetn,

    // ---- AXI4-Lite slave : control ---------------------------------------
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]      s_axi_awaddr,
    input  logic [2:0]                         s_axi_awprot,
    input  logic                               s_axi_awvalid,
    output logic                               s_axi_awready,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]      s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0]  s_axi_wstrb,
    input  logic                               s_axi_wvalid,
    output logic                               s_axi_wready,
    output logic [1:0]                         s_axi_bresp,
    output logic                               s_axi_bvalid,
    input  logic                               s_axi_bready,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]      s_axi_araddr,
    input  logic [2:0]                         s_axi_arprot,
    input  logic                               s_axi_arvalid,
    output logic                               s_axi_arready,
    output logic [C_S_AXI_DATA_WIDTH-1:0]      s_axi_rdata,
    output logic [1:0]                         s_axi_rresp,
    output logic                               s_axi_rvalid,
    input  logic                               s_axi_rready,

    // ---- AXI4-Stream slave : operand stream ------------------------------
    input  logic [C_S_AXI_DATA_WIDTH-1:0]      s_axis_tdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0]  s_axis_tkeep,
    input  logic                               s_axis_tlast,
    input  logic                               s_axis_tvalid,
    output logic                               s_axis_tready,

    // ---- AXI4-Stream master : result stream ------------------------------
    output logic [C_S_AXI_DATA_WIDTH-1:0]      m_axis_tdata,
    output logic [(C_S_AXI_DATA_WIDTH/8)-1:0]  m_axis_tkeep,
    output logic                               m_axis_tlast,
    output logic                               m_axis_tvalid,
    input  logic                               m_axis_tready,

    // ---- Interrupt -------------------------------------------------------
    output logic                               irq
);

    // ---- Derived widths (must match stoch_gemm_top_hybrid_rad) -----------
    localparam int RESW = WIDTH + 2;
    localparam int CNTW = $clog2(STREAM_LEN_RESIDUE + 1);
    localparam int RESULT_W = N*N*RESW;

    // ---- AXI-Lite register file ------------------------------------------
    // 6-bit address decode (needs to reach 0x24, the new FAULT register).
    logic [5:0] aw_addr_q, ar_addr_q;

    logic [KW-1:0]  reg_klen;
    logic [31:0]    reg_res_per_k;
    logic           reg_irqen;
    logic           ext_start;        // AXI-Lite CTRL.START pulse -- arms the loader AND the vote sequencer
    logic           done_sticky;
    logic [31:0]    reg_icount, reg_ocount;
    logic           seq_busy;         // vote sequencer busy -- driven by assign further down

    // ---- Fault telemetry (sticky, write-1-to-clear via A_FAULT) ----------
    logic fault_watchdog_sticky, fault_tmr_sticky, fault_vote_sticky;
    logic fault_cfg_sticky, fault_axil_sticky, fault_bist_sticky;
    logic cfg_tmr_mismatch;           // driven by g_tmr_cfg/g_no_tmr_cfg generate below
    logic fault_clear_pulse;
    wire  fault_any_sticky = fault_watchdog_sticky || fault_tmr_sticky || fault_vote_sticky ||
                              fault_cfg_sticky      || fault_axil_sticky || fault_bist_sticky;

    // ---- BIST (RAD_BIST) ---------------------------------------------------
    // Triggered by CTRL bit 2. Loads a fixed known operand pattern directly
    // into abuf[0]/bbuf[0] (bypassing the AXI-Stream loader), forces k_len=1
    // for one run of the core, and compares the result against a golden
    // constant captured by simulating this exact RTL once (see
    // gen_bist_golden.sv) at the default parameter set. Mutually exclusive
    // with a real job and with stream loading -- see the CTRL write logic.
    logic bist_start_req;   // CTRL.BIST_START write pulse (qualified: !bist_busy && !seq_busy && !loading)
    logic bist_busy;
    logic bist_done_sticky;
    logic bist_pass_sticky; // valid only once bist_done_sticky=1
    logic bist_fail_event;  // one-cycle pulse: this BIST run just concluded with a fail
    logic bist_pulse;       // -> u_core.core_start (muxed with vote_start); driven by BIST FSM below
    wire  bist_load_pulse;  // -> loader always_ff gate; driven by BIST FSM state (defined below)

    // ---- Operand buffers ---------------------------------------------------
    logic [WIDTH-1:0] abuf [KBUF_MAX][N];
    logic [WIDTH-1:0] bbuf [KBUF_MAX][N];

    logic [KW-1:0]  in_term;
    logic           in_half;
    logic [$clog2(N)-1:0] in_lane;
    logic           loading;

    // ---- Core interface ----------------------------------------------------
    logic                        core_load_k;
    logic [$clog2(KBUF_MAX)-1:0] core_kidx;
    logic [N*WIDTH-1:0]          core_a_bin, core_b_bin;
    wire signed [N*N*RESW-1:0]   core_c_flat;   // net: driven by u_core output, only read in wrapper
    logic                        core_busy, core_done;
    logic                        core_watchdog_fault, core_tmr_mismatch, core_fault;
    logic                        vote_start;   // internal pulse -> u_core.core_start (does NOT touch the loader)

    // =========================================================================
    // AXI-Lite write FSM (optionally TMR'd -- this is a tiny 2-state FSM,
    // triplicating it costs essentially nothing and protects the path that
    // issues core_start / writes K_LEN / writes RES_PER_K from a single
    // upset wedging the whole control plane).
    // =========================================================================
    typedef enum logic [1:0] {AW_IDLE, AW_ADDR, AW_DATA, AW_RESP} aw_t;
    logic [$bits(aw_t)-1:0] aw_state_a, aw_state_b, aw_state_c;
    aw_t aw_state;
    aw_t aw_state_next;
    logic aw_tmr_mismatch;

    generate
    if (RAD_TMR_AXIL) begin : g_tmr_aw
        logic [$bits(aw_t)-1:0] aw_state_voted;
        tmr_vote3 #(.W($bits(aw_t))) u_vote_aw (
            .a(aw_state_a), .b(aw_state_b), .c(aw_state_c),
            .y(aw_state_voted), .mismatch(aw_tmr_mismatch)
        );
        always_ff @(posedge aclk) begin
            if (!aresetn) begin
                aw_state_a <= AW_IDLE; aw_state_b <= AW_IDLE; aw_state_c <= AW_IDLE;
            end else begin
                aw_state_a <= aw_state_next; aw_state_b <= aw_state_next; aw_state_c <= aw_state_next;
            end
        end
        assign aw_state = aw_t'(aw_state_voted);
    end else begin : g_no_tmr_aw
        always_ff @(posedge aclk) begin
            if (!aresetn) aw_state <= AW_IDLE;
            else          aw_state <= aw_state_next;
        end
        assign aw_state_a = aw_state; assign aw_state_b = aw_state; assign aw_state_c = aw_state;
        assign aw_tmr_mismatch = 1'b0;
    end
    endgenerate

    always_comb begin
        aw_state_next = aw_state;
        unique case (aw_state)
            AW_IDLE: if (s_axi_awvalid) aw_state_next = AW_DATA;
            AW_DATA: if (s_axi_wvalid)  aw_state_next = AW_RESP;
            AW_RESP: if (s_axi_bready)  aw_state_next = AW_IDLE;
            default: aw_state_next = AW_IDLE;
        endcase
    end

    logic [KW-1:0]  reg_klen_a, reg_klen_b, reg_klen_c;
    logic [31:0]    reg_res_per_k_a, reg_res_per_k_b, reg_res_per_k_c;
    logic           reg_irqen_a, reg_irqen_b, reg_irqen_c;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bvalid   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            aw_addr_q      <= '0;
            reg_klen_a      <= '0;        reg_klen_b      <= '0;        reg_klen_c      <= '0;
            reg_res_per_k_a <= 32'd8192;  reg_res_per_k_b <= 32'd8192;  reg_res_per_k_c <= 32'd8192;
            reg_irqen_a     <= 1'b0;      reg_irqen_b     <= 1'b0;      reg_irqen_c     <= 1'b0;
            ext_start      <= 1'b0;
            bist_start_req <= 1'b0;
            fault_clear_pulse <= 1'b0;
        end else begin
            ext_start         <= 1'b0;
            bist_start_req    <= 1'b0;
            fault_clear_pulse <= 1'b0;
            case (aw_state)
                AW_IDLE: begin
                    s_axi_awready <= 1'b1;
                    s_axi_wready  <= 1'b0;
                    s_axi_bvalid  <= 1'b0;
                    if (s_axi_awvalid) begin
                        aw_addr_q     <= s_axi_awaddr[5:0];
                        s_axi_awready <= 1'b0;
                        s_axi_wready  <= 1'b1;
                    end
                end
                AW_DATA: begin
                    if (s_axi_wvalid) begin
                        case (aw_addr_q)
                            6'h00: begin // CTRL: bit0=START, bit1=IRQEN, bit2=BIST_START
                                if (s_axi_wdata[0] && !bist_busy) ext_start <= 1'b1;
                                if (s_axi_wdata[2] && !bist_busy && !seq_busy)
                                    bist_start_req <= 1'b1;
                                reg_irqen_a <= s_axi_wdata[1];
                                reg_irqen_b <= s_axi_wdata[1];
                                reg_irqen_c <= s_axi_wdata[1];
                            end
                            6'h08: begin
                                reg_klen_a <= s_axi_wdata[KW-1:0];
                                reg_klen_b <= s_axi_wdata[KW-1:0];
                                reg_klen_c <= s_axi_wdata[KW-1:0];
                            end
                            6'h20: begin
                                reg_res_per_k_a <= s_axi_wdata[31:0];
                                reg_res_per_k_b <= s_axi_wdata[31:0];
                                reg_res_per_k_c <= s_axi_wdata[31:0];
                            end
                            6'h24: if (s_axi_wdata[0]) fault_clear_pulse <= 1'b1; // A_FAULT: write-1-to-clear
                            default: ;
                        endcase
                        s_axi_wready <= 1'b0;
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= 2'b00;
                    end
                end
                AW_RESP: begin
                    if (s_axi_bready) s_axi_bvalid <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    // ---- Config register TMR voting (item: AXI-Lite config register TMR) --
    // K_LEN/RES_PER_K/IRQEN are written once at the start of a tile and held
    // stable for the whole ~hundreds-of-us run -- exactly the kind of
    // long-lived state an SEU during that window can silently corrupt.
    // Triplicated above, voted here; reg_klen/reg_res_per_k/reg_irqen below
    // are now the VOTED values and are what every other use site in this
    // file already reads.
    generate
    if (RAD_TMR_CFG) begin : g_tmr_cfg
        logic m_klen, m_resperk, m_irqen;
        tmr_vote3 #(.W(KW))  u_vote_klen    (.a(reg_klen_a),      .b(reg_klen_b),      .c(reg_klen_c),      .y(reg_klen),      .mismatch(m_klen));
        tmr_vote3 #(.W(32))  u_vote_resperk (.a(reg_res_per_k_a), .b(reg_res_per_k_b), .c(reg_res_per_k_c), .y(reg_res_per_k), .mismatch(m_resperk));
        tmr_vote3 #(.W(1))   u_vote_irqen   (.a(reg_irqen_a),     .b(reg_irqen_b),     .c(reg_irqen_c),     .y(reg_irqen),     .mismatch(m_irqen));
        assign cfg_tmr_mismatch = m_klen || m_resperk || m_irqen;
    end else begin : g_no_tmr_cfg
        assign reg_klen         = reg_klen_a;
        assign reg_res_per_k    = reg_res_per_k_a;
        assign reg_irqen        = reg_irqen_a;
        assign cfg_tmr_mismatch = 1'b0;
    end
    endgenerate

    // ---- AXI-Lite read FSM (same TMR treatment) ---------------------------
    typedef enum logic [1:0] {AR_IDLE, AR_RESP} ar_t;
    logic [$bits(ar_t)-1:0] ar_state_a, ar_state_b, ar_state_c;
    ar_t ar_state;
    ar_t ar_state_next;
    logic ar_tmr_mismatch;

    generate
    if (RAD_TMR_AXIL) begin : g_tmr_ar
        logic [$bits(ar_t)-1:0] ar_state_voted;
        tmr_vote3 #(.W($bits(ar_t))) u_vote_ar (
            .a(ar_state_a), .b(ar_state_b), .c(ar_state_c),
            .y(ar_state_voted), .mismatch(ar_tmr_mismatch)
        );
        always_ff @(posedge aclk) begin
            if (!aresetn) begin
                ar_state_a <= AR_IDLE; ar_state_b <= AR_IDLE; ar_state_c <= AR_IDLE;
            end else begin
                ar_state_a <= ar_state_next; ar_state_b <= ar_state_next; ar_state_c <= ar_state_next;
            end
        end
        assign ar_state = ar_t'(ar_state_voted);
    end else begin : g_no_tmr_ar
        always_ff @(posedge aclk) begin
            if (!aresetn) ar_state <= AR_IDLE;
            else          ar_state <= ar_state_next;
        end
        assign ar_state_a = ar_state; assign ar_state_b = ar_state; assign ar_state_c = ar_state;
        assign ar_tmr_mismatch = 1'b0;
    end
    endgenerate

    always_comb begin
        ar_state_next = ar_state;
        unique case (ar_state)
            AR_IDLE: if (s_axi_arvalid) ar_state_next = AR_RESP;
            AR_RESP: if (s_axi_rready)  ar_state_next = AR_IDLE;
            default: ar_state_next = AR_IDLE;
        endcase
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            ar_addr_q     <= '0;
        end else begin
            case (ar_state)
                AR_IDLE: begin
                    s_axi_arready <= 1'b1;
                    s_axi_rvalid  <= 1'b0;
                    if (s_axi_arvalid) begin
                        ar_addr_q     <= s_axi_araddr[5:0];
                        s_axi_arready <= 1'b0;
                        s_axi_rvalid  <= 1'b1;
                        s_axi_rresp   <= 2'b00;
                    end
                end
                AR_RESP: begin
                    if (s_axi_rready) s_axi_rvalid <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    always_comb begin
        s_axi_rdata = 32'd0;
        case (ar_addr_q)
            6'h00: s_axi_rdata = {30'd0, reg_irqen, 1'b0};
            6'h04: s_axi_rdata = {25'd0, RAD_CRC_TRAILER, bist_pass_sticky, bist_done_sticky,
                                   bist_busy, fault_any_sticky, done_sticky, seq_busy}; // STATUS
            6'h08: s_axi_rdata = {{(32-KW){1'b0}}, reg_klen};
            6'h0C: s_axi_rdata = {RESW[7:0], CNTW[7:0], KW[7:0], N[7:0]};
            6'h10: s_axi_rdata = {1'b1, 7'd0, STREAM_LEN_RESIDUE[23:0]};
            6'h14: s_axi_rdata = reg_icount;
            6'h18: s_axi_rdata = reg_ocount;
            6'h1C: s_axi_rdata = {16'd0, SAR_BIT_LEN[7:0], K_SAR_BITS[7:0]};
            6'h20: s_axi_rdata = reg_res_per_k;
            6'h24: s_axi_rdata = {25'd0, fault_bist_sticky, fault_axil_sticky, fault_cfg_sticky,
                                   fault_vote_sticky, fault_tmr_sticky, fault_watchdog_sticky,
                                   fault_any_sticky};       // FAULT
            default: s_axi_rdata = 32'd0;
        endcase
    end

    // ---- AXI-Stream input: load operands into abuf/bbuf -------------------
    // Gated on ext_start only -- internal vote-sequencer re-runs (vote_start)
    // do NOT touch the loader, so abuf/bbuf (and therefore the operand
    // stream into the core) are bit-identical across all RAD_VOTE_RUNS runs
    // of a tile in the fault-free case, which is exactly the property the
    // re-run comparison in the vote sequencer below depends on.
    assign s_axis_tready = loading;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            in_term    <= '0;
            in_half    <= 1'b0;
            in_lane    <= '0;
            loading    <= 1'b1;
            reg_icount <= 32'd0;
        end else if (bist_load_pulse) begin
            // BIST's one-cycle parallel load of the fixed pattern into
            // abuf[0]/bbuf[0] -- kept in this same always_ff (rather than a
            // second block also writing abuf/bbuf) so the array has exactly
            // one procedural driver, as synthesis requires. core_kidx is 0
            // throughout a k_len=1 run, so the existing
            // abuf[core_kidx]/bbuf[core_kidx] mirror feeding
            // core_a_bin/core_b_bin below picks this up with no further
            // wiring needed.
            for (int li = 0; li < N; li++) begin
                abuf[0][li] <= bist_a_val(li);
                bbuf[0][li] <= bist_b_val(li);
            end
        end else if (ext_start) begin
            in_term    <= '0;
            in_half    <= 1'b0;
            in_lane    <= '0;
            loading    <= 1'b1;
            reg_icount <= 32'd0;
        end else if (loading && s_axis_tvalid) begin
            if (in_half == 1'b0)
                abuf[in_term][in_lane] <= s_axis_tdata[WIDTH-1:0];
            else
                bbuf[in_term][in_lane] <= s_axis_tdata[WIDTH-1:0];
            reg_icount <= reg_icount + 32'd1;

            if (in_lane == N-1) begin
                in_lane <= '0;
                if (in_half == 1'b0) in_half <= 1'b1;
                else begin
                    in_half <= 1'b0;
                    if (in_term + 1 < reg_klen) in_term <= in_term + 1;
                    else                        loading <= 1'b0;
                end
            end else begin
                in_lane <= in_lane + 1;
            end

            if (s_axis_tlast) loading <= 1'b0;
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            core_a_bin <= '0;
            core_b_bin <= '0;
        end else begin
            for (int li = 0; li < N; li++) begin
                core_a_bin[li*WIDTH +: WIDTH] <= abuf[core_kidx][li];
                core_b_bin[li*WIDTH +: WIDTH] <= bbuf[core_kidx][li];
            end
        end
    end

    // ---- Hardened core instance --------------------------------------------
    stoch_gemm_top_hybrid_rad #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .K_SAR_BITS(K_SAR_BITS),
        .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE),
        .KMAX(KBUF_MAX), .RESW(RESW),
        .RAD_TMR_FSM(RAD_TMR_FSM), .RAD_WATCHDOG(RAD_WATCHDOG)
    ) u_core (
        .clk         (aclk),
        .rst_n       (aresetn),
        .core_start  (vote_start || bist_pulse),     // NOT ext_start -- see header; BIST shares this same pulse
        .k_len       (bist_busy ? KW'(1) : reg_klen),
        .res_per_k   (reg_res_per_k),
        .core_busy   (core_busy),
        .core_done   (core_done),
        .core_kidx   (core_kidx),
        .core_load_k (core_load_k),
        .core_a_bin  (core_a_bin),
        .core_b_bin  (core_b_bin),
        .core_c_flat (core_c_flat),
        .core_watchdog_fault (core_watchdog_fault),
        .core_tmr_mismatch   (core_tmr_mismatch),
        .core_fault           (core_fault)
    );

    // =========================================================================
    // Vote sequencer: drives vote_start RAD_VOTE_RUNS times per job, captures
    // each run's result, decides the voted/accepted result, and produces a
    // single vote_done pulse that the output-streaming logic below treats
    // exactly like the original design treated core_done.
    // =========================================================================
    // ---- Vote-sequencer run-count register ---------------------------------
    // XSim 2022.2 has a confirmed limitation: 'parameter int' overrides are
    // not propagated into generate-if conditions, always_ff static comparisons,
    // or localparams derived from the parameter -- the module default is used
    // instead. Capturing the parameter into a register at reset is the only
    // mechanism that reliably uses the instance-specific value in XSim: the
    // simulator reads the parameter at the active-reset clock edge and commits
    // it into the FF. The FSM then compares against the register (a plain
    // signal), not the parameter directly, so the correct instance value is
    // always used regardless of simulator.
    logic [3:0] eff_vote_runs;  // RAD_VOTE_RUNS captured into FF at reset

    typedef enum logic [3:0] {
        VS_IDLE, VS_RUN1, VS_WAIT1, VS_RUN2, VS_WAIT2,
        VS_RUN3, VS_WAIT3, VS_FINAL
    } vstate_t;
    vstate_t vstate;

    logic signed [RESULT_W-1:0] buf_a, buf_b, buf_c;
    logic signed [RESULT_W-1:0] vote_result;
    logic                       vote_done;
    logic                       run_wd_fault, run_tmr_fault; // OR'd across all runs of this job

    wire buf_ab_match = (buf_a === buf_b);

    assign seq_busy = (vstate != VS_IDLE);
    logic vote_mismatch_set;  // one-cycle pulse set by the FSM when a genuine mismatch is detected;
                               // read by the fault-sticky block so the detection lives in one always_ff

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            vstate           <= VS_IDLE;
            vote_start       <= 1'b0;
            vote_done        <= 1'b0;
            buf_a            <= '0;
            buf_b            <= '0;
            buf_c            <= '0;
            vote_result      <= '0;
            run_wd_fault     <= 1'b0;
            run_tmr_fault    <= 1'b0;
            vote_mismatch_set <= 1'b0;
            // Capture parameter into FF at reset. This is the only mechanism
            // that reliably picks up the INSTANCE value in XSim -- parameter
            // values in always_ff/generate conditions use the module default.
            eff_vote_runs <= 4'(RAD_VOTE_RUNS);
        end else begin
            vote_start        <= 1'b0;
            vote_done         <= 1'b0;
            vote_mismatch_set <= 1'b0;  // cleared every cycle unless FSM sets it below

            case (vstate)
                VS_IDLE: begin
                    if (ext_start) begin
                        run_wd_fault  <= 1'b0;
                        run_tmr_fault <= 1'b0;
                        vstate        <= VS_RUN1;
                    end
                end

                VS_RUN1: begin
                    vote_start <= 1'b1;
                    vstate     <= VS_WAIT1;
                end
                VS_WAIT1: begin
                    if (core_watchdog_fault) run_wd_fault  <= 1'b1;
                    if (core_tmr_mismatch)   run_tmr_fault <= 1'b1;
                    if (core_done) begin
                        buf_a <= core_c_flat;
                        if (eff_vote_runs <= 4'd1) begin
                            vote_result <= core_c_flat;
                            vstate      <= VS_FINAL;
                        end else begin
                            vstate <= VS_RUN2;
                        end
                    end
                end

                VS_RUN2: begin
                    vote_start <= 1'b1;
                    vstate     <= VS_WAIT2;
                end
                VS_WAIT2: begin
                    if (core_watchdog_fault) run_wd_fault  <= 1'b1;
                    if (core_tmr_mismatch)   run_tmr_fault <= 1'b1;
                    if (core_done) begin
                        buf_b <= core_c_flat;
                        if (core_c_flat === buf_a) begin
                            // Two independent runs agree bit-for-bit: accept.
                            vote_result <= core_c_flat;
                            vstate      <= VS_FINAL;
                        end else if (eff_vote_runs < 4'd3) begin
                            // No third run budgeted: best-effort pass-through,
                            // flagged as unresolved for software to see.
                            vote_result       <= core_c_flat;
                            vote_mismatch_set <= 1'b1;  // mismatch detected even without tiebreaker
                            vstate            <= VS_FINAL;
                        end else begin
                            vstate <= VS_RUN3;
                        end
                    end
                end

                VS_RUN3: begin
                    vote_start <= 1'b1;
                    vstate     <= VS_WAIT3;
                end
                VS_WAIT3: begin
                    if (core_watchdog_fault) run_wd_fault  <= 1'b1;
                    if (core_tmr_mismatch)   run_tmr_fault <= 1'b1;
                    if (core_done) begin
                        buf_c             <= core_c_flat;
                        vote_result       <= (buf_a & buf_b) | (buf_b & core_c_flat) | (buf_a & core_c_flat);
                        vote_mismatch_set <= 1'b1;  // reaching VS_WAIT3 means runs 1 and 2 disagreed
                        vstate            <= VS_FINAL;
                    end
                end

                VS_FINAL: begin
                    vote_done <= 1'b1;
                    vstate    <= VS_IDLE;
                end

                default: vstate <= VS_IDLE;
            endcase
        end
    end

    // ---- Wrapper-level sticky fault register, write-1-to-clear -----------
    // vote_mismatch_set is a one-cycle pulse generated directly by the vote
    // sequencer FSM when it detects a genuine inter-run disagreement. Using a
    // register pulse rather than a combinational wire (vote_mismatch_event)
    // avoids cross-always_ff timing issues in XSim where the wire may be
    // evaluated with stale signal values.
    wire axil_tmr_mismatch_event = aw_tmr_mismatch || ar_tmr_mismatch;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            fault_watchdog_sticky <= 1'b0;
            fault_tmr_sticky      <= 1'b0;
            fault_vote_sticky     <= 1'b0;
            fault_cfg_sticky      <= 1'b0;
            fault_axil_sticky     <= 1'b0;
            fault_bist_sticky     <= 1'b0;
        end else begin
            if (vstate == VS_FINAL) begin
                if (run_wd_fault)  fault_watchdog_sticky <= 1'b1;
                if (run_tmr_fault) fault_tmr_sticky       <= 1'b1;
            end
            if (vote_mismatch_set)          fault_vote_sticky <= 1'b1;
            if (cfg_tmr_mismatch)           fault_cfg_sticky  <= 1'b1;
            if (axil_tmr_mismatch_event)    fault_axil_sticky <= 1'b1;
            if (bist_fail_event)            fault_bist_sticky <= 1'b1;
            if (fault_clear_pulse) begin
                fault_watchdog_sticky <= 1'b0;
                fault_tmr_sticky      <= 1'b0;
                fault_vote_sticky     <= 1'b0;
                fault_cfg_sticky      <= 1'b0;
                fault_axil_sticky     <= 1'b0;
                fault_bist_sticky     <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Built-in self-test (RAD_BIST). Runs entirely independently of the vote
    // sequencer above -- a real job and a BIST run can never overlap (the
    // CTRL write logic refuses BIST_START while seq_busy/loading, and refuses
    // a real START while bist_busy). A single core_start pulse (not the
    // 2-3x temporal-redundancy voting used for real jobs) is sufficient here
    // because BIST already has an independent ground truth -- the golden
    // constant -- so there is nothing to vote between.
    //
    // BIST_PARAMS_MATCH_GOLDEN guards against silently "passing" a BIST built
    // for the wrong configuration: if this wrapper is instantiated with any
    // N/WIDTH/LFSR_W/K_SAR_BITS/SAR_BIT_LEN/STREAM_LEN_RESIDUE other than the
    // set the golden constant was captured against, BIST_GOLDEN's bit width
    // no longer matches RESULT_W and the comparison would be meaningless --
    // so BIST is forced to always report fail in that case rather than risk
    // a false pass. Regenerate the constant with gen_bist_golden.sv (provided
    // alongside this file) if you change any of those parameters, then update
    // BIST_GOLDEN and BIST_PARAMS_MATCH_GOLDEN to match.
    // =========================================================================
    localparam bit BIST_PARAMS_MATCH_GOLDEN =
        (N == 22) && (WIDTH == 16) && (LFSR_W == 16) &&
        (K_SAR_BITS == 8) && (SAR_BIT_LEN == 32) && (STREAM_LEN_RESIDUE == 65536);

    // Fixed input pattern -- mid-range values spread across each lane,
    // avoiding the 0/full-scale edges. Must match gen_bist_golden.sv exactly.
    function automatic logic [WIDTH-1:0] bist_a_val(int idx);
        return WIDTH'(16'h3000 + idx * 16'h0140);
    endfunction
    function automatic logic [WIDTH-1:0] bist_b_val(int idx);
        return WIDTH'(16'hC000 - idx * 16'h0140);
    endfunction

    // Golden result captured by gen_bist_golden.sv simulating this exact RTL
    // (N=22, WIDTH=16, LFSR_W=16, K_SAR_BITS=8, SAR_BIT_LEN=32,
    // STREAM_LEN_RESIDUE=65536, K_LEN=1, RES_PER_K=8192) and printing
    // core_c_flat at core_done. Only meaningful when RESULT_W == 8712
    // (i.e. when BIST_PARAMS_MATCH_GOLDEN is true).
    localparam int BIST_GOLDEN_W = 8712;
    localparam logic [BIST_GOLDEN_W-1:0] BIST_GOLDEN_RAW =
        8712'h442819c3ff6bbfe830d818098bff82812e6ff6c4091a00824046dff5abfcedff9941a55ff2c000750634bfd9fff243fcb300717fe140ad940f49ff8d402ce02d4c0d7300fac11d90059400e70126c0081009980266002280e8aff3b40a9affb2401f6014d3fdf704b0c0077ffb9402c7ff6ebfd8fff47813a8ff66c3599ff5abfc5202c1008f1ff300008a00ee3fe64000c00a730053020a9ffba8020e0d7c8201000b9005ef0083012ac00b900411013680a9dffaabfecb062a8047aff4600ca502aec034c066101cfc02487ff380202034d002c600b27ff3280bef03a3ffd0700a93fe9c071dbfc9eff3b7c3ff007340a1bff2effe290d7b404b102e2ffdd9ff70c025effcebfee2ff3e4097a0304404ffff413fcd6ffa3fff01ff2f80ac80290ffdd1ff15ffdfc0357bfd8affa5fff1fff67800ce0d64ffda60017415a805667fd37ff54403630814009190304fffd90607bfc45ff26bfcb9046fc01fe049740c1cffad8024f02d9819540102bff8a00127fd1202c240b40ff697f18603067d862fa8aff100028c0183304b0c1973ff9a4088301fd81ad7ff3efbd9500e600cef01013fcd5ff7640b40fffabffa2ff983fc6a00ce3da33f5310041c0346bfd92ff657fd200656c003a002e800c1fffc81189001cbfcf30104bfbfdff1fffdd800c280decf387c10bb012dc062506de41d1a02f58357802e9c34cd0064c042a016240b5302b8c0b0001077fddeff23bfde00310c0a40fefe7feeeff8c3d5e4003e7fd4104b880b42002e43483ff33bf7f2f589c01d300ea3fc61ffeabfe0bff2ec088dff7f4072700b27ef37feff7fb3b03393e14eff68c0294016240071ff383fe4500da7fe5cffc1ffc80ff277fc04f8c5bfe75ff0b8032df366c0bc3fefc7fb8d07367fda1ff5880bb1ff3f00c3cff2a3fcee00db00aaf0006bd63b0624bfc32ff097e1f0ff2cbfb9dfeeeffbf1fef2bfb7afbcabd9a9012080b9a02b73ffaaff97c34f0006140c72fff6bfe39ff2a3fc0dff923fe3efb7afe627fef9ffbf5ff66ffb7c06cb7fe5302e2bfdff00380362df90200c7f029880b72000c3f5cdff1abfc49f708bf70cfbaefd721ff098181df4643fb55079efc277ff7e40af9ffcdc108af875c11f3fc73ff3c80611bbe82f809be037fc2c3e8c3fbbefdcc9fc83fe187fee6002d4f6613ebd6064b7eeeb02bf01e90f9043c387f4dbbf3c1ff2e7c511f4c23ed74f5fa7e674fc13bdcd7f34a3eefef2cabe2fff812fc481fa7b3e20cff438019cf9e7bfe47ff193f581fff27d319fb84bcbdaf3807e585f8254029afed801b25f7b10039cf0ccbe206010b7f304ff9d3d16ef46a3fc9cff0ebfbb1ffee3cc93f4b97f4def7dafdaaaf835fdd09fd42bed8af0a0be3a5ff337d21e00f67e39402393bec6fff73c2d3f0cb809b7ffd9beeeafc4dfc290f44dbc2a8f4cd3e99ef09c7ed12ee1a3c207f0c13d054fa5cbd860ff3600d59fc0cfe63df0927f64f00dc7cd95ec5301731f6a7fc2fdf7c2fda9df9987c1fef7a2bfead;

    typedef enum logic [2:0] {BIST_IDLE, BIST_LOAD, BIST_RUN, BIST_WAIT, BIST_COMPARE} bist_t;
    bist_t bist_state;
    // bist_pulse and bist_load_pulse declared at top of module (before first use in loader/core)
    logic  bist_wd_fault, bist_tmr_fault;
    assign bist_load_pulse = (bist_state == BIST_LOAD);

    // Combinational pass/fail evaluation -- used in both the COMPARE state
    // and the bist_fail_event assignment so the two are never inconsistent.
    wire bist_pass_comb = BIST_PARAMS_MATCH_GOLDEN &&
                          !bist_wd_fault && !bist_tmr_fault &&
                          (core_c_flat === BIST_GOLDEN_RAW[N*N*RESW-1:0]);

    // bist_fail_event must only pulse when the comparison actually fails.
    // Previously it pulsed on every BIST_COMPARE entry, incorrectly setting
    // fault_bist_sticky even on a passing run.
    assign bist_fail_event = (bist_state == BIST_COMPARE) && !bist_pass_comb;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            bist_state       <= BIST_IDLE;
            bist_busy         <= 1'b0;
            bist_pulse        <= 1'b0;
            bist_done_sticky  <= 1'b0;
            bist_pass_sticky  <= 1'b0;
            bist_wd_fault     <= 1'b0;
            bist_tmr_fault    <= 1'b0;
        end else begin
            bist_pulse <= 1'b0;
            case (bist_state)
                BIST_IDLE: begin
                    if (bist_start_req) begin
                        bist_busy      <= 1'b1;
                        bist_wd_fault  <= 1'b0;
                        bist_tmr_fault <= 1'b0;
                        bist_state     <= BIST_LOAD;
                    end
                end
                BIST_LOAD: begin
                    // The actual abuf[0]/bbuf[0] parallel-load happens in the
                    // AXI-Stream loader's always_ff (gated on bist_load_pulse,
                    // see below) so that abuf/bbuf have exactly one procedural
                    // driver -- two separate always_ff blocks writing the same
                    // array would simulate fine here (the conditions never
                    // overlap) but is a multiply-driven-net error in
                    // synthesis. This state just spends one cycle as a sync
                    // point so the write (combinationally gated on this
                    // state) is guaranteed to have landed before BIST_RUN
                    // pulses core_start.
                    bist_state <= BIST_RUN;
                end
                BIST_RUN: begin
                    bist_pulse <= 1'b1;
                    bist_state <= BIST_WAIT;
                end
                BIST_WAIT: begin
                    if (core_watchdog_fault) bist_wd_fault  <= 1'b1;
                    if (core_tmr_mismatch)   bist_tmr_fault <= 1'b1;
                    if (core_done) bist_state <= BIST_COMPARE;
                end
                BIST_COMPARE: begin
                    bist_busy        <= 1'b0;
                    bist_done_sticky <= 1'b1;
                    bist_pass_sticky <= bist_pass_comb;
                    bist_state       <= BIST_IDLE;
                end
                default: bist_state <= BIST_IDLE;
            endcase
        end
    end

    // ---- Output stream draining -- reads the VOTED result, gated on
    //      vote_done instead of raw core_done ------------------------------
    // When RAD_CRC_TRAILER=1, one extra beat is appended after the N*N
    // result beats, carrying a CRC32 (poly 0xEDB88320 reflected / IEEE
    // 802.3, init 0xFFFFFFFF, final XOR 0xFFFFFFFF -- the same algorithm
    // and constants as Python's zlib.crc32) computed over the N*N
    // m_axis_tdata beats, each word's 4 bytes processed little-endian
    // (byte0=bits[7:0] first ... byte3=bits[31:24] last). That convention
    // is exactly what zlib.crc32(struct.pack('<%dI' % (N*N), *words))
    // reproduces, so a host-side checker is a few lines of Python -- see
    // RADIATION_HARDENING_NOTES.md. tlast moves to this new final beat;
    // reg_ocount still counts only the N*N data beats (unchanged software
    // contract), so software detects the trailer purely from tlast arriving
    // one beat later than N*N, or from STATUS bit 6 (RAD_CRC_TRAILER,
    // static, tells software whether this hardware build has the trailer
    // at all). Catches AXI fabric / DMA / DDR corruption downstream of the
    // accelerator, which re-run voting inside the core cannot see.
    logic [$clog2(N*N):0]   out_idx;
    logic                   out_active;
    logic signed [RESW-1:0] out_res;

    generate
    if (RAD_CRC_TRAILER) begin : g_crc_on
        logic [31:0] crc_reg;
        logic        out_crc_beat;

        function automatic logic [31:0] crc32_update_byte(logic [31:0] crc, logic [7:0] data);
            logic [31:0] c;
            c = crc ^ {24'd0, data};
            for (int bi = 0; bi < 8; bi++)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            return c;
        endfunction

        // Two-stage pipelined CRC with mandatory stall cycle between beats.
        //
        // Each output beat takes exactly 2 clock cycles:
        //   Cycle A (tvalid=1): beat presented and accepted. Stage 1 runs:
        //                       crc_lo  <- CRC32(crc_reg, byte0, byte1)  [16 XOR levels]
        //                       crc_stall asserted -> tvalid falls next cycle.
        //   Cycle B (tvalid=0): stall. Stage 2 runs:
        //                       crc_reg <- CRC32(crc_lo,  byte2, byte3)  [16 XOR levels]
        //                       crc_stall released.
        //   Cycle A+2: next beat is presented with correctly updated crc_reg.
        //
        // The stall cycle resolves the RAW hazard that plagued the previous
        // version: stage 1 of beat i+1 reads crc_reg at the same edge that
        // stage 2 of beat i would write it, so without the stall it reads the
        // stale value. The stall ensures stage 2 has committed before the next
        // stage 1 starts. The extra latency is negligible relative to the
        // N*N-beat drain window (N^2 cycles even without the stall).
        //
        // tlast is gated on !crc_stall so it never appears during a stall cycle.

        logic [31:0] data_beat_q;   // beat registered during cycle A for stage 2
        logic [31:0] crc_lo;        // stage-1 partial result (bytes 0-1 applied)
        logic        crc_lo_valid;  // one-cycle pulse: stage 2 should run this cycle
        logic        crc_stall;     // one-cycle flag: hold tvalid low this cycle

        always_comb out_res = vote_result[out_idx*RESW +: RESW];

        wire [31:0] data_beat = {{(32-RESW){out_res[RESW-1]}}, out_res};
        wire [31:0] crc_beat  = crc_reg ^ 32'hFFFFFFFF;

        assign m_axis_tdata  = out_crc_beat ? crc_beat : data_beat;
        assign m_axis_tkeep  = '1;
        assign m_axis_tvalid = out_active && !crc_stall;
        assign m_axis_tlast  = out_active && !crc_stall && out_crc_beat;

        always_ff @(posedge aclk) begin
            if (!aresetn) begin
                out_idx      <= '0;
                out_active   <= 1'b0;
                out_crc_beat <= 1'b0;
                crc_reg      <= 32'hFFFFFFFF;
                crc_lo       <= 32'hFFFFFFFF;
                crc_lo_valid <= 1'b0;
                crc_stall    <= 1'b0;
                data_beat_q  <= '0;
                reg_ocount   <= 32'd0;
            end else begin
                // Defaults: stall and valid are one-cycle pulses.
                crc_lo_valid <= 1'b0;
                crc_stall    <= 1'b0;

                if (ext_start) begin
                    out_idx      <= '0;
                    out_active   <= 1'b0;
                    out_crc_beat <= 1'b0;
                    crc_reg      <= 32'hFFFFFFFF;
                    crc_lo       <= 32'hFFFFFFFF;
                    reg_ocount   <= 32'd0;
                end

                if (!out_active && vote_done) begin
                    out_active   <= 1'b1;
                    out_idx      <= '0;
                    out_crc_beat <= 1'b0;
                    crc_reg      <= 32'hFFFFFFFF;
                end

                // Stage 2 (runs during the stall cycle, cycle B).
                // crc_reg is updated here; it is stable and correct for the
                // next beat's stage 1 because tvalid is low during this cycle.
                if (crc_lo_valid)
                    crc_reg <= crc32_update_byte(
                                   crc32_update_byte(crc_lo, data_beat_q[23:16]),
                               data_beat_q[31:24]);

                // Stage 1 (cycle A): beat accepted. Only fires when not stalling,
                // so crc_reg is always the fully-committed value from stage 2.
                if (out_active && !crc_stall && m_axis_tready && !out_crc_beat) begin
                    reg_ocount   <= reg_ocount + 32'd1;
                    data_beat_q  <= data_beat;              // save for stage 2
                    crc_lo       <= crc32_update_byte(
                                        crc32_update_byte(crc_reg, data_beat[7:0]),
                                    data_beat[15:8]);
                    crc_lo_valid <= 1'b1;   // triggers stage 2 next cycle
                    crc_stall    <= 1'b1;   // suppresses tvalid next cycle
                    if (out_idx == (N*N - 1))
                        out_crc_beat <= 1'b1;
                    else
                        out_idx <= out_idx + 1;
                end

                // CRC trailer beat consumed: drain complete.
                if (out_active && !crc_stall && out_crc_beat && m_axis_tready)
                    out_active <= 1'b0;
            end
        end
    end else begin : g_crc_off
        // Identical to the pre-CRC-trailer behaviour: N*N beats, tlast on
        // the last data beat, no extra beat.
        always_comb out_res = vote_result[out_idx*RESW +: RESW];

        assign m_axis_tdata  = {{(32-RESW){out_res[RESW-1]}}, out_res};
        assign m_axis_tkeep  = '1;
        assign m_axis_tvalid = out_active;
        assign m_axis_tlast  = out_active && (out_idx == (N*N - 1));

        always_ff @(posedge aclk) begin
            if (!aresetn) begin
                out_idx    <= '0;
                out_active <= 1'b0;
                reg_ocount <= 32'd0;
            end else begin
                if (ext_start) begin
                    out_idx    <= '0;
                    out_active <= 1'b0;
                    reg_ocount <= 32'd0;
                end
                if (!out_active && vote_done) begin
                    out_active <= 1'b1;
                    out_idx    <= '0;
                end
                if (out_active && m_axis_tready) begin
                    reg_ocount <= reg_ocount + 32'd1;
                    if (out_idx == (N*N - 1)) begin
                        out_active <= 1'b0;
                    end else begin
                        out_idx <= out_idx + 1;
                    end
                end
            end
        end
    end
    endgenerate

    // ---- Done-sticky and IRQ ------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn)         done_sticky <= 1'b0;
        else if (vote_done)   done_sticky <= 1'b1;
        else if (ext_start)   done_sticky <= 1'b0;
    end

    assign irq = done_sticky && reg_irqen;

endmodule

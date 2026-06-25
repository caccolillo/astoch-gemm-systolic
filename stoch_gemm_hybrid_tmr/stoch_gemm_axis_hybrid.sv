`timescale 1ns/1ps

// =============================================================================
// stoch_gemm_axis_hybrid.sv
// AXI-Stream + AXI-Lite wrapper around stoch_gemm_top_hybrid.
//
// Drop-in compatible with the original stoch_gemm_axis.sv:
//   - Same AXI-Lite register map (CTRL, STATUS, K_LEN, INFO, INFO2, ICOUNT, OCOUNT)
//   - Same AXI-Stream input format: 2*N*K beats per job, kernel-on-a/patches-on-b
//   - Same AXI-Stream output format: N*N beats, signed RESW sign-extended to 32
//   - Same IRQ behaviour
//
// What is different:
//   - Instantiates stoch_gemm_top_hybrid instead of stoch_gemm_top
//   - INFO2 reports STREAM_LEN_RESIDUE (the residue counter length)
//   - A new INFO3 register reports {K_SAR_BITS, SAR_BIT_LEN} so software
//     can use the correct hybrid decode formula
//   - RESW is generally wider than the plain-counter version (WIDTH + 2)
//
// SOFTWARE DECODE FORMULA (different from the plain counter design!)
//   real_value_per_term = c_flat / 2^(WIDTH-1)
//   real_value_sum      = c_flat * K / 2^(WIDTH-1)
//   pixel_value         = real_value_sum * 255 * kmax / kern_sum
//
//   Plain-counter design used:
//     pixel_value = c_flat * 255 * kmax / kern_sum / STREAM_LEN
//
//   These are NOT interchangeable. Software must detect hybrid mode (via
//   bit 31 of INFO2) and apply the correct formula.
// =============================================================================

module stoch_gemm_axis_hybrid #(
    parameter int N                  = 8,
    parameter int WIDTH              = 16,
    parameter int LFSR_W             = 16,
    parameter int K_SAR_BITS         = 8,
    parameter int SAR_BIT_LEN        = 32,
    parameter int STREAM_LEN_RESIDUE = 65536,
    parameter int KW                 = 16,
    parameter int KBUF_MAX           = 16,
    parameter int C_S_AXI_ADDR_WIDTH = 12,
    parameter int C_S_AXI_DATA_WIDTH = 32
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

    // ---- Derived widths (must match stoch_gemm_top_hybrid) ---------------
    localparam int RESW = WIDTH + 2;
    // CNTW for INFO reporting (residue counter width)
    localparam int CNTW = $clog2(STREAM_LEN_RESIDUE + 1);

    // ---- AXI-Lite register file ------------------------------------------
    localparam logic [3:0] A_CTRL   = 4'h0;
    localparam logic [3:0] A_STATUS = 4'h4;
    localparam logic [3:0] A_KLEN   = 4'h8;
    localparam logic [3:0] A_INFO   = 4'hC;
    localparam logic [3:0] A_INFO2  = 4'h0; // 0x10 -> low nibble 0
    localparam logic [3:0] A_ICOUNT = 4'h4; // 0x14
    localparam logic [3:0] A_OCOUNT = 4'h8; // 0x18
    localparam logic [3:0] A_INFO3  = 4'hC; // 0x1C

    // The original wrapper uses 5-bit address decoding internally. Same here.
    // 6-bit address decode: needs to reach 0x20 (RES_PER_K register).
    // Was 5 bits which silently aliased 0x20 onto 0x00 (CTRL register)
    // and made writes to RES_PER_K invisible -- they pulsed START instead.
    logic [5:0] aw_addr_q, ar_addr_q;

    logic [KW-1:0]  reg_klen;
    logic [31:0]    reg_res_per_k;     // res_per_k written by software
    logic           reg_irqen;
    logic           core_start;
    logic           core_busy, core_done;
    logic           done_sticky;
    logic [31:0]    reg_icount, reg_ocount;

    // ---- Operand buffers (the same logical structure as the original) ---
    logic [WIDTH-1:0] abuf [KBUF_MAX][N];
    logic [WIDTH-1:0] bbuf [KBUF_MAX][N];

    logic [KW-1:0]  in_term;
    logic           in_half;        // 0 = a-bus, 1 = b-bus
    logic [$clog2(N)-1:0] in_lane;
    logic           loading;        // accept input beats while loading

    // ---- Core interface (matches stoch_gemm_top_hybrid) ------------------
    logic                       core_load_k;
    logic [$clog2(KBUF_MAX)-1:0] core_kidx;
    logic [N*WIDTH-1:0]         core_a_bin, core_b_bin;
    logic signed [N*N*RESW-1:0] core_c_flat;

    // ---- AXI-Lite write FSM ----------------------------------------------
    typedef enum logic [1:0] {AW_IDLE, AW_ADDR, AW_DATA, AW_RESP} aw_t;
    aw_t aw_state;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            aw_state       <= AW_IDLE;
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bvalid   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            aw_addr_q      <= '0;
            reg_klen       <= '0;
            reg_res_per_k  <= 32'd8192;   // safe default for K=9, SLR=65536
            reg_irqen      <= 1'b0;
            core_start     <= 1'b0;
        end else begin
            core_start <= 1'b0;  // self-clearing
            case (aw_state)
                AW_IDLE: begin
                    s_axi_awready <= 1'b1;
                    s_axi_wready  <= 1'b0;
                    s_axi_bvalid  <= 1'b0;
                    if (s_axi_awvalid) begin
                        aw_addr_q     <= s_axi_awaddr[5:0];
                        s_axi_awready <= 1'b0;
                        s_axi_wready  <= 1'b1;
                        aw_state      <= AW_DATA;
                    end
                end
                AW_DATA: begin
                    if (s_axi_wvalid) begin
                        case (aw_addr_q)
                            6'h00: begin // CTRL
                                if (s_axi_wdata[0]) core_start <= 1'b1;
                                reg_irqen <= s_axi_wdata[1];
                            end
                            6'h08: reg_klen <= s_axi_wdata[KW-1:0];
                            6'h20: reg_res_per_k <= s_axi_wdata[31:0];
                            default: ;
                        endcase
                        s_axi_wready <= 1'b0;
                        s_axi_bvalid <= 1'b1;
                        s_axi_bresp  <= 2'b00;
                        aw_state     <= AW_RESP;
                    end
                end
                AW_RESP: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        aw_state     <= AW_IDLE;
                    end
                end
                default: aw_state <= AW_IDLE;
            endcase
        end
    end

    // ---- AXI-Lite read FSM -----------------------------------------------
    typedef enum logic [1:0] {AR_IDLE, AR_RESP} ar_t;
    ar_t ar_state;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            ar_state      <= AR_IDLE;
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
                        ar_state      <= AR_RESP;
                    end
                end
                AR_RESP: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        ar_state     <= AR_IDLE;
                    end
                end
                default: ar_state <= AR_IDLE;
            endcase
        end
    end

    always_comb begin
        s_axi_rdata = 32'd0;
        case (ar_addr_q)
            6'h00: s_axi_rdata = {30'd0, reg_irqen, 1'b0};                // CTRL
            6'h04: s_axi_rdata = {30'd0, done_sticky, core_busy};         // STATUS
            6'h08: s_axi_rdata = {{(32-KW){1'b0}}, reg_klen};             // K_LEN
            6'h0C: s_axi_rdata = {RESW[7:0], CNTW[7:0], KW[7:0], N[7:0]}; // INFO
            // INFO2 high bit set to mark hybrid converter mode
            6'h10: s_axi_rdata = {1'b1, 7'd0, STREAM_LEN_RESIDUE[23:0]};   // INFO2
            6'h14: s_axi_rdata = reg_icount;                              // ICOUNT
            6'h18: s_axi_rdata = reg_ocount;                              // OCOUNT
            6'h1C: s_axi_rdata = {16'd0, SAR_BIT_LEN[7:0], K_SAR_BITS[7:0]}; // INFO3
            6'h20: s_axi_rdata = reg_res_per_k;                           // RES_PER_K
            default: s_axi_rdata = 32'd0;
        endcase
    end

    // ---- AXI-Stream input: load operands into abuf/bbuf -----------------
    assign s_axis_tready = loading;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            in_term    <= '0;
            in_half    <= 1'b0;
            in_lane    <= '0;
            loading    <= 1'b1;
            reg_icount <= 32'd0;
        end else if (core_start) begin
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

    // ---- Drive core operand buses from buffers ---------------------------
    // CRITICAL: the previous bounds check
    //     if (core_kidx < KBUF_MAX[$clog2(KBUF_MAX)-1:0]) ...
    // was BROKEN because KBUF_MAX[5:0] for KBUF_MAX=64 (=0b01000000) is 0.
    // The comparison was therefore "core_kidx < 0", always false, and the
    // wrapper unconditionally drove core_a_bin/core_b_bin to zero -- the
    // core saw all-zero operands and saturated c_flat at max-positive
    // (bipolar-product (-1)x(-1) = +1 every term, summed = +K).
    //
    // Direct indexing is safe here: core_kidx is $clog2(KBUF_MAX) bits wide
    // (6 bits for KBUF_MAX=64) and abuf has exactly KBUF_MAX entries, so
    // every value of core_kidx is in range by construction.
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

    // ---- Core instance ---------------------------------------------------
    stoch_gemm_top_hybrid #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .K_SAR_BITS(K_SAR_BITS),
        .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE),
        .KMAX(KBUF_MAX), .RESW(RESW)
    ) u_core (
        .clk         (aclk),
        .rst_n       (aresetn),
        .core_start  (core_start),
        .k_len       (reg_klen),
        .res_per_k   (reg_res_per_k),
        .core_busy   (core_busy),
        .core_done   (core_done),
        .core_kidx   (core_kidx),
        .core_load_k (core_load_k),
        .core_a_bin  (core_a_bin),
        .core_b_bin  (core_b_bin),
        .core_c_flat (core_c_flat)
    );

    // ---- Output stream draining -----------------------------------------
    logic [$clog2(N*N):0] out_idx;
    logic                 out_active;
    logic signed [RESW-1:0] out_res;

    always_comb out_res = core_c_flat[out_idx*RESW +: RESW];

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
            if (core_start) begin
                out_idx    <= '0;
                out_active <= 1'b0;
                reg_ocount <= 32'd0;
            end
            if (!out_active && core_done) begin
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

    // ---- Done-sticky and IRQ ---------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn)              done_sticky <= 1'b0;
        else if (core_done)        done_sticky <= 1'b1;
        else if (core_start)       done_sticky <= 1'b0;
    end

    assign irq = done_sticky && reg_irqen;

endmodule

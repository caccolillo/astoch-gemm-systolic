`timescale 1ns/1ps

// =============================================================================
// stoch_gemm_axis.sv
// Streaming wrapper around stoch_gemm_top: AXI4-Lite for control + AXI4-Stream
// for bulk data, with an input FIFO. Designed to be driven by an AXI DMA on a
// Zynq UltraScale+ HP port.
//
// WHY THIS EXISTS (vs. the register-mapped stoch_gemm_axil.sv)
//   The AXI-Lite-only wrapper moves operands one 32-bit word per AXI
//   transaction -- ~5-8 cycles each, with the CPU issuing every write. For one
//   8x8 tile that is ~140+ transactions. This wrapper instead takes operands
//   as an AXI-Stream burst: a DMA pushes a whole tile's operands in back-to-
//   back beats, the CPU just sets up one descriptor, and a FIFO decouples the
//   DMA's bursty delivery from the core's paced consumption. Results leave the
//   same way, as an output stream a DMA drains to DDR.
//   AXI-Lite is RETAINED, but only for control (start/status/config/irq) --
//   the thing it is actually good at.
//
// DATA FORMAT ON THE STREAMS
//   Input stream  s_axis : one 32-bit beat per operand, low WIDTH bits used.
//     Order, per GEMM job: for term k = 0..K-1:
//        N beats of a-operands  (lane 0..N-1)
//        N beats of b-operands  (lane 0..N-1)
//     i.e. 2*N beats per term, K terms => 2*N*K beats total.
//     TLAST should mark the final beat of the job (optional but recommended).
//   Output stream m_axis : one 32-bit beat per result element, N*N beats,
//     element index 0..N*N-1 in row-major order. Each beat is the signed
//     result numerator, sign-extended to 32 bits. Real value = numerator /
//     STREAM_LEN. TLAST marks the last (element N*N-1).
//
// PROGRAMMING MODEL (ARM)
//   1. Write K_LEN with the contraction depth K.
//   2. Set up a DMA MM2S transfer of 2*N*K words from DDR to s_axis.
//   3. Write CTRL.START = 1.
//   4. Set up a DMA S2MM transfer of N*N words from m_axis to DDR.
//   5. Wait for irq / poll STATUS.DONE.
//
// AXI-Lite register map (unchanged subset of stoch_gemm_axil.sv)
//   0x00 CTRL    W  bit0 START (self-clearing), bit1 IRQ_EN
//   0x04 STATUS  R  bit0 BUSY, bit1 DONE (DONE clears on next START)
//   0x08 K_LEN   RW contraction depth K
//   0x0C INFO    R  {RESW,CNTW,KW,N} build params (8 bits each)
//   0x10 INFO2   R  STREAM_LEN
//   0x14 ICOUNT  R  input-stream beats received for the current job (debug)
//   0x18 OCOUNT  R  output-stream beats sent for the current job (debug)
// =============================================================================

module stoch_gemm_axis #(
    parameter int N          = 8,
    parameter int WIDTH      = 16,
    parameter int LFSR_W     = 16,
    parameter int STREAM_LEN = 1024,
    parameter int KW         = 16,
    parameter int KBUF_MAX   = 64,           // max contraction depth buffered
    parameter int C_S_AXI_ADDR_WIDTH = 12,
    parameter int C_S_AXI_DATA_WIDTH = 32
) (
    // ---- Clock / reset (single domain) -------------------------------------
    input  logic                              aclk,
    input  logic                              aresetn,        // active-LOW

    // ---- AXI4-Lite slave : control -----------------------------------------
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

    // ---- AXI4-Stream slave : operand input ---------------------------------
    input  logic [31:0]                        s_axis_tdata,
    input  logic                               s_axis_tvalid,
    output logic                               s_axis_tready,
    input  logic                               s_axis_tlast,

    // ---- AXI4-Stream master : result output --------------------------------
    output logic [31:0]                        m_axis_tdata,
    output logic                               m_axis_tvalid,
    input  logic                               m_axis_tready,
    output logic                               m_axis_tlast,

    // ---- Interrupt to PS ---------------------------------------------------
    output logic                               irq
);

    // ---- Derived widths (mirror stoch_gemm_top) ----------------------------
    localparam int CNTW = $clog2((1<<KW)-1) + $clog2(STREAM_LEN + 1) + 1;
    localparam int RESW = CNTW + 2;

    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_CTRL   = 'h00 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_STATUS = 'h04 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_KLEN   = 'h08 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_INFO   = 'h0C >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_INFO2  = 'h10 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_ICOUNT = 'h14 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_OCOUNT = 'h18 >> 2;

    logic core_rst;
    assign core_rst = ~aresetn;

    // =========================================================================
    // Control registers
    // =========================================================================
    logic [KW-1:0] reg_klen;
    logic          reg_irq_en;
    logic          core_start;
    logic          done_sticky;

    // =========================================================================
    // Operand buffer : [term][lane] for a and b. Filled from the input stream.
    // =========================================================================
    logic [WIDTH-1:0] abuf [KBUF_MAX][N];
    logic [WIDTH-1:0] bbuf [KBUF_MAX][N];

    // Input-stream sequencer: beats arrive as
    //   term 0: a[0..N-1], b[0..N-1]   term 1: a[0..N-1], b[0..N-1]  ...
    // Track (term, half, lane): half 0 = a-operands, half 1 = b-operands.
    logic [$clog2(KBUF_MAX)-1:0] in_term;
    logic                        in_half;     // 0 = a, 1 = b
    logic [$clog2(N)-1:0]         in_lane;
    logic [31:0]                  in_count;   // total beats received (debug)

    // Accept input only while not computing and buffer not yet full for K.
    logic loading;          // 1 while we still expect operands for this job
    assign s_axis_tready = loading;

    wire in_beat = s_axis_tvalid & s_axis_tready;

    always_ff @(posedge aclk) begin
        if (core_rst) begin
            in_term  <= '0;
            in_half  <= 1'b0;
            in_lane  <= '0;
            in_count <= '0;
            loading  <= 1'b1;        // ready to receive a job's operands
        end else begin
            if (core_start) begin
                // a new job consumes the buffered operands; reset the input
                // sequencer for the *next* job's load.
                in_term  <= '0;
                in_half  <= 1'b0;
                in_lane  <= '0;
                in_count <= '0;
                loading  <= 1'b1;
            end else if (in_beat) begin
                in_count <= in_count + 1;
                // store this beat
                if (in_half == 1'b0)
                    abuf[in_term][in_lane] <= s_axis_tdata[WIDTH-1:0];
                else
                    bbuf[in_term][in_lane] <= s_axis_tdata[WIDTH-1:0];
                // advance (lane -> half -> term)
                if (in_lane == N-1) begin
                    in_lane <= '0;
                    if (in_half == 1'b0) begin
                        in_half <= 1'b1;
                    end else begin
                        in_half <= 1'b0;
                        in_term <= in_term + 1;
                    end
                end else begin
                    in_lane <= in_lane + 1;
                end
                // TLAST (or reaching K terms) ends the load phase.
                if (s_axis_tlast ||
                    (in_term == reg_klen-1 && in_half == 1'b1 && in_lane == N-1))
                    loading <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Core instance + operand replay
    // =========================================================================
    logic               core_busy, core_done, core_load_k;
    logic [KW-1:0]       core_kidx;
    logic [N*WIDTH-1:0]  core_a_bin, core_b_bin;
    logic [N*N*RESW-1:0] core_c_flat;

    integer li;
    always_ff @(posedge aclk) begin
        if (core_rst) begin
            core_a_bin <= '0;
            core_b_bin <= '0;
        end else begin
            for (li = 0; li < N; li++) begin
                if (core_kidx < KW'(KBUF_MAX)) begin
                    core_a_bin[li*WIDTH +: WIDTH] <= abuf[core_kidx][li];
                    core_b_bin[li*WIDTH +: WIDTH] <= bbuf[core_kidx][li];
                end else begin
                    core_a_bin[li*WIDTH +: WIDTH] <= '0;
                    core_b_bin[li*WIDTH +: WIDTH] <= '0;
                end
            end
        end
    end

    stoch_gemm_top #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .STREAM_LEN(STREAM_LEN), .KW(KW)
    ) u_core (
        .clk(aclk), .rst(core_rst), .start(core_start), .k_len(reg_klen),
        .a_bin(core_a_bin), .b_bin(core_b_bin),
        .load_k(core_load_k), .k_idx(core_kidx),
        .busy(core_busy), .done(core_done), .c_flat(core_c_flat)
    );

    // =========================================================================
    // Output stream : when the core finishes, walk c_flat element by element
    // out through m_axis.
    // =========================================================================
    typedef enum logic [1:0] {O_IDLE, O_SEND, O_DONE} ostate_t;
    ostate_t                     ostate;
    logic [$clog2(N*N)-1:0]      out_idx;
    logic [31:0]                 out_count;

    logic signed [RESW-1:0] out_res;
    always_comb out_res = core_c_flat[out_idx*RESW +: RESW];

    assign m_axis_tdata  = {{(32-RESW){out_res[RESW-1]}}, out_res};
    assign m_axis_tvalid = (ostate == O_SEND);
    assign m_axis_tlast  = (ostate == O_SEND) && (out_idx == N*N-1);

    wire out_beat = m_axis_tvalid & m_axis_tready;

    always_ff @(posedge aclk) begin
        if (core_rst) begin
            ostate    <= O_IDLE;
            out_idx   <= '0;
            out_count <= '0;
        end else begin
            case (ostate)
                O_IDLE: begin
                    if (core_done) begin       // core finished: start draining
                        ostate    <= O_SEND;
                        out_idx   <= '0;
                        out_count <= '0;
                    end
                end
                O_SEND: begin
                    if (out_beat) begin
                        out_count <= out_count + 1;
                        if (out_idx == N*N-1)
                            ostate <= O_DONE;
                        else
                            out_idx <= out_idx + 1;
                    end
                end
                O_DONE: begin
                    if (core_start)            // next job re-arms the drainer
                        ostate <= O_IDLE;
                end
                default: ostate <= O_IDLE;
            endcase
        end
    end

    // =========================================================================
    // done_sticky : set when the whole output stream has been drained, cleared
    // on the next START. (Completion = results delivered, not just computed.)
    // =========================================================================
    always_ff @(posedge aclk) begin
        if (core_rst)            done_sticky <= 1'b0;
        else if (core_start)     done_sticky <= 1'b0;
        else if (ostate == O_SEND && out_beat && out_idx == N*N-1)
            done_sticky <= 1'b1;
    end
    assign irq = reg_irq_en & done_sticky;

    // =========================================================================
    // AXI4-Lite control (write + read) -- compact slave, same style as
    // stoch_gemm_axil.sv.
    // =========================================================================
    logic                          aw_en;
    logic [C_S_AXI_ADDR_WIDTH-1:0]  awaddr_q;
    logic                           wr_commit;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
            awaddr_q <= '0; aw_en <= 1'b1;
        end else begin
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1; awaddr_q <= s_axi_awaddr; aw_en <= 1'b0;
            end else s_axi_awready <= 1'b0;
            if (!s_axi_wready && s_axi_awvalid && s_axi_wvalid && aw_en)
                s_axi_wready <= 1'b1;
            else s_axi_wready <= 1'b0;
            if (s_axi_bvalid && s_axi_bready) aw_en <= 1'b1;
        end
    end
    assign wr_commit = s_axi_awready & s_axi_awvalid &
                       s_axi_wready  & s_axi_wvalid;

    always_ff @(posedge aclk) begin
        if (core_rst) begin
            reg_klen   <= KW'(1);
            reg_irq_en <= 1'b0;
            core_start <= 1'b0;
        end else begin
            core_start <= 1'b0;                     // self-clearing pulse
            if (wr_commit) begin
                case (awaddr_q[C_S_AXI_ADDR_WIDTH-1:2])
                    A_CTRL: begin
                        if (s_axi_wdata[0]) core_start <= 1'b1;
                        reg_irq_en <= s_axi_wdata[1];
                    end
                    A_KLEN: reg_klen <= s_axi_wdata[KW-1:0];
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
        end else begin
            if (wr_commit && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    logic [C_S_AXI_ADDR_WIDTH-3:0] rd_word;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0; rd_word <= '0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                rd_word <= s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2];
            end else s_axi_arready <= 1'b0;
        end
    end
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0; s_axi_rresp <= 2'b00;
        end else begin
            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
            end else if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    always_comb begin
        unique case (rd_word)
            A_CTRL:   s_axi_rdata = {30'd0, reg_irq_en, 1'b0};
            A_STATUS: s_axi_rdata = {30'd0, done_sticky, core_busy};
            A_KLEN:   s_axi_rdata = {{(32-KW){1'b0}}, reg_klen};
            A_INFO:   s_axi_rdata = {RESW[7:0], CNTW[7:0], KW[7:0], N[7:0]};
            A_INFO2:  s_axi_rdata = STREAM_LEN[31:0];
            A_ICOUNT: s_axi_rdata = in_count;
            A_OCOUNT: s_axi_rdata = out_count;
            default:  s_axi_rdata = 32'h0;
        endcase
    end

endmodule

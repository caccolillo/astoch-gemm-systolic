`timescale 1ns/1ps

// =============================================================================
// stoch_gemm_axil.sv
// AXI4-Lite slave wrapper around stoch_gemm_top.
//
// Purpose
//   Turns the stochastic GEMM core into a memory-mapped peripheral the ARM
//   (Zynq UltraScale+ PS) can drive over an AXI4-Lite control port. This is
//   the first integration block: it makes the accelerator addressable. Bulk
//   data still moves through these registers here (fine for one 8x8 tile);
//   a later revision can add an AXI-Stream / DMA path for higher throughput.
//
// Why a register-mapped wrapper needs an operand buffer
//   stoch_gemm_top does NOT take all its operands at once. It streams them by
//   contraction term: it pulses 'load_k', and on that pulse expects that
//   term's a_bin / b_bin. There are K terms. AXI-Lite, by contrast, is a
//   random-access register interface with no streaming notion. So this
//   wrapper holds an ON-CHIP OPERAND BUFFER: software writes all K terms of
//   a_bin/b_bin into the buffer first, then starts the core; the wrapper then
//   replays the buffered operands to the core, one term per 'load_k' pulse,
//   indexed by the core's 'k_idx' output.
//
// Programming model (software, from the ARM)
//   1. Write K_LEN with the contraction depth K (1..K_MAX).
//   2. For term k = 0..K-1:
//        - write OPERAND_IDX = k
//        - write A_BIN_0..A_BIN_{N-1}  (the N a-operands for term k)
//        - write B_BIN_0..B_BIN_{N-1}  (the N b-operands for term k)
//      (each write to an A_BIN_i / B_BIN_i lands in buffer[OPERAND_IDX].)
//   3. Write CTRL.START = 1 (self-clearing). The core runs.
//   4. Poll STATUS.DONE (or wait for the irq output), then read STATUS.BUSY=0.
//   5. Read results: write RESULT_IDX = element index (0..N*N-1), then read
//      RESULT_LO / RESULT_HI for that element's signed numerator. The real
//      value is numerator / STREAM_LEN (STREAM_LEN is a build-time constant,
//      also readable from the INFO register).
//
// Register map (AXI-Lite, 4-byte words; offsets in bytes)
//   0x00  CTRL        W   bit0 START (self-clearing), bit1 IRQ_EN
//   0x04  STATUS      R   bit0 BUSY, bit1 DONE (DONE clears on read of STATUS)
//   0x08  K_LEN       RW  contraction depth K
//   0x0C  OPERAND_IDX RW  which term (0..K-1) the A_BIN/B_BIN writes target
//   0x10  RESULT_IDX  RW  which result element (0..N*N-1) RESULT_LO/HI return
//   0x14  RESULT_LO   R   low 32 bits of the selected result numerator
//   0x18  RESULT_HI   R   high bits (sign-extended) of the selected result
//   0x1C  INFO        R   {RESW[7:0], CNTW[7:0], KW[7:0], N[7:0]} build params
//   0x20  INFO2       R   STREAM_LEN (the de-bias divisor for software)
//   0x40  A_BIN_0..   RW  N words: a-operands for term OPERAND_IDX  (0x40+4*i)
//   0x80  B_BIN_0..   RW  N words: b-operands for term OPERAND_IDX  (0x80+4*i)
//
// Notes
//   - Reset 'rst' is synchronous, ACTIVE-HIGH on the core. AXI uses an
//     active-LOW reset (s_axi_aresetn) per the AXI spec; this wrapper inverts
//     it once for the core. Everything is in the single s_axi_aclk domain.
//   - WIDTH (operand width) must be <= 32 so each operand fits one AXI word.
//   - This wrapper is deliberately simple (no AXI-Stream, no DMA). It is the
//     control plane; a DMA data plane is a separate, later block.
// =============================================================================

module stoch_gemm_axil #(
    // Core parameters -- forwarded to stoch_gemm_top.
    parameter int N          = 8,
    parameter int WIDTH      = 16,
    parameter int LFSR_W     = 16,
    parameter int STREAM_LEN = 1024,
    parameter int KW         = 16,
    // AXI-Lite address width. 12 bits = 4 KB, ample for this map.
    parameter int C_S_AXI_ADDR_WIDTH = 12,
    parameter int C_S_AXI_DATA_WIDTH = 32
) (
    // ---- AXI4-Lite slave interface -----------------------------------------
    input  logic                                  s_axi_aclk,
    input  logic                                  s_axi_aresetn,   // active-LOW

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]          s_axi_awaddr,
    input  logic [2:0]                             s_axi_awprot,
    input  logic                                   s_axi_awvalid,
    output logic                                   s_axi_awready,

    input  logic [C_S_AXI_DATA_WIDTH-1:0]          s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0]      s_axi_wstrb,
    input  logic                                   s_axi_wvalid,
    output logic                                   s_axi_wready,

    output logic [1:0]                             s_axi_bresp,
    output logic                                   s_axi_bvalid,
    input  logic                                   s_axi_bready,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]          s_axi_araddr,
    input  logic [2:0]                             s_axi_arprot,
    input  logic                                   s_axi_arvalid,
    output logic                                   s_axi_arready,

    output logic [C_S_AXI_DATA_WIDTH-1:0]          s_axi_rdata,
    output logic [1:0]                             s_axi_rresp,
    output logic                                   s_axi_rvalid,
    input  logic                                   s_axi_rready,

    // ---- Interrupt to the PS (level, active-high) --------------------------
    output logic                                   irq
);

    // ---- Derived widths (must mirror stoch_gemm_top) -----------------------
    localparam int CNTW = $clog2((1<<KW)-1) + $clog2(STREAM_LEN + 1) + 1;
    localparam int RESW = CNTW + 2;
    localparam int K_MAX = (1 << KW) - 1;

    // ---- Register offsets (word addresses; byte offset = word*4) -----------
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_CTRL    = 'h00 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_STATUS  = 'h04 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_KLEN    = 'h08 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_OPIDX   = 'h0C >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_RESIDX  = 'h10 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_RESLO   = 'h14 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_RESHI   = 'h18 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_INFO    = 'h1C >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_INFO2   = 'h20 >> 2;
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_ABASE   = 'h40 >> 2;  // .. +N
    localparam logic [C_S_AXI_ADDR_WIDTH-3:0] A_BBASE   = 'h80 >> 2;  // .. +N

    // =========================================================================
    // Core-facing reset: stoch_gemm_top uses synchronous ACTIVE-HIGH reset.
    // =========================================================================
    logic core_rst;
    assign core_rst = ~s_axi_aresetn;

    // =========================================================================
    // Software-visible registers + the on-chip operand buffer.
    // =========================================================================
    logic [KW-1:0]              reg_klen;
    logic [KW-1:0]              reg_opidx;     // term index for operand writes
    logic [$clog2(N*N)-1:0]     reg_residx;    // result element to read back
    logic                       reg_irq_en;

    // Operand buffer: for each contraction term, the N a- and N b-operands.
    // Indexed [term][lane]. K_MAX terms would be huge; size to a practical
    // maximum number of terms the buffer supports. KBUF_MAX caps it.
    localparam int KBUF_MAX = 64;          // max contraction depth this wrapper buffers
    logic [WIDTH-1:0] abuf [KBUF_MAX][N];
    logic [WIDTH-1:0] bbuf [KBUF_MAX][N];

    // ---- Core handshake signals --------------------------------------------
    logic               core_start;
    logic               core_busy;
    logic               core_done;
    logic               core_load_k;
    logic [KW-1:0]       core_kidx;
    logic [N*WIDTH-1:0]  core_a_bin;
    logic [N*WIDTH-1:0]  core_b_bin;
    logic [N*N*RESW-1:0] core_c_flat;

    // 'done' is a 1-cycle pulse from the core; latch it into a sticky status
    // bit that software clears by reading STATUS.
    logic done_sticky;

    // =========================================================================
    // Operand replay: drive the core's a_bin/b_bin from the buffer, selected
    // by the core's current term index k_idx. Registered for clean timing
    // (the core's S_LOAD/S_LATCH gives the needed setup cycle).
    // =========================================================================
    integer li;
    always_ff @(posedge s_axi_aclk) begin
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

    // =========================================================================
    // The stochastic GEMM core.
    // =========================================================================
    stoch_gemm_top #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .STREAM_LEN(STREAM_LEN), .KW(KW)
    ) u_core (
        .clk    (s_axi_aclk),
        .rst    (core_rst),
        .start  (core_start),
        .k_len  (reg_klen),
        .a_bin  (core_a_bin),
        .b_bin  (core_b_bin),
        .load_k (core_load_k),
        .k_idx  (core_kidx),
        .busy   (core_busy),
        .done   (core_done),
        .c_flat (core_c_flat)
    );

    // =========================================================================
    // AXI4-Lite WRITE channel
    // =========================================================================
    logic                              aw_en;       // ready to accept a write
    logic [C_S_AXI_ADDR_WIDTH-1:0]      awaddr_q;
    logic                              wr_commit;   // a write lands this cycle

    // Address/data handshake: classic Xilinx AXI-Lite slave style.
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            awaddr_q      <= '0;
            aw_en         <= 1'b1;
        end else begin
            // Accept address when both AW and W are presented and we are armed.
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                awaddr_q      <= s_axi_awaddr;
                aw_en         <= 1'b0;
            end else begin
                s_axi_awready <= 1'b0;
            end
            // Accept data on the same condition.
            if (!s_axi_wready && s_axi_awvalid && s_axi_wvalid && aw_en)
                s_axi_wready <= 1'b1;
            else
                s_axi_wready <= 1'b0;
            // Re-arm after the write response handshake completes.
            if (s_axi_bvalid && s_axi_bready)
                aw_en <= 1'b1;
        end
    end

    assign wr_commit = s_axi_awready && s_axi_awvalid &&
                       s_axi_wready  && s_axi_wvalid;

    // Word address of the current write.
    logic [C_S_AXI_ADDR_WIDTH-3:0] wr_word;
    assign wr_word = awaddr_q[C_S_AXI_ADDR_WIDTH-1:2];

    // ---- Register write actions --------------------------------------------
    integer wi;
    always_ff @(posedge s_axi_aclk) begin
        if (core_rst) begin
            reg_klen   <= KW'(1);
            reg_opidx  <= '0;
            reg_residx <= '0;
            reg_irq_en <= 1'b0;
            core_start <= 1'b0;
        end else begin
            // START is a 1-cycle self-clearing pulse.
            core_start <= 1'b0;

            if (wr_commit) begin
                case (wr_word)
                    A_CTRL: begin
                        if (s_axi_wdata[0]) core_start <= 1'b1;   // START
                        reg_irq_en <= s_axi_wdata[1];             // IRQ_EN
                    end
                    A_KLEN:   reg_klen   <= s_axi_wdata[KW-1:0];
                    A_OPIDX:  reg_opidx  <= s_axi_wdata[KW-1:0];
                    A_RESIDX: reg_residx <= s_axi_wdata[$clog2(N*N)-1:0];
                    default:  ; // operand-buffer writes handled below
                endcase

                // Operand buffer writes: A_BIN_i at A_ABASE+i, B_BIN_i at
                // A_BBASE+i, targeting term reg_opidx.
                for (wi = 0; wi < N; wi++) begin
                    if (wr_word == (A_ABASE + wi[C_S_AXI_ADDR_WIDTH-3:0]) &&
                        reg_opidx < KW'(KBUF_MAX))
                        abuf[reg_opidx][wi] <= s_axi_wdata[WIDTH-1:0];
                    if (wr_word == (A_BBASE + wi[C_S_AXI_ADDR_WIDTH-3:0]) &&
                        reg_opidx < KW'(KBUF_MAX))
                        bbuf[reg_opidx][wi] <= s_axi_wdata[WIDTH-1:0];
                end
            end
        end
    end

    // ---- Write response -----------------------------------------------------
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (wr_commit && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;          // OKAY
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // done / busy status tracking
    // =========================================================================
    // done_sticky latches the core's 1-cycle 'done' pulse so software can see
    // completion. It is CLEARED when software issues a new START -- NOT on a
    // STATUS read. Clearing on read would race a polling loop: the poll reads
    // STATUS many times, and a clear-on-read would destroy the DONE flag on
    // the first read that observes it, often before the read data is even
    // returned. START-clears-DONE is unambiguous: a new job clears the old
    // completion flag, and DONE then stays set until the next job starts.
    always_ff @(posedge s_axi_aclk) begin
        if (core_rst) begin
            done_sticky <= 1'b0;
        end else begin
            if (core_start)
                done_sticky <= 1'b0;          // new job: clear stale DONE
            else if (core_done)
                done_sticky <= 1'b1;          // latch the 1-cycle done pulse
        end
    end

    // Level interrupt: asserted while a completed result is pending and IRQ
    // is enabled. Cleared when the next START is issued (same as done_sticky).
    assign irq = reg_irq_en & done_sticky;

    // =========================================================================
    // AXI4-Lite READ channel
    // =========================================================================
    logic [C_S_AXI_ADDR_WIDTH-3:0] rd_word;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            rd_word       <= '0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
                rd_word       <= s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2];
            end else begin
                s_axi_arready <= 1'b0;
            end
        end
    end

    // rvalid follows an accepted address.
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;          // OKAY
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // ---- Selected result element -> 64-bit, split into LO/HI ---------------
    // c_flat element reg_residx, sign-extended to 64 bits for software.
    logic signed [RESW-1:0]  sel_res;
    logic        [63:0]      sel_res_ext;
    always_comb begin
        sel_res     = core_c_flat[reg_residx*RESW +: RESW];
        sel_res_ext = {{(64-RESW){sel_res[RESW-1]}}, sel_res};
    end

    // ---- Read data mux ------------------------------------------------------
    always_comb begin
        unique case (rd_word)
            A_CTRL:    s_axi_rdata = {30'd0, reg_irq_en, 1'b0};
            A_STATUS:  s_axi_rdata = {30'd0, done_sticky, core_busy};
            A_KLEN:    s_axi_rdata = {{(32-KW){1'b0}}, reg_klen};
            A_OPIDX:   s_axi_rdata = {{(32-KW){1'b0}}, reg_opidx};
            A_RESIDX:  s_axi_rdata = {{(32-$clog2(N*N)){1'b0}}, reg_residx};
            A_RESLO:   s_axi_rdata = sel_res_ext[31:0];
            A_RESHI:   s_axi_rdata = sel_res_ext[63:32];
            A_INFO:    s_axi_rdata = {RESW[7:0], CNTW[7:0],
                                      KW[7:0],  N[7:0]};
            A_INFO2:   s_axi_rdata = STREAM_LEN[31:0];
            default:   s_axi_rdata = 32'h0;
        endcase
    end

endmodule

`timescale 1ns/1ps
// =============================================================================
// tb_radhard_new_features.sv
//
// Covers the three items added on top of the original TMR/watchdog/temporal-
// redundancy package:
//   1. AXI-Lite config-register TMR (K_LEN/RES_PER_K/IRQEN) -- force one of
//      the three internal copies wrong, confirm the voted readback is still
//      correct and CFG_TMR_MISMATCH (A_FAULT bit4) is set.
//   1b. Confirms the previously-dead aw_tmr_mismatch/ar_tmr_mismatch wiring
//       (AXIL_TMR_MISMATCH, A_FAULT bit5) now actually sets on an AXI-Lite
//       FSM upset.
//   2. CRC32 trailer -- clean tile, confirm tlast lands on beat N*N (not
//      N*N-1), and that the trailer beat matches an independently-written
//      CRC32 reference computed over the received data beats.
//   3. BIST:
//      3a. Small-N harness (params deliberately != the golden vector's) --
//          confirms BIST_PARAMS_MATCH_GOLDEN correctly forces a fail rather
//          than a false pass, and that it completes without hanging.
//      3b. Real N=22 production-default harness, triggered through the
//          actual AXI-Lite CTRL.BIST_START path (not the core directly) --
//          confirms the full BIST FSM + golden compare reports PASS. This
//          one run takes several million cycles (~25s wall-clock).
// =============================================================================
module tb_radhard_new_features;

    int errors = 0;

    // =========================================================================
    // PART A: small-N harness -- config-register TMR, AXI-Lite FSM TMR wiring,
    // CRC32 trailer, BIST negative-path guard.
    // =========================================================================
    localparam int N                  = 3;
    localparam int WIDTH              = 8;
    localparam int LFSR_W             = 8;
    localparam int K_SAR_BITS         = 4;
    localparam int SAR_BIT_LEN        = 4;
    localparam int STREAM_LEN_RESIDUE = 16;
    localparam int KW                 = 8;
    localparam int KBUF_MAX           = 4;
    localparam int C_S_AXI_ADDR_WIDTH = 12;
    localparam int C_S_AXI_DATA_WIDTH = 32;
    localparam int RESW               = WIDTH + 2;
    localparam int K                  = 2;
    localparam time CLK_PERIOD        = 10ns;

    localparam logic [11:0] A_CTRL      = 12'h000;
    localparam logic [11:0] A_STATUS    = 12'h004;
    localparam logic [11:0] A_KLEN      = 12'h008;
    localparam logic [11:0] A_ICOUNT    = 12'h014;
    localparam logic [11:0] A_OCOUNT    = 12'h018;
    localparam logic [11:0] A_RES_PER_K = 12'h020;
    localparam logic [11:0] A_FAULT     = 12'h024;

    logic aclk = 0;
    logic aresetn;

    logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr;
    logic [2:0]   s_axi_awprot;
    logic         s_axi_awvalid, s_axi_awready;
    logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb;
    logic         s_axi_wvalid, s_axi_wready;
    logic [1:0]   s_axi_bresp;
    logic         s_axi_bvalid, s_axi_bready;
    logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr;
    logic [2:0]   s_axi_arprot;
    logic         s_axi_arvalid, s_axi_arready;
    logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata;
    logic [1:0]   s_axi_rresp;
    logic         s_axi_rvalid, s_axi_rready;

    logic [C_S_AXI_DATA_WIDTH-1:0] s_axis_tdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axis_tkeep;
    logic s_axis_tlast, s_axis_tvalid, s_axis_tready;

    logic [C_S_AXI_DATA_WIDTH-1:0] m_axis_tdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0] m_axis_tkeep;
    logic m_axis_tlast, m_axis_tvalid, m_axis_tready;
    logic irq;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    stoch_gemm_axis_hybrid_rad #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .K_SAR_BITS(K_SAR_BITS), .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE),
        .KW(KW), .KBUF_MAX(KBUF_MAX),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH), .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .RAD_VOTE_RUNS(3), .RAD_TMR_FSM(1), .RAD_WATCHDOG(1), .RAD_TMR_AXIL(1),
        .RAD_TMR_CFG(1), .RAD_BIST(1), .RAD_CRC_TRAILER(1)
    ) dut_small (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .irq(irq)
    );

    task automatic axil_write(input [11:0] addr, input [31:0] data);
        @(posedge aclk);
        s_axi_awaddr  <= addr; s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data; s_axi_wstrb   <= 4'hF; s_axi_wvalid <= 1'b1;
        s_axi_bready  <= 1'b1;
        @(posedge aclk);
        while (!s_axi_awready) @(posedge aclk);
        s_axi_awvalid <= 1'b0;
        while (!s_axi_wready) @(posedge aclk);
        s_axi_wvalid  <= 1'b0;
        while (!s_axi_bvalid) @(posedge aclk);
        @(posedge aclk);
        s_axi_bready <= 1'b0;
    endtask

    task automatic axil_read(input [11:0] addr, output [31:0] data);
        @(posedge aclk);
        s_axi_araddr  <= addr; s_axi_arvalid <= 1'b1;
        s_axi_rready  <= 1'b1;
        @(posedge aclk);
        while (!s_axi_arready) @(posedge aclk);
        s_axi_arvalid <= 1'b0;
        while (!s_axi_rvalid) @(posedge aclk);
        data = s_axi_rdata;
        @(posedge aclk);
        s_axi_rready <= 1'b0;
    endtask

    // ---- Reference CRC32 (IEEE 802.3 / zlib), written independently of the
    //      DUT's implementation, self-checked against the standard
    //      "123456789" -> 0xCBF43926 test vector before being trusted. ----
    function automatic logic [31:0] ref_crc32_byte(logic [31:0] crc, logic [7:0] data);
        logic [31:0] c;
        c = crc ^ {24'd0, data};
        for (int i = 0; i < 8; i++)
            c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        return c;
    endfunction

    initial begin
        logic [31:0] c;
        logic [7:0] check_str [0:8];
        check_str[0] = 8'h31; check_str[1] = 8'h32; check_str[2] = 8'h33;
        check_str[3] = 8'h34; check_str[4] = 8'h35; check_str[5] = 8'h36;
        check_str[6] = 8'h37; check_str[7] = 8'h38; check_str[8] = 8'h39; // "123456789"
        c = 32'hFFFFFFFF;
        for (int i = 0; i < 9; i++) c = ref_crc32_byte(c, check_str[i]);
        c = c ^ 32'hFFFFFFFF;
        if (c !== 32'hCBF43926) begin
            $display("FAIL: reference CRC32 self-check mismatch, got 0x%08h expect 0xCBF43926", c);
            errors++;
        end else begin
            $display("PASS: reference CRC32 implementation self-check (\"123456789\" -> 0x%08h)", c);
        end
    end

    initial begin
        aresetn = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        s_axis_tvalid = 0; s_axis_tlast = 0;
        m_axis_tready = 0;
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge aclk);

        // =====================================================================
        // TEST 1: AXI-Lite config-register TMR
        // =====================================================================
        $display("\n===== TEST 1: config register (K_LEN/RES_PER_K) TMR =====");
        axil_write(A_KLEN, K[7:0]);
        axil_write(A_RES_PER_K, 32'd12);

        begin
            logic [31:0] klen_rb, fault_reg;
            // Corrupt one of the three internal copies persistently (like an
            // SEU landing in that copy's flop and staying there until the
            // next write refreshes it).
            force dut_small.reg_klen_b = ~dut_small.reg_klen_b;
            repeat (3) @(posedge aclk);

            axil_read(A_KLEN, klen_rb);
            if (klen_rb[7:0] !== K[7:0]) begin
                $display("  FAIL: voted K_LEN readback = %0d, expected %0d -- TMR did not mask the corrupted copy",
                          klen_rb[7:0], K);
                errors++;
            end else begin
                $display("  PASS: voted K_LEN readback still correct (%0d) with one copy corrupted", klen_rb[7:0]);
            end

            axil_read(A_FAULT, fault_reg);
            if (fault_reg[4] !== 1'b1) begin // CFG_TMR_MISMATCH
                $display("  FAIL: expected CFG_TMR_MISMATCH (A_FAULT bit4) set, got 0x%08h", fault_reg);
                errors++;
            end else begin
                $display("  PASS: CFG_TMR_MISMATCH correctly flagged");
            end

            release dut_small.reg_klen_b;
            axil_write(A_FAULT, 32'h1); // clear all sticky fault bits
            repeat (2) @(posedge aclk);
        end

        // =====================================================================
        // TEST 1b: AXI-Lite read FSM TMR wiring (previously dead code)
        // =====================================================================
        $display("\n===== TEST 1b: AXI-Lite ar_state TMR mismatch wiring =====");
        begin
            logic [31:0] rb, fault_reg;
            // Force one copy of ar_state to an illegal/wrong encoding for the
            // duration of one read, then release.
            force dut_small.ar_state_b = 2'b11;
            axil_read(A_KLEN, rb);
            release dut_small.ar_state_b;

            if (rb[7:0] !== K[7:0]) begin
                $display("  FAIL: K_LEN readback corrupted during ar_state upset (%0d, expected %0d)", rb[7:0], K);
                errors++;
            end else begin
                $display("  PASS: read FSM TMR masked the corrupted ar_state copy, correct data returned");
            end

            axil_read(A_FAULT, fault_reg);
            if (fault_reg[5] !== 1'b1) begin // AXIL_TMR_MISMATCH
                $display("  FAIL: expected AXIL_TMR_MISMATCH (A_FAULT bit5) set, got 0x%08h", fault_reg);
                errors++;
            end else begin
                $display("  PASS: AXIL_TMR_MISMATCH correctly flagged (dead wiring now connected)");
            end
            axil_write(A_FAULT, 32'h1);
            repeat (2) @(posedge aclk);
        end

        // =====================================================================
        // TEST 2: CRC32 trailer on a clean tile
        // =====================================================================
        $display("\n===== TEST 2: CRC32 trailer =====");
        begin
            int n_beats; int recvd; int wd;
            logic [31:0] data_beats [0:N*N-1];
            logic [31:0] crc_received;
            logic [7:0]  byte_stream [0:(N*N*4)-1];
            logic [31:0] crc_ref;
            bit tlast_position_ok;

            n_beats = K * 2 * N;

            for (int b = 0; b < n_beats; b++) begin
                @(posedge aclk);
                s_axis_tdata  <= {24'h0, 8'h41 + b[7:0]};
                s_axis_tkeep  <= 4'hF;
                s_axis_tlast  <= (b == n_beats - 1);
                s_axis_tvalid <= 1'b1;
                do @(posedge aclk); while (!s_axis_tready);
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
            end

            axil_write(A_CTRL, 32'h0000_0001);

            m_axis_tready <= 1'b1;
            recvd = 0;
            wd = 0;
            tlast_position_ok = 1'b1;
            while (recvd < N*N+1 && wd < 200000) begin
                @(posedge aclk);
                if (m_axis_tvalid && m_axis_tready) begin
                    if (recvd < N*N) begin
                        data_beats[recvd] = m_axis_tdata;
                        if (m_axis_tlast) tlast_position_ok = 1'b0; // tlast must NOT be on a data beat
                    end else begin
                        crc_received = m_axis_tdata;
                        if (!m_axis_tlast) tlast_position_ok = 1'b0; // tlast MUST be on the trailer beat
                    end
                    recvd++;
                end
                wd++;
            end
            m_axis_tready <= 1'b0;

            if (recvd !== N*N+1) begin
                $display("  FAIL: received %0d beats, expected %0d (N*N data + 1 CRC trailer)", recvd, N*N+1);
                errors++;
            end else begin
                $display("  PASS: received exactly N*N+1 = %0d beats", N*N+1);
            end

            if (!tlast_position_ok) begin
                $display("  FAIL: tlast did not land exactly on the trailer beat");
                errors++;
            end else begin
                $display("  PASS: tlast correctly landed on the trailer beat only");
            end

            for (int i = 0; i < N*N; i++) begin
                byte_stream[i*4+0] = data_beats[i][7:0];
                byte_stream[i*4+1] = data_beats[i][15:8];
                byte_stream[i*4+2] = data_beats[i][23:16];
                byte_stream[i*4+3] = data_beats[i][31:24];
            end
            crc_ref = 32'hFFFFFFFF;
            for (int i = 0; i < N*N*4; i++) crc_ref = ref_crc32_byte(crc_ref, byte_stream[i]);
            crc_ref = crc_ref ^ 32'hFFFFFFFF;

            if (crc_received !== crc_ref) begin
                $display("  FAIL: CRC trailer = 0x%08h, independently-computed reference = 0x%08h",
                          crc_received, crc_ref);
                errors++;
            end else begin
                $display("  PASS: CRC trailer (0x%08h) matches independently-computed reference", crc_received);
            end
        end

        // =====================================================================
        // TEST 3a: BIST negative-path guard (small N != golden vector's N)
        // =====================================================================
        $display("\n===== TEST 3a: BIST guard at mismatched parameters (expect FAIL, not hang) =====");
        begin
            logic [31:0] status_reg, fault_reg;
            int wd;
            axil_write(A_CTRL, 32'h0000_0004); // BIST_START
            wd = 0;
            do begin
                @(posedge aclk);
                axil_read(A_STATUS, status_reg);
                wd++;
            end while (status_reg[3] && wd < 5000); // bit3 = bist_busy
            if (wd >= 5000) begin
                $display("  FAIL: BIST never completed (possible hang) at mismatched parameters");
                errors++;
            end else if (!status_reg[4]) begin // bit4 = bist_done_sticky
                $display("  FAIL: bist_done_sticky not set after BIST completed");
                errors++;
            end else if (status_reg[5]) begin // bit5 = bist_pass_sticky -- must NOT pass at wrong params
                $display("  FAIL: BIST reported PASS at a parameter set that does not match the golden vector -- false pass risk");
                errors++;
            end else begin
                $display("  PASS: BIST correctly completed and reported FAIL (params don't match golden vector, guard working)");
            end
            axil_read(A_FAULT, fault_reg);
            if (!fault_reg[6]) begin // BIST_FAIL sticky
                $display("  FAIL: expected BIST_FAIL (A_FAULT bit6) set");
                errors++;
            end else begin
                $display("  PASS: BIST_FAIL sticky correctly set");
            end
            axil_write(A_FAULT, 32'h1);
        end

        $display("\n============================================================");
        if (errors == 0) $display("PART A (small-N harness) PASSED");
        else $display("PART A: %0d FAILURE(S)", errors);
        $display("============================================================");

        part_a_done = 1'b1;
    end

    bit part_a_done = 1'b0;

    // =========================================================================
    // PART B: real N=22 production-default harness -- BIST positive path,
    // triggered through the actual AXI-Lite CTRL.BIST_START path. This is the
    // exact configuration the golden vector in stoch_gemm_axis_hybrid_rad.sv
    // was generated against (see gen_bist_golden.sv). Runs after Part A
    // finishes so the two don't contend for simulator time/output ordering.
    // =========================================================================
    localparam int N2  = 22;
    localparam int W2  = 16;
    localparam int LW2 = 16;
    localparam int KSB2 = 8;
    localparam int SBL2 = 32;
    localparam int SLR2 = 65536;
    localparam int KW2  = 16;
    localparam int KBM2 = 16;

    logic aclk2 = 0;
    logic aresetn2;
    logic [11:0] s_axi_awaddr2;
    logic [2:0]  s_axi_awprot2;
    logic        s_axi_awvalid2, s_axi_awready2;
    logic [31:0] s_axi_wdata2;
    logic [3:0]  s_axi_wstrb2;
    logic        s_axi_wvalid2, s_axi_wready2;
    logic [1:0]  s_axi_bresp2;
    logic        s_axi_bvalid2, s_axi_bready2;
    logic [11:0] s_axi_araddr2;
    logic [2:0]  s_axi_arprot2;
    logic        s_axi_arvalid2, s_axi_arready2;
    logic [31:0] s_axi_rdata2;
    logic [1:0]  s_axi_rresp2;
    logic        s_axi_rvalid2, s_axi_rready2;
    logic [31:0] s_axis_tdata2;
    logic [3:0]  s_axis_tkeep2;
    logic s_axis_tlast2, s_axis_tvalid2, s_axis_tready2;
    logic [31:0] m_axis_tdata2;
    logic [3:0]  m_axis_tkeep2;
    logic m_axis_tlast2, m_axis_tvalid2, m_axis_tready2;
    logic irq2;

    always #(CLK_PERIOD/2) aclk2 = ~aclk2;

    stoch_gemm_axis_hybrid_rad #(
        .N(N2), .WIDTH(W2), .LFSR_W(LW2),
        .K_SAR_BITS(KSB2), .SAR_BIT_LEN(SBL2),
        .STREAM_LEN_RESIDUE(SLR2),
        .KW(KW2), .KBUF_MAX(KBM2),
        .RAD_VOTE_RUNS(1), // single run -- BIST itself needs no temporal-redundancy voting
        .RAD_TMR_FSM(1), .RAD_WATCHDOG(1), .RAD_TMR_AXIL(1),
        .RAD_TMR_CFG(1), .RAD_BIST(1), .RAD_CRC_TRAILER(1)
    ) dut_n22 (
        .aclk(aclk2), .aresetn(aresetn2),
        .s_axi_awaddr(s_axi_awaddr2), .s_axi_awprot(s_axi_awprot2),
        .s_axi_awvalid(s_axi_awvalid2), .s_axi_awready(s_axi_awready2),
        .s_axi_wdata(s_axi_wdata2), .s_axi_wstrb(s_axi_wstrb2),
        .s_axi_wvalid(s_axi_wvalid2), .s_axi_wready(s_axi_wready2),
        .s_axi_bresp(s_axi_bresp2), .s_axi_bvalid(s_axi_bvalid2), .s_axi_bready(s_axi_bready2),
        .s_axi_araddr(s_axi_araddr2), .s_axi_arprot(s_axi_arprot2),
        .s_axi_arvalid(s_axi_arvalid2), .s_axi_arready(s_axi_arready2),
        .s_axi_rdata(s_axi_rdata2), .s_axi_rresp(s_axi_rresp2),
        .s_axi_rvalid(s_axi_rvalid2), .s_axi_rready(s_axi_rready2),
        .s_axis_tdata(s_axis_tdata2), .s_axis_tkeep(s_axis_tkeep2),
        .s_axis_tlast(s_axis_tlast2), .s_axis_tvalid(s_axis_tvalid2), .s_axis_tready(s_axis_tready2),
        .m_axis_tdata(m_axis_tdata2), .m_axis_tkeep(m_axis_tkeep2),
        .m_axis_tlast(m_axis_tlast2), .m_axis_tvalid(m_axis_tvalid2), .m_axis_tready(m_axis_tready2),
        .irq(irq2)
    );

    task automatic axil_write2(input [11:0] addr, input [31:0] data);
        @(posedge aclk2);
        s_axi_awaddr2  <= addr; s_axi_awvalid2 <= 1'b1;
        s_axi_wdata2   <= data; s_axi_wstrb2   <= 4'hF; s_axi_wvalid2 <= 1'b1;
        s_axi_bready2  <= 1'b1;
        @(posedge aclk2);
        while (!s_axi_awready2) @(posedge aclk2);
        s_axi_awvalid2 <= 1'b0;
        while (!s_axi_wready2) @(posedge aclk2);
        s_axi_wvalid2  <= 1'b0;
        while (!s_axi_bvalid2) @(posedge aclk2);
        @(posedge aclk2);
        s_axi_bready2 <= 1'b0;
    endtask

    task automatic axil_read2(input [11:0] addr, output [31:0] data);
        @(posedge aclk2);
        s_axi_araddr2  <= addr; s_axi_arvalid2 <= 1'b1;
        s_axi_rready2  <= 1'b1;
        @(posedge aclk2);
        while (!s_axi_arready2) @(posedge aclk2);
        s_axi_arvalid2 <= 1'b0;
        while (!s_axi_rvalid2) @(posedge aclk2);
        data = s_axi_rdata2;
        @(posedge aclk2);
        s_axi_rready2 <= 1'b0;
    endtask

    initial begin
        logic [31:0] status_reg, fault_reg;
        int wd;

        aresetn2 = 0;
        s_axi_awvalid2 = 0; s_axi_wvalid2 = 0; s_axi_bready2 = 0;
        s_axi_arvalid2 = 0; s_axi_rready2 = 0;
        s_axis_tvalid2 = 0; s_axis_tlast2 = 0;
        m_axis_tready2 = 0;
        repeat (5) @(posedge aclk2);
        aresetn2 = 1;
        repeat (3) @(posedge aclk2);

        wait (part_a_done); // keep log output in order

        $display("\n===== TEST 3b: BIST positive path at real N=22 production defaults =====");
        $display("  (this one run is several million cycles -- expect ~20-30s wall-clock)");

        axil_write2(A_CTRL, 32'h0000_0004); // BIST_START
        axil_read2(A_STATUS, status_reg);
        wd = 0;
        while (status_reg[3] && wd < 40) begin // bit3 = bist_busy; poll every 500k cycles, ~20M cycle ceiling
            repeat (500_000) @(posedge aclk2);
            axil_read2(A_STATUS, status_reg);
            wd++;
            $display("  [progress] poll %0d, sim_time=%0t, bist_busy=%0b", wd, $time, status_reg[3]);
            $fflush();
        end

        if (wd >= 40) begin
            $display("  FAIL: BIST never completed at N=22 (timeout)");
            errors++;
        end else begin
            axil_read2(A_STATUS, status_reg);
            if (!status_reg[4]) begin
                $display("  FAIL: bist_done_sticky not set");
                errors++;
            end else if (!status_reg[5]) begin
                $display("  FAIL: BIST reported FAIL at the real N=22 production default parameter set -- golden vector mismatch");
                errors++;
            end else begin
                $display("  PASS: BIST reported PASS at the real N=22 production default parameter set");
            end
            axil_read2(A_FAULT, fault_reg);
            if (fault_reg[6]) begin
                $display("  FAIL: BIST_FAIL sticky unexpectedly set despite PASS status");
                errors++;
            end else begin
                $display("  PASS: no BIST_FAIL sticky on the passing run");
            end
        end

        $display("\n============================================================");
        if (errors == 0) $display("ALL NEW-FEATURE TESTS PASSED");
        else $display("%0d TOTAL FAILURE(S)", errors);
        $display("============================================================");
        $finish;
    end

endmodule

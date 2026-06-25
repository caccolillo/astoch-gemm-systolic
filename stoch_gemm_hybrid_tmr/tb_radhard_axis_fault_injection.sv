`timescale 1ns/1ps
// =============================================================================
// tb_radhard_axis_fault_injection.sv
//
// Drives stoch_gemm_axis_hybrid_rad through its real AXI-Lite/AXI-Stream
// interface (same PHASE1/PHASE2/PHASE3 pattern as
// tb_stoch_gemm_axis_hybrid_n22.sv) with small parameters for fast sim.
//
//   RUN A (clean):    stream operands, start, collect output. This is the
//                      reference answer.
//   RUN B (injected):  identical operands, but this time the FIRST internal
//                      vote-sequencer run (run 1 of RAD_VOTE_RUNS=3) has one
//                      PE's c_flat register corrupted for exactly the cycle
//                      it gets captured into the vote sequencer's buf_a --
//                      i.e. "this PE's accumulator silently produced a wrong
//                      answer on run 1, as a real SEU in cnt_xnor/cnt_fb/
//                      sar_reg would". Runs 2 and 3 are untouched. Expect:
//                      the final streamed-out result EXACTLY MATCHES Run A's
//                      reference answer (the corruption was outvoted), and
//                      the new A_FAULT register's VOTE_MISMATCH bit is set.
// =============================================================================
module tb_radhard_axis_fault_injection;

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

    // Module-level scratch for fault injection.
    // Cannot use automatic/local variables in force statements.
    // N*N*RESW = 3*3*10 = 90 bits -- same width as buf_a/core_c_flat.
    logic [N*N*RESW-1:0] buf_a_scratch;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    stoch_gemm_axis_hybrid_rad #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .K_SAR_BITS(K_SAR_BITS), .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE),
        .KW(KW), .KBUF_MAX(KBUF_MAX),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH), .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .RAD_VOTE_RUNS(3), .RAD_TMR_FSM(1), .RAD_WATCHDOG(1), .RAD_TMR_AXIL(1)
    ) dut (
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

    int errors = 0;

    // ---- AXI-Lite helper tasks ---------------------------------------------
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

    logic [RESW-1:0] rx_a [0:N*N-1];
    logic [RESW-1:0] rx_b [0:N*N-1];

    task automatic run_tile(input bit inject_fault, output bit completed);
        automatic int n_beats = K * 2 * N;
        automatic int recvd;
        automatic logic [RESW-1:0] tmp;
        automatic int wd;
        automatic bit injected;

        // ---- PHASE 1: stream operands (fixed pattern, same every run) -----
        for (int b = 0; b < n_beats; b++) begin
            @(posedge aclk);
            s_axis_tdata  <= {24'h0, 8'h85 + b[7:0]};
            s_axis_tkeep  <= 4'hF;
            s_axis_tlast  <= (b == n_beats - 1);
            s_axis_tvalid <= 1'b1;
            do @(posedge aclk); while (!s_axis_tready);
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
        end

        // ---- PHASE 2: start ------------------------------------------------
        axil_write(A_CTRL, 32'h0000_0001);

        // ---- Optional fault injection on run 1 only ------------------------
        // Corrupts PE(0,0)'s c_flat register for exactly the cycle it gets
        // latched into the vote sequencer's buf_a, simulating "this PE's
        // accumulator state was already wrong by the time run 1 finished" --
        // the same observable effect a real SEU in cnt_xnor/cnt_fb/sar_reg
        // would have produced, without needing to time an injection against
        // the PE's internal multi-cycle SAR/residue arithmetic.
        injected = 1'b0;
        if (inject_fault) begin
            // Inject fault into dut.buf_a rather than dut.core_c_flat or
            // the PE internals through generate-block hierarchy.
            //
            // Approach: wait for run 1 to complete (core_done), let buf_a
            // register the correct result for one cycle, then capture the
            // correct value and force buf_a to its bitwise inverse. This is
            // unambiguously wrong regardless of what the computation produced.
            //
            // The force holds through run 2's core_done so VS_WAIT2 sees
            // buf_a=wrong vs buf_b=correct and triggers the mismatch flag.
            // buf_a is a module-level logic variable with no continuous driver
            // (no generate-block path), so force/release work in XSim.
            wd = 0;
            while (!dut.core_done && wd < 5000) begin @(posedge aclk); wd++; end
            // buf_a <= core_c_flat was just registered at this clock edge.
            @(posedge aclk);  // advance one cycle so buf_a holds run-1 result
            buf_a_scratch = dut.buf_a;                // capture correct run-1 result
            force dut.buf_a = ~buf_a_scratch;         // force to definite wrong value
            injected = 1'b1;
            $display("  [%0t] forced buf_a to inverse of correct run-1 result (guaranteed wrong)",
                      $time);
            // Skip past any residual core_done pulse, then wait for run 2
            @(posedge aclk);
            wd = 0;
            while (!dut.core_done && wd < 5000) begin @(posedge aclk); wd++; end
            // VS_WAIT2 has now compared wrong buf_a vs correct buf_b →
            // disagreement detected → vote_mismatch_event fires → fault_vote_sticky set.
            @(posedge aclk);  // let the VS_WAIT2 always_ff commit
            release dut.buf_a;
        end

        // ---- PHASE 3: collect output ----------------------------------------
        m_axis_tready <= 1'b1;
        recvd = 0;
        wd = 0;
        while (recvd < N*N && wd < 200000) begin
            @(posedge aclk);
            if (m_axis_tvalid && m_axis_tready) begin
                tmp = m_axis_tdata[RESW-1:0];
                if (inject_fault) rx_b[recvd] = tmp; else rx_a[recvd] = tmp;
                recvd++;
            end
            wd++;
        end
        m_axis_tready <= 1'b0;
        completed = (recvd == N*N);
        if (!completed) begin
            $display("  FAIL: only received %0d/%0d output beats", recvd, N*N);
            errors++;
        end
    endtask

    initial begin
        aresetn = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        s_axis_tvalid = 0; s_axis_tlast = 0;
        m_axis_tready = 0;
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge aclk);

        axil_write(A_KLEN, K[7:0]);
        axil_write(A_RES_PER_K, 32'd12);

        begin
            bit ok_a, ok_b;
            logic [31:0] fault_reg, status_reg;
            int mismatches;

            $display("\n===== RUN A: clean (reference) =====");
            run_tile(1'b0, ok_a);

            axil_read(A_FAULT, fault_reg);
            $display("  A_FAULT after clean run = 0x%08h (expect all-clear)", fault_reg);
            if (fault_reg[0] !== 1'b0) begin
                $display("  FAIL: fault bits set after a clean run");
                errors++;
            end

            $display("\n===== RUN B: core_c_flat corrupted on run 1 only (all PEs, corrected by majority vote) =====");
            run_tile(1'b1, ok_b);

            axil_read(A_FAULT, fault_reg);
            $display("  A_FAULT after injected run = 0x%08h", fault_reg);
            if (fault_reg[3] !== 1'b1) begin // VOTE_MISMATCH bit
                $display("  FAIL: expected VOTE_MISMATCH bit set after injected run");
                errors++;
            end else begin
                $display("  PASS: VOTE_MISMATCH bit correctly set");
            end

            mismatches = 0;
            for (int i = 0; i < N*N; i++) begin
                if (rx_a[i] !== rx_b[i]) mismatches++;
            end
            if (mismatches == 0) begin
                $display("  PASS: all %0d output values identical between clean and injected runs --", N*N);
                $display("        the re-run vote fully recovered the correct answer.");
            end else begin
                $display("  FAIL: %0d/%0d output values differ -- the injected fault leaked through",
                          mismatches, N*N);
                errors++;
            end

            // Clear and confirm A_FAULT clears
            axil_write(A_FAULT, 32'h1);
            axil_read(A_FAULT, fault_reg);
            if (fault_reg[0] !== 1'b0) begin
                $display("  FAIL: A_FAULT did not clear after write-1-to-clear");
                errors++;
            end else begin
                $display("  PASS: A_FAULT cleared after write-1-to-clear");
            end
        end

        $display("\n============================================================");
        if (errors == 0) $display("ALL AXIS-WRAPPER FAULT-INJECTION TESTS PASSED");
        else              $display("%0d TEST(S) FAILED", errors);
        $display("============================================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 4_000_000);
        $display("FATAL: testbench timeout");
        $finish;
    end

endmodule

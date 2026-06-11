// =============================================================================
// tb_stoch_gemm_axis_hybrid_n22.sv
//
// Wrapper-level testbench: drives the stoch_gemm_axis_hybrid IP through its
// AXI-Lite control interface and AXI-Stream operand/result interfaces at N=22.
// This is the same exercise the userspace gemm-test program performs on real
// hardware. If simulation here matches simulation of the inner core (~53 dB
// PSNR), the wrapper's RTL is fine and the bug is synthesis-only. If sim
// here ALSO produces bipolar-zero noise, the wrapper itself has an N=22 bug
// that's source-fixable.
//
// What it does
//   1. Brings the wrapper out of reset.
//   2. Reads INFO/INFO2/INFO3 via AXI-Lite to confirm hw config = N=22.
//   3. Writes K_LEN=9 and RES_PER_K=7282 via AXI-Lite.
//   4. Pulses CTRL.START via AXI-Lite.
//   5. Streams 396 input beats (K=9 terms x 2N=44 beats per term).
//   6. Receives 484 output beats via the result AXI-Stream.
//   7. Polls STATUS until DONE.
//   8. Compares the first IMG_DIM=8 results against software reference.
// =============================================================================
`timescale 1ns/1ps

module tb_stoch_gemm_axis_hybrid_n22;

    // ---- Parameters (match the wrapper VHDL defaults at N=22) -----------
    localparam int N                  = 22;
    localparam int IMG_DIM            = 8;
    localparam int WIDTH              = 16;
    localparam int LFSR_W             = 16;
    localparam int K                  = 9;
    localparam int K_SAR_BITS         = 8;
    localparam int SAR_BIT_LEN        = 32;
    localparam int STREAM_LEN_RESIDUE = 65536;
    localparam int KW                 = 16;
    localparam int KBUF_MAX           = 64;
    localparam int C_S_AXI_ADDR_WIDTH = 12;
    localparam int C_S_AXI_DATA_WIDTH = 32;
    localparam int RESW               = WIDTH + 2;
    localparam time CLK_PERIOD        = 10ns;

    // Register offsets (match the wrapper)
    localparam logic [11:0] A_CTRL      = 12'h000;
    localparam logic [11:0] A_STATUS    = 12'h004;
    localparam logic [11:0] A_KLEN      = 12'h008;
    localparam logic [11:0] A_INFO      = 12'h00C;
    localparam logic [11:0] A_INFO2     = 12'h010;
    localparam logic [11:0] A_ICOUNT    = 12'h014;
    localparam logic [11:0] A_OCOUNT    = 12'h018;
    localparam logic [11:0] A_INFO3     = 12'h01C;
    localparam logic [11:0] A_RES_PER_K = 12'h020;

    // ---- DUT signals ----------------------------------------------------
    logic                              aclk;
    logic                              aresetn;

    // AXI-Lite
    logic [C_S_AXI_ADDR_WIDTH-1:0]      s_axi_awaddr;
    logic [2:0]                         s_axi_awprot;
    logic                               s_axi_awvalid;
    logic                               s_axi_awready;
    logic [C_S_AXI_DATA_WIDTH-1:0]      s_axi_wdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0]  s_axi_wstrb;
    logic                               s_axi_wvalid;
    logic                               s_axi_wready;
    logic [1:0]                         s_axi_bresp;
    logic                               s_axi_bvalid;
    logic                               s_axi_bready;
    logic [C_S_AXI_ADDR_WIDTH-1:0]      s_axi_araddr;
    logic [2:0]                         s_axi_arprot;
    logic                               s_axi_arvalid;
    logic                               s_axi_arready;
    logic [C_S_AXI_DATA_WIDTH-1:0]      s_axi_rdata;
    logic [1:0]                         s_axi_rresp;
    logic                               s_axi_rvalid;
    logic                               s_axi_rready;

    // AXI-Stream slave (operand input)
    logic [C_S_AXI_DATA_WIDTH-1:0]      s_axis_tdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0]  s_axis_tkeep;
    logic                               s_axis_tlast;
    logic                               s_axis_tvalid;
    logic                               s_axis_tready;

    // AXI-Stream master (result output)
    logic [C_S_AXI_DATA_WIDTH-1:0]      m_axis_tdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0]  m_axis_tkeep;
    logic                               m_axis_tlast;
    logic                               m_axis_tvalid;
    logic                               m_axis_tready;

    // Interrupt
    logic                               irq;

    // ---- Clock ----------------------------------------------------------
    initial begin aclk = 0; forever #(CLK_PERIOD/2) aclk = ~aclk; end

    // ---- DUT instantiation ----------------------------------------------
    stoch_gemm_axis_hybrid #(
        .N                  (N),
        .WIDTH              (WIDTH),
        .LFSR_W             (LFSR_W),
        .K_SAR_BITS         (K_SAR_BITS),
        .SAR_BIT_LEN        (SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE (STREAM_LEN_RESIDUE),
        .KW                 (KW),
        .KBUF_MAX           (KBUF_MAX),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH),
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH)
    ) dut (
        .aclk           (aclk),
        .aresetn        (aresetn),

        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awprot   (s_axi_awprot),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arprot   (s_axi_arprot),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),

        .irq            (irq)
    );

    // ---- AXI-Lite write task --------------------------------------------
    task automatic axil_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge aclk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;
            do @(posedge aclk); while (!(s_axi_awready && s_axi_awvalid));
            s_axi_awvalid <= 1'b0;
            do @(posedge aclk); while (!(s_axi_wready && s_axi_wvalid));
            s_axi_wvalid  <= 1'b0;
            do @(posedge aclk); while (!s_axi_bvalid);
            s_axi_bready  <= 1'b0;
            $display("  AXI-Lite WR  [0x%03h] = 0x%08h", addr, data);
        end
    endtask

    // ---- AXI-Lite read task ---------------------------------------------
    task automatic axil_read(input [11:0] addr, output [31:0] data);
        begin
            @(posedge aclk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;
            do @(posedge aclk); while (!(s_axi_arready && s_axi_arvalid));
            s_axi_arvalid <= 1'b0;
            do @(posedge aclk); while (!s_axi_rvalid);
            data = s_axi_rdata;
            s_axi_rready <= 1'b0;
            $display("  AXI-Lite RD  [0x%03h] = 0x%08h", addr, data);
        end
    endtask

    // ---- Encoding -------------------------------------------------------
    function automatic logic [WIDTH-1:0] enc(input real x);
        int qi;
        qi = $rtoi((x + 1.0) * 0.5 * real'(1 << WIDTH));
        if (qi < 0) qi = 0;
        else if (qi > ((1 << WIDTH) - 1)) qi = (1 << WIDTH) - 1;
        return WIDTH'(qi);
    endfunction

    // ---- Stimulus storage -----------------------------------------------
    int img [8][8];
    real kern [K];
    real kmax;
    real expected [N];

    logic [WIDTH-1:0] kenc [K];
    logic [WIDTH-1:0] tx_data [K*2*N];   // 396 beats for N=22 K=9
    logic [RESW-1:0]  rx_data [N*N];     // 484 beats

    // ---- Main test ------------------------------------------------------
    initial begin
        int dr [9] = '{-1,-1,-1, 0, 0, 0, 1, 1, 1};
        int dc [9] = '{-1, 0, 1,-1, 0, 1,-1, 0, 1};
        logic [31:0] rd;

        // Init signals
        aresetn       = 1'b0;
        s_axi_awaddr  = '0;  s_axi_awprot = '0;  s_axi_awvalid = 1'b0;
        s_axi_wdata   = '0;  s_axi_wstrb  = '0;  s_axi_wvalid  = 1'b0;
        s_axi_bready  = 1'b0;
        s_axi_araddr  = '0;  s_axi_arprot = '0;  s_axi_arvalid = 1'b0;
        s_axi_rready  = 1'b0;
        s_axis_tdata  = '0;  s_axis_tkeep = '0;  s_axis_tlast  = 1'b0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b0;

        // Build image and kernel
        for (int r = 0; r < 8; r++)
            for (int c = 0; c < 8; c++)
                img[r][c] = c * 32;
        kmax    = 4.0;
        kern[0] = 1.0/kmax;  kern[1] = 2.0/kmax;  kern[2] = 1.0/kmax;
        kern[3] = 2.0/kmax;  kern[4] = 4.0/kmax;  kern[5] = 2.0/kmax;
        kern[6] = 1.0/kmax;  kern[7] = 2.0/kmax;  kern[8] = 1.0/kmax;

        for (int k = 0; k < K; k++) kenc[k] = enc(kern[k]);

        // Build TX (kernel a-half then patch b-half, per term)
        for (int k = 0; k < K; k++) begin
            for (int i = 0; i < N; i++) begin
                int rr, cc, pix;
                rr = 0 + dr[k];
                cc = i + dc[k];
                if (rr < 0 || rr >= IMG_DIM || cc < 0 || cc >= IMG_DIM)
                    pix = 0;
                else
                    pix = img[rr][cc];
                tx_data[k*2*N + i]         = kenc[k];                  // a-half
                tx_data[k*2*N + N + i]     = enc(real'(pix) / 255.0);  // b-half
            end
        end

        // Build SW reference (only meaningful for i < IMG_DIM)
        for (int i = 0; i < N; i++) begin
            real acc;
            acc = 0.0;
            if (i < IMG_DIM) begin
                for (int k = 0; k < K; k++) begin
                    int rr, cc, pix;
                    rr = 0 + dr[k];
                    cc = i + dc[k];
                    if (rr < 0 || rr >= IMG_DIM || cc < 0 || cc >= IMG_DIM)
                        pix = 0;
                    else
                        pix = img[rr][cc];
                    acc = acc + kern[k] * (real'(pix) / 255.0);
                end
            end
            expected[i] = acc;
        end

        // Reset
        repeat (10) @(posedge aclk);
        aresetn = 1'b1;
        repeat (5) @(posedge aclk);

        $display("============================================================");
        $display(" Wrapper-level testbench, N=%0d K=%0d", N, K);
        $display("============================================================");

        // Sanity: read INFO/INFO2/INFO3 to confirm DUT is alive
        axil_read(A_INFO,  rd);
        $display("  INFO  decoded: N=%0d KW=%0d CNTW=%0d RESW=%0d",
                 rd[7:0], rd[15:8], rd[23:16], rd[31:24]);
        if (rd[7:0] != N) $display("  >>> WARNING: INFO.N != %0d", N);

        axil_read(A_INFO2, rd);
        $display("  INFO2 decoded: hybrid=%0d SLR=%0d",
                 rd[31], rd[23:0]);

        axil_read(A_INFO3, rd);
        $display("  INFO3 decoded: K_SAR_BITS=%0d SAR_BIT_LEN=%0d",
                 rd[7:0], rd[15:8]);

        // Program control regs
        axil_write(A_KLEN,      K);
        axil_write(A_RES_PER_K, (STREAM_LEN_RESIDUE + K - 1) / K);  // = 7282

        // Read RES_PER_K back to confirm the 5-bit address bug
        axil_read(A_RES_PER_K, rd);
        $display("  RES_PER_K readback: 0x%08h (expected 7282=0x1C72)", rd);
        if (rd != 32'd7282)
            $display("  >>> CONFIRMED: 5-bit address decoder bug, RES_PER_K not writable via 0x20");

        // Drain any pending bvalid
        @(posedge aclk);

        // Now start streaming the operands. The wrapper will assert
        // s_axis_tready and consume beats as it can. We DO NOT pulse
        // START until at least some operands are loaded? Actually the
        // wrapper accepts operands BEFORE start. We follow real flow:
        // 1) program K_LEN and RES_PER_K
        // 2) stream operands
        // 3) pulse START
        // 4) read back outputs

        // Open the output stream sink
        m_axis_tready <= 1'b1;

        // Fork the input stream driver
        fork
            // ---- TX driver -----
            begin
                automatic int n_beats = K * 2 * N;
                for (int b = 0; b < n_beats; b++) begin
                    @(posedge aclk);
                    s_axis_tdata  <= {16'h0, tx_data[b]};   // low 16 bits = operand
                    s_axis_tkeep  <= 4'hF;
                    s_axis_tlast  <= (b == n_beats - 1);
                    s_axis_tvalid <= 1'b1;
                    do @(posedge aclk); while (!s_axis_tready);
                end
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
                $display("  TX driver done -- %0d beats sent", n_beats);
            end

            // ---- RX collector -----
            begin
                automatic int recvd = 0;
                automatic int expected_n = N * N;
                logic [RESW-1:0] tmp;
                while (recvd < expected_n) begin
                    @(posedge aclk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        tmp = m_axis_tdata[RESW-1:0];
                        rx_data[recvd] = tmp;
                        recvd++;
                    end
                end
                $display("  RX collector done -- %0d beats received", recvd);
            end

            // ---- Trigger START after a brief delay ----
            begin
                repeat (50) @(posedge aclk);
                axil_write(A_CTRL, 32'h0000_0001);   // START bit
            end
        join

        // Wait for DONE in STATUS
        begin
            int tries;
            tries = 0;
            do begin
                @(posedge aclk);
                axil_read(A_STATUS, rd);
                tries++;
                if (tries > 10) begin
                    $display("  >>> TIMEOUT waiting for STATUS.DONE after start");
                    break;
                end
            end while (rd[1] != 1'b1);
            $display("  STATUS = 0x%08h (BUSY=%0d DONE=%0d) after %0d polls",
                     rd, rd[0], rd[1], tries);
        end

        // Read ICOUNT, OCOUNT
        axil_read(A_ICOUNT, rd);
        $display("  ICOUNT = %0d (expected %0d)", rd, K * 2 * N);
        axil_read(A_OCOUNT, rd);
        $display("  OCOUNT = %0d (expected %0d)", rd, N * N);

        // Compare results
        begin
            real psnr_mse;
            real hw_pix, sw_pix, err_pix, psnr;
            logic signed [RESW-1:0] cv;
            int fout;

            fout = $fopen("gemm_axis_n22_out.txt", "w");
            psnr_mse = 0.0;
            $display("");
            $display(" pixel   c_flat   hw_pix    sw_pix    abs_err   tag");
            for (int i = 0; i < N; i++) begin
                cv = $signed(rx_data[i]);
                $fwrite(fout, "%0d\n", cv);
                hw_pix  = real'(cv) / real'(1 << (WIDTH-1)) * real'(K);
                sw_pix  = expected[i];
                err_pix = (hw_pix > sw_pix) ? (hw_pix - sw_pix) : (sw_pix - hw_pix);
                if (i < IMG_DIM) begin
                    psnr_mse = psnr_mse + err_pix * err_pix;
                    $display(" %4d   %8d   %7.4f   %7.4f   %7.4f   meaningful",
                             i, cv, hw_pix, sw_pix, err_pix);
                end else begin
                    $display(" %4d   %8d   %7.4f   %7.4f   %7.4f   zero-padded",
                             i, cv, hw_pix, sw_pix, err_pix);
                end
            end
            $fclose(fout);

            psnr_mse = psnr_mse / real'(IMG_DIM);
            if (psnr_mse > 0.0) begin
                psnr = 10.0 * $ln(real'(K)*real'(K) / psnr_mse) / $ln(10.0);
                $display("");
                $display(" Wrapper PSNR (vs bipolar sum range [-K,+K]) = %0.2f dB", psnr);
            end
        end

        $display("============================================================");
        $finish;
    end

    // ---- Safety timeout -------------------------------------------------
    initial begin
        #(CLK_PERIOD * (STREAM_LEN_RESIDUE + K * K_SAR_BITS * SAR_BIT_LEN) * 8);
        $display("FATAL: testbench timeout");
        $finish;
    end

endmodule

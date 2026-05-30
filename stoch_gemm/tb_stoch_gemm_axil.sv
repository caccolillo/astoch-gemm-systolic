`timescale 1ns/1ps
// =============================================================================
// tb_stoch_gemm_axil.sv
// Self-checking testbench for the AXI4-Lite wrapper stoch_gemm_axil.
// Drives the accelerator purely through AXI-Lite register reads/writes -- the
// same way the ARM PS would -- runs a small GEMM, and checks the result
// against a behavioural reference within stochastic tolerance.
// =============================================================================
module tb_stoch_gemm_axil;

  localparam int N          = 8;
  localparam int WIDTH      = 16;
  localparam int LFSR_W     = 16;
  localparam int STREAM_LEN = 256;
  localparam int KW         = 16;
  localparam int AW         = 12;
  localparam int DW         = 32;
  localparam int K          = 3;       // contraction depth under test

  // mirror core derived widths
  localparam int CNTW = $clog2((1<<KW)-1) + $clog2(STREAM_LEN+1) + 1;
  localparam int RESW = CNTW + 2;

  // register offsets (bytes)
  localparam CTRL=12'h00, STATUS=12'h04, KLEN=12'h08, OPIDX=12'h0C,
             RESIDX=12'h10, RESLO=12'h14, RESHI=12'h18, INFO=12'h1C,
             INFO2=12'h20, ABASE=12'h40, BBASE=12'h80;

  logic clk=0, aresetn;
  always #5 clk = ~clk;   // 100 MHz

  // AXI-Lite signals
  logic [AW-1:0] awaddr;  logic awvalid; logic awready;
  logic [DW-1:0] wdata;   logic [3:0] wstrb; logic wvalid; logic wready;
  logic [1:0] bresp;      logic bvalid;  logic bready;
  logic [AW-1:0] araddr;  logic arvalid; logic arready;
  logic [DW-1:0] rdata;   logic [1:0] rresp; logic rvalid; logic rready;
  logic irq;

  stoch_gemm_axil #(
    .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W), .STREAM_LEN(STREAM_LEN), .KW(KW),
    .C_S_AXI_ADDR_WIDTH(AW), .C_S_AXI_DATA_WIDTH(DW)
  ) dut (
    .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .irq(irq)
  );

  // ---- AXI-Lite write transaction ----
  task automatic axi_write(input [AW-1:0] addr, input [DW-1:0] data);
    begin
      @(posedge clk);
      awaddr<=addr; awvalid<=1; wdata<=data; wstrb<=4'hF; wvalid<=1; bready<=1;
      // wait for both ready
      do @(posedge clk); while (!(awready && wready));
      awvalid<=0; wvalid<=0;
      do @(posedge clk); while (!bvalid);
      bready<=0;
      @(posedge clk);
    end
  endtask

  // ---- AXI-Lite read transaction ----
  task automatic axi_read(input [AW-1:0] addr, output [DW-1:0] data);
    begin
      @(posedge clk);
      araddr<=addr; arvalid<=1; rready<=1;
      do @(posedge clk); while (!arready);
      arvalid<=0;
      do @(posedge clk); while (!rvalid);
      data = rdata;
      rready<=0;
      @(posedge clk);
    end
  endtask

  // operands as reals in [-1,1], offset-encoded
  real a_real[N][K], b_real[K][N];
  longint c_ref[N*N];
  integer seed;

  function automatic logic [WIDTH-1:0] enc(input real x);
    real s; int q; logic [WIDTH-1:0] r;
    s=(x+1.0)/2.0*(2.0**WIDTH); q=$rtoi(s);
    if(q<0)q=0; if(q>(2**WIDTH)-1)q=(2**WIDTH)-1;
    r=q[WIDTH-1:0]; return r;
  endfunction

  logic [DW-1:0] rd;
  integer i,j,k;
  longint num; real est, ideal, err, worst;
  integer fails;

  initial begin
    awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0;
    aresetn=0;
    repeat(6) @(posedge clk);
    aresetn=1;
    repeat(2) @(posedge clk);

    // sanity: read INFO
    axi_read(INFO, rd);
    $display("INFO  = %08h  (N=%0d KW=%0d CNTW=%0d RESW=%0d)",
             rd, rd[7:0], rd[15:8], rd[23:16], rd[31:24]);
    axi_read(INFO2, rd);
    $display("INFO2 = %0d  (STREAM_LEN)", rd);

    // build random operands and reference
    seed=32'hBEEF;
    for(i=0;i<N;i++) for(k=0;k<K;k++)
      a_real[i][k]=(($random(seed)%1000)/1000.0)*0.8;
    for(k=0;k<K;k++) for(j=0;j<N;j++)
      b_real[k][j]=(($random(seed)%1000)/1000.0)*0.8;
    for(i=0;i<N;i++) for(j=0;j<N;j++) begin
      longint acc; acc=0;
      for(k=0;k<K;k++) acc += longint'($rtoi(a_real[i][k]*1.0e6))
                            * longint'($rtoi(b_real[k][j]*1.0e6));
      c_ref[i*N+j]=acc;  // scaled ref, only used for sign/shape sanity
    end

    // program K
    axi_write(KLEN, K);

    // load operands term by term
    for(k=0;k<K;k++) begin
      axi_write(OPIDX, k);
      for(i=0;i<N;i++) axi_write(ABASE+4*i, {16'd0, enc(a_real[i][k])});
      for(j=0;j<N;j++) axi_write(BBASE+4*j, {16'd0, enc(b_real[k][j])});
    end

    // start
    axi_write(CTRL, 32'h1);

    // poll STATUS.DONE
    do axi_read(STATUS, rd); while (!rd[1]);
    $display("core finished (STATUS=%08h)", rd);

    // read back all results, compare against ideal real GEMM
    worst=0.0; fails=0;
    for(i=0;i<N;i++) for(j=0;j<N;j++) begin
      axi_write(RESIDX, i*N+j);
      axi_read(RESLO, rd);  num = {{32{1'b0}}, rd};
      axi_read(RESHI, rd);  num = {rd, num[31:0]};
      // sign-extend from 64-bit
      est = $itor($signed(num)) / real'(STREAM_LEN);
      ideal = 0.0;
      for(k=0;k<K;k++) ideal += a_real[i][k]*b_real[k][j];
      err = (est>ideal)?(est-ideal):(ideal-est);
      if(err>worst) worst=err;
      // Tolerance scaled to the stochastic noise floor. Per-element error in
      // bipolar stochastic computing falls as ~1/sqrt(STREAM_LEN); with K
      // accumulated terms the spread grows ~sqrt(K). A few-sigma bound is
      //   tol ~= 3 * sqrt(K) / sqrt(STREAM_LEN).
      // A fixed threshold would wrongly fail short streams (noise) or pass
      // sloppily on long ones; scaling keeps the check honest at any L.
      if(err > 3.0*$sqrt(real'(K))/$sqrt(real'(STREAM_LEN))) begin
        fails++;
        if(fails<=8) $display("  MISMATCH C[%0d][%0d] est=%0.4f ideal=%0.4f err=%0.4f",
                              i,j,est,ideal,err);
      end
    end
    $display("-------------------------------------------------------");
    $display("AXI-Lite wrapper test  N=%0d K=%0d STREAM_LEN=%0d", N,K,STREAM_LEN);
    $display("per-element tolerance = %0.4f  (3*sqrt(K)/sqrt(L))",
             3.0*$sqrt(real'(K))/$sqrt(real'(STREAM_LEN)));
    $display("worst abs error = %0.4f", worst);
    if(fails==0) $display("PASS: all %0d results within tolerance via AXI-Lite.", N*N);
    else         $display("FAIL: %0d/%0d out of tolerance.", fails, N*N);
    $display("-------------------------------------------------------");
    $finish;
  end

  initial begin #200000000; $display("FAIL: timeout"); $finish; end
endmodule

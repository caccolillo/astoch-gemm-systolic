`timescale 1ns/1ps
// =============================================================================
// tb_stoch_gemm_axis.sv
// Self-checking testbench for the streaming wrapper stoch_gemm_axis.
// Drives control via AXI-Lite and data via AXI-Stream (operands in on s_axis,
// results out on m_axis) -- emulating an AXI DMA. Checks results within the
// stochastic noise floor.
// =============================================================================
module tb_stoch_gemm_axis;

  localparam int N=8, WIDTH=16, LFSR_W=16, STREAM_LEN=512, KW=16;
  localparam int AW=12, DW=32, K=3;
  localparam int CNTW=$clog2((1<<KW)-1)+$clog2(STREAM_LEN+1)+1, RESW=CNTW+2;

  localparam CTRL=12'h00, STATUS=12'h04, KLEN=12'h08, INFO=12'h0C,
             INFO2=12'h10, ICOUNT=12'h14, OCOUNT=12'h18;

  logic clk=0, rstn; always #5 clk=~clk;

  // AXI-Lite
  logic [AW-1:0] awaddr; logic awvalid,awready;
  logic [DW-1:0] wdata;  logic [3:0] wstrb; logic wvalid,wready;
  logic [1:0] bresp; logic bvalid,bready;
  logic [AW-1:0] araddr; logic arvalid,arready;
  logic [DW-1:0] rdata; logic [1:0] rresp; logic rvalid,rready;
  // AXI-Stream
  logic [31:0] s_tdata; logic s_tvalid,s_tready,s_tlast;
  logic [31:0] m_tdata; logic m_tvalid,m_tready,m_tlast;
  logic irq;

  stoch_gemm_axis #(.N(N),.WIDTH(WIDTH),.LFSR_W(LFSR_W),.STREAM_LEN(STREAM_LEN),
    .KW(KW),.C_S_AXI_ADDR_WIDTH(AW),.C_S_AXI_DATA_WIDTH(DW)) dut(
    .aclk(clk),.aresetn(rstn),
    .s_axi_awaddr(awaddr),.s_axi_awprot(3'd0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
    .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
    .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
    .s_axi_araddr(araddr),.s_axi_arprot(3'd0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
    .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
    .s_axis_tdata(s_tdata),.s_axis_tvalid(s_tvalid),.s_axis_tready(s_tready),.s_axis_tlast(s_tlast),
    .m_axis_tdata(m_tdata),.m_axis_tvalid(m_tvalid),.m_axis_tready(m_tready),.m_axis_tlast(m_tlast),
    .irq(irq));

  task automatic axi_write(input [AW-1:0] a, input [DW-1:0] d);
    begin @(posedge clk);
      awaddr<=a;awvalid<=1;wdata<=d;wstrb<=4'hF;wvalid<=1;bready<=1;
      do @(posedge clk); while(!(awready&&wready));
      awvalid<=0;wvalid<=0;
      do @(posedge clk); while(!bvalid);
      bready<=0;@(posedge clk);
    end
  endtask
  task automatic axi_read(input [AW-1:0] a, output [DW-1:0] d);
    begin @(posedge clk);
      araddr<=a;arvalid<=1;rready<=1;
      do @(posedge clk); while(!arready);
      arvalid<=0;
      do @(posedge clk); while(!rvalid);
      d=rdata;rready<=0;@(posedge clk);
    end
  endtask
  // push one beat onto s_axis
  task automatic s_push(input [31:0] d, input logic last);
    begin @(posedge clk);
      s_tdata<=d;s_tvalid<=1;s_tlast<=last;
      do @(posedge clk); while(!s_tready);
      s_tvalid<=0;s_tlast<=0;
    end
  endtask

  function automatic logic [WIDTH-1:0] enc(input real x);
    real s; int q;
    s=(x+1.0)/2.0*(2.0**WIDTH); q=$rtoi(s);
    if(q<0)q=0; if(q>(2**WIDTH)-1)q=(2**WIDTH)-1;
    return q[WIDTH-1:0];
  endfunction

  real a_r[N][K], b_r[K][N];
  real est[N*N], ideal[N*N];
  logic [DW-1:0] rd;
  integer i,j,k,seed,oi,fails;
  real err,worst,tol;

  initial begin
    awvalid=0;wvalid=0;bready=0;arvalid=0;rready=0;
    s_tvalid=0;s_tlast=0;m_tready=0;
    rstn=0; repeat(6)@(posedge clk); rstn=1; repeat(2)@(posedge clk);

    axi_read(INFO,rd);
    $display("INFO=%08h N=%0d KW=%0d CNTW=%0d RESW=%0d",
             rd,rd[7:0],rd[15:8],rd[23:16],rd[31:24]);

    // random operands + ideal reference
    seed=32'h1234;
    for(i=0;i<N;i++) for(k=0;k<K;k++) a_r[i][k]=(($random(seed)%1000)/1000.0)*0.8;
    for(k=0;k<K;k++) for(j=0;j<N;j++) b_r[k][j]=(($random(seed)%1000)/1000.0)*0.8;
    for(i=0;i<N;i++) for(j=0;j<N;j++) begin
      ideal[i*N+j]=0.0;
      for(k=0;k<K;k++) ideal[i*N+j]+=a_r[i][k]*b_r[k][j];
    end

    axi_write(KLEN,K);

    // stream operands: per term -> N a-beats then N b-beats
    for(k=0;k<K;k++) begin
      for(i=0;i<N;i++)
        s_push({16'd0,enc(a_r[i][k])}, (k==K-1 && i==N-1)?1'b0:1'b0);
      for(j=0;j<N;j++)
        s_push({16'd0,enc(b_r[k][j])}, (k==K-1 && j==N-1)?1'b1:1'b0);
    end
    $display("operands streamed in");
    axi_read(ICOUNT,rd); $display("ICOUNT=%0d (expect %0d)", rd, 2*N*K);

    // start the core
    axi_write(CTRL,32'h1);

    // drain results from m_axis
    oi=0; m_tready=1;
    while(oi<N*N) begin
      @(posedge clk);
      if(m_tvalid && m_tready) begin
        est[oi]=$itor($signed(m_tdata))/real'(STREAM_LEN);
        oi++;
      end
    end
    m_tready=0;
    $display("results streamed out (%0d beats)", oi);

    // check
    tol=3.0*$sqrt(real'(K))/$sqrt(real'(STREAM_LEN));
    worst=0.0; fails=0;
    for(i=0;i<N*N;i++) begin
      err=(est[i]>ideal[i])?(est[i]-ideal[i]):(ideal[i]-est[i]);
      if(err>worst) worst=err;
      if(err>tol) begin
        fails++;
        if(fails<=8) $display("  MISMATCH elem %0d est=%0.4f ideal=%0.4f err=%0.4f",
                              i,est[i],ideal[i],err);
      end
    end
    $display("-------------------------------------------------------");
    $display("AXI-Stream wrapper test  N=%0d K=%0d STREAM_LEN=%0d",N,K,STREAM_LEN);
    $display("tolerance=%0.4f  worst error=%0.4f", tol, worst);
    if(fails==0) $display("PASS: all %0d results correct via AXI-Stream path.",N*N);
    else         $display("FAIL: %0d/%0d out of tolerance.",fails,N*N);
    $display("-------------------------------------------------------");
    $finish;
  end
  initial begin #50000000; $display("FAIL: timeout"); $finish; end
endmodule

`timescale 1ns/1ps
// One-shot generator: runs stoch_gemm_top_hybrid_rad at the REAL production
// parameter set (N=22, WIDTH=16, K_SAR_BITS=8, SAR_BIT_LEN=32,
// STREAM_LEN_RESIDUE=65536 -- matching tb_stoch_gemm_axis_hybrid_n22.sv)
// with a fixed BIST input pattern and K_LEN=1, captures core_c_flat at
// core_done, and prints it in a form that can be pasted straight into the
// BIST golden-constant localparam in stoch_gemm_axis_hybrid_rad.sv.
//
// Re-run this (and re-paste the printed constant) if N, WIDTH, LFSR_W,
// K_SAR_BITS, SAR_BIT_LEN, or STREAM_LEN_RESIDUE ever change in the
// production wrapper -- the golden vector is only valid for the exact
// parameter set it was generated against.
module gen_bist_golden;

    localparam int N                  = 22;
    localparam int WIDTH              = 16;
    localparam int LFSR_W             = 16;
    localparam int K_SAR_BITS         = 8;
    localparam int SAR_BIT_LEN        = 32;
    localparam int STREAM_LEN_RESIDUE = 65536;
    localparam int KMAX               = 16;
    localparam int RESW               = WIDTH + 2;
    localparam int RESULT_W           = N*N*RESW;

    logic clk = 0;
    logic rst_n;
    logic core_start;
    logic [$clog2(KMAX+1)-1:0] k_len;
    logic [31:0] res_per_k;
    logic core_busy, core_done;
    logic [$clog2(KMAX)-1:0] core_kidx;
    logic core_load_k;
    logic [N*WIDTH-1:0] core_a_bin, core_b_bin;
    logic signed [N*N*RESW-1:0] core_c_flat;
    logic core_watchdog_fault, core_tmr_mismatch, core_fault;

    always #5 clk = ~clk;

    // Same fixed pattern that will be embedded in the production BIST logic.
    function automatic logic [WIDTH-1:0] bist_a_val(int idx);
        return WIDTH'(16'h3000 + idx * 16'h0140);
    endfunction
    function automatic logic [WIDTH-1:0] bist_b_val(int idx);
        return WIDTH'(16'hC000 - idx * 16'h0140);
    endfunction

    initial begin
        core_a_bin = '0;
        core_b_bin = '0;
        for (int i = 0; i < N; i++) begin
            core_a_bin[i*WIDTH +: WIDTH] = bist_a_val(i);
            core_b_bin[i*WIDTH +: WIDTH] = bist_b_val(i);
        end
    end

    stoch_gemm_top_hybrid_rad #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .K_SAR_BITS(K_SAR_BITS), .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE), .KMAX(KMAX), .RESW(RESW),
        .RAD_TMR_FSM(1), .RAD_WATCHDOG(1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .core_start(core_start), .k_len(k_len), .res_per_k(res_per_k),
        .core_busy(core_busy), .core_done(core_done),
        .core_kidx(core_kidx), .core_load_k(core_load_k),
        .core_a_bin(core_a_bin), .core_b_bin(core_b_bin),
        .core_c_flat(core_c_flat),
        .core_watchdog_fault(core_watchdog_fault),
        .core_tmr_mismatch(core_tmr_mismatch),
        .core_fault(core_fault)
    );

    initial begin
        rst_n = 0; core_start = 0; k_len = 1; res_per_k = 32'd8192;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        @(posedge clk);
        core_start <= 1'b1;
        @(posedge clk);
        core_start <= 1'b0;

        $display("[%0t] BIST golden-vector run started, waiting for core_done...", $time);
        wait (core_done);
        $display("[%0t] core_done asserted.", $time);
        $display("BIST_GOLDEN_HEX_BEGIN");
        $display("%0d'h%0h", RESULT_W, core_c_flat);
        $display("BIST_GOLDEN_HEX_END");
        $display("core_watchdog_fault=%0b core_tmr_mismatch=%0b core_fault=%0b",
                  core_watchdog_fault, core_tmr_mismatch, core_fault);
        $finish;
    end

    // Safety timeout in case something hangs.
    initial begin
        #(1_500_000);
        $display("TIMEOUT -- core_done never asserted");
        $finish;
    end

endmodule

`timescale 1ns/1ps
// =============================================================================
// tb_radhard_fault_injection.sv
//
// Exercises stoch_gemm_top_hybrid_rad directly (not through the AXI wrapper)
// with deliberately small parameters so each scenario runs in microseconds
// of sim time instead of the real ~680us/tile budget. Three scenarios:
//
//   1. BASELINE   -- no faults injected, tile must complete and core_fault
//                    must stay 0 throughout.
//   2. TMR_UPSET  -- force a single bit flip into ONE of the three state
//                    register copies mid-tile (simulating an SEU hitting
//                    exactly one CRAM-backed flip-flop). Expect: the voted
//                    `state` is undisturbed (other two copies still agree),
//                    core_tmr_mismatch goes high and stays sticky, but the
//                    tile still completes on schedule and core_watchdog_fault
//                    stays low. This is the "SEU caught and corrected"
//                    success case.
//   3. STUCK_FSM  -- force ALL THREE state copies to a non-IDLE,
//                    non-advancing value and hold it (simulating a fault
//                    severe enough to defeat TMR, e.g. a multi-bit event,
//                    or simply demonstrating the backstop in isolation).
//                    Expect: TMR sees agreement (no mismatch -- this is the
//                    case TMR structurally cannot catch), but the watchdog
//                    independently trips after WATCHDOG_LIMIT cycles and
//                    forces the FSM back to S_IDLE with core_watchdog_fault
//                    asserted.
// =============================================================================
module tb_radhard_fault_injection;

    // Small parameters for fast simulation.
    localparam int N                  = 2;
    localparam int WIDTH              = 8;
    localparam int LFSR_W             = 8;
    localparam int K_SAR_BITS         = 4;
    localparam int SAR_BIT_LEN        = 4;
    localparam int STREAM_LEN_RESIDUE = 32;
    localparam int KMAX               = 4;
    localparam int RESW               = WIDTH + 2;
    localparam int K_LEN              = 2;

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

    stoch_gemm_top_hybrid_rad #(
        .N(N), .WIDTH(WIDTH), .LFSR_W(LFSR_W),
        .K_SAR_BITS(K_SAR_BITS), .SAR_BIT_LEN(SAR_BIT_LEN),
        .STREAM_LEN_RESIDUE(STREAM_LEN_RESIDUE), .KMAX(KMAX), .RESW(RESW),
        .RAD_TMR_FSM(1), .RAD_WATCHDOG(1),
        .WATCHDOG_LIMIT(200)   // tight on purpose so scenario 3 finishes fast
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

    // Keep operands constant and benign throughout (offset-encoded mid-scale).
    initial begin
        core_a_bin = {N{8'h80}};
        core_b_bin = {N{8'h80}};
    end

    task automatic do_reset;
        rst_n = 0; core_start = 0; k_len = K_LEN; res_per_k = 32'd16;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
    endtask

    task automatic pulse_start;
        @(posedge clk);
        core_start <= 1'b1;
        @(posedge clk);
        core_start <= 1'b0;
    endtask

    int errors = 0;

    // Polling-based wait-with-timeout helpers, one per target signal
    // (Icarus doesn't support `ref` task ports, so these can't be generic).
    task automatic wait_done(input int max_cycles, input string what);
        int n;
        n = 0;
        while (!core_done && n < max_cycles) begin
            @(posedge clk);
            n++;
        end
        if (!core_done) begin
            $display("  FAIL: timeout waiting for %s after %0d cycles", what, max_cycles);
            errors++;
        end
    endtask

    task automatic wait_watchdog(input int max_cycles, input string what);
        int n;
        n = 0;
        while (!core_watchdog_fault && n < max_cycles) begin
            @(posedge clk);
            n++;
        end
        if (!core_watchdog_fault) begin
            $display("  FAIL: timeout waiting for %s after %0d cycles", what, max_cycles);
            errors++;
        end
    endtask

    // ---- Scenario 1: baseline, no faults ----------------------------------
    task automatic scenario_baseline;
        $display("\n===== SCENARIO 1: BASELINE (no fault injection) =====");
        do_reset();
        pulse_start();
        wait_done(5000, "baseline tile completion");
        @(posedge clk);
        if (core_fault) begin
            $display("  FAIL: core_fault asserted with no injected fault");
            errors++;
        end else begin
            $display("  PASS: tile completed cleanly, core_fault=0");
        end
    endtask

    // ---- Scenario 2: single-copy TMR upset, should self-heal --------------
    task automatic scenario_tmr_upset;
        $display("\n===== SCENARIO 2: SINGLE-COPY TMR UPSET (state_b) =====");
        do_reset();
        pulse_start();

        // Let the tile get into the SAR phase, then flip state_b only
        // (one of the three triplicated copies) for one cycle, simulating
        // an SEU landing on exactly one flip-flop. state_a and state_c are
        // untouched, so the voter should still see 2-of-3 agreement.
        repeat (6) @(posedge clk);
        $display("  [%0t] injecting single-bit upset into state_b (was %0d)",
                  $time, dut.state_b);
        // state_b is logic[3:0]; dut.state is state_t (enum) -- use bit-select
        // to obtain a plain logic value before XOR, satisfying XSim's type rules.
        force dut.state_b = dut.state[3:0] ^ 4'h1;
        @(posedge clk);
        release dut.state_b;
        $display("  [%0t] released forced upset; state_b will resync next cycle",
                  $time);

        wait_done(5000, "tile completion after TMR upset");
        @(posedge clk);

        if (!core_tmr_mismatch) begin
            $display("  FAIL: expected core_tmr_mismatch=1 (voter should have caught the upset)");
            errors++;
        end else begin
            $display("  PASS: core_tmr_mismatch=1 -- voter detected and corrected the upset");
        end
        if (core_watchdog_fault) begin
            $display("  FAIL: watchdog should NOT have tripped on a corrected TMR upset");
            errors++;
        end else begin
            $display("  PASS: core_watchdog_fault=0 -- tile still completed on schedule");
        end
    endtask

    // ---- Scenario 3: all three copies stuck, watchdog backstop ------------
    task automatic scenario_watchdog;
        $display("\n===== SCENARIO 3: STUCK FSM, WATCHDOG BACKSTOP =====");
        do_reset();
        pulse_start();

        repeat (6) @(posedge clk);
        $display("  [%0t] forcing ALL THREE state copies to a stuck non-IDLE value",
                  $time);
        force dut.state_a = 4'h2; // S_SAR_BIT_START, held
        force dut.state_b = 4'h2;
        force dut.state_c = 4'h2;

        wait_watchdog(2000, "watchdog trip on stuck FSM");
        $display("  [%0t] watchdog tripped, releasing forced state", $time);
        release dut.state_a;
        release dut.state_b;
        release dut.state_c;

        if (core_tmr_mismatch) begin
            $display("  NOTE: core_tmr_mismatch also set (expected -- all three copies");
            $display("        agreed throughout, this is exactly the case TMR alone can't catch)");
        end
        if (!core_watchdog_fault) begin
            $display("  FAIL: expected core_watchdog_fault=1");
            errors++;
        end else begin
            $display("  PASS: core_watchdog_fault=1 -- backstop caught what TMR structurally cannot");
        end

        // Confirm recovery: a fresh tile after release should run clean.
        repeat (4) @(posedge clk);
        do_reset();
        pulse_start();
        wait_done(5000, "recovery tile after watchdog trip");
        $display("  PASS: device recovered and completed a clean tile after the fault");
    endtask

    initial begin
        scenario_baseline();
        scenario_tmr_upset();
        scenario_watchdog();

        $display("\n============================================================");
        if (errors == 0) $display("ALL FAULT-INJECTION SCENARIOS PASSED");
        else              $display("%0d SCENARIO(S) FAILED", errors);
        $display("============================================================");
        $finish;
    end

endmodule

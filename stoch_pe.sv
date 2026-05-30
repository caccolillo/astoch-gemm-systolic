`timescale 1ns/1ps

// =============================================================================
// stoch_pe.sv
// Processing Element (PE) for a FULLY STOCHASTIC output-stationary systolic
// GEMM array.
//
// Target: Xilinx Zynq UltraScale+ ZU3EG (Avnet Ultra96-V2), Vivado 2022.2.
// Reset : synchronous, ACTIVE-HIGH.
//
// --- Stochastic computing background --------------------------------------
// Operands are BIPOLAR stochastic bitstreams: a stream of length L encodes a
// value  v = 2*P(bit=1) - 1  in the range [-1, +1], where P(bit=1) is the
// fraction of '1's in the stream.
//
// Bipolar multiplication of two independent streams is a single XNOR gate:
//     bit_product = ~(a_bit ^ b_bit)
// because substituting the bipolar mapping into P(xnor=1) gives
// v_product = v_a * v_b in expectation.
//
// --- Dataflow, and why 'valid' travels with the operands -------------------
// Each PE owns one output element C[i][j]. Operand bits stream THROUGH the PE
// one bit per cycle: 'a' rightward, 'b' downward. Because a bit takes one
// cycle to hop to the next PE, operands reach PE(i,j) only after a diagonal
// skew of (i + j) cycles relative to the array edge.
//
// The COUNTING WINDOW must therefore also be skewed: PE(i,j) may only count
// products during the K*L cycles when ITS operands are the valid ones. To do
// this every PE carries a 'valid' bit that flows diagonally exactly like the
// operands -- 'v_in' enters with the operand bits, gates the counter, and is
// registered out (as 'v_a_out' / 'v_b_out') one hop along each axis. Each PE
// then counts over exactly K*L valid products, so the central de-bias
// 2*cnt - K*L is exact for every PE regardless of its position.
//
// --- Recovering the GEMM value ---------------------------------------------
// Over K terms PE(i,j) sees K*L valid product bits with grand '1's count
// 'cnt'. The true GEMM element is  C[i][j] = (2*cnt - K*L) / L  (range
// [-K, K]). The PE exposes the RAW count; the affine de-bias and /L scaling
// are done once, centrally, in stoch_gemm_top.
//
// Resource note: per PE this is one XNOR, three 1-bit pipeline registers
// (a, b, valid), and one counter. No DSP48E2 anywhere in the array.
//
// Parameters:
//   CNTW : width of the product-'1's counter. Must hold up to K*STREAM_LEN.
//
// Inputs:
//   clk     : clock
//   rst     : synchronous active-HIGH reset
//   run     : global pipeline-advance enable (advances ALL hop registers so
//             the skew staircase fills/drains; does NOT by itself count)
//   clr     : synchronous clear of counter + all pipeline registers
//   a_in    : 1-bit bipolar stochastic operand from the left
//   b_in    : 1-bit bipolar stochastic operand from above
//   v_in    : 1-bit 'valid' travelling with the operands; when high (and run
//             high) this PE counts the current product
//
// Outputs:
//   a_out    : a_in registered, forwarded to the right
//   b_out    : b_in registered, forwarded below
//   v_a_out  : v_in registered, forwarded to the right (paired with a_out)
//   v_b_out  : v_in registered, forwarded below       (paired with b_out)
//   cnt      : running count of valid XNOR-product '1's (raw)
// =============================================================================

module stoch_pe #(
    parameter int CNTW = 20
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              run,
    input  logic              clr,
    input  logic              a_in,
    input  logic              b_in,
    input  logic              v_in,
    output logic              a_out,
    output logic              b_out,
    output logic              v_a_out,
    output logic              v_b_out,
    output logic [CNTW-1:0]   cnt
);

    // Bipolar stochastic multiply: a single XNOR gate.
    logic prod_bit;
    assign prod_bit = ~(a_in ^ b_in);

    always_ff @(posedge clk) begin
        if (rst || clr) begin
            // Flush all pipeline registers AND the counter so a fresh tile
            // cannot be contaminated by a previous run's residue.
            a_out   <= 1'b0;
            b_out   <= 1'b0;
            v_a_out <= 1'b0;
            v_b_out <= 1'b0;
            cnt     <= '0;
        end else if (run) begin
            // Advance the hop registers every run cycle so the skew
            // staircase fills and drains correctly.
            a_out   <= a_in;
            b_out   <= b_in;
            v_a_out <= v_in;
            v_b_out <= v_in;
            // Count only when THIS PE's operands are the valid ones.
            if (v_in)
                cnt <= cnt + {{(CNTW-1){1'b0}}, prod_bit};
        end
    end

endmodule

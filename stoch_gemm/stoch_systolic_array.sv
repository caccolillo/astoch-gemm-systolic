`timescale 1ns/1ps

// =============================================================================
// stoch_systolic_array.sv
// 8x8 (parameterizable N x N) FULLY STOCHASTIC output-stationary systolic
// array for GEMM.
//
// Target: Xilinx Zynq UltraScale+ ZU3EG (Avnet Ultra96-V2), Vivado 2022.2.
// Reset : synchronous, ACTIVE-HIGH.
//
// Computes a tile  C[N][N] = A[N][K] * B[K][N]  in the BIPOLAR stochastic
// domain. A is fed as bitstreams into the LEFT edge, B into the TOP edge;
// each PE(i,j) XNOR-multiplies and counts, producing the raw '1's count for
// C[i][j]. The top level converts those counts back to numeric GEMM values.
//
// For im2col-based convolution / image processing:
//   - A = the filter matrix : N output channels x K patch elements, each
//         coefficient turned into a bipolar bitstream by an SNG.
//   - B = the im2col (lowered) activation matrix : K patch elements x N image
//         patches, likewise SNG-encoded.
//   - C = N output channels x N output pixels for this tile.
//
// --- Dataflow, skew, and the valid signal ----------------------------------
// Operand BITS hop one PE per cycle ('A' rightward, 'B' downward). Operands
// reach PE(i,j) after a diagonal skew of (i + j) cycles. A 'valid' bit is
// injected at the edges alongside the operands and flows diagonally with
// them, so it reaches PE(i,j) with exactly the same (i + j) skew. Each PE
// counts a product only while its own valid is high -- giving every PE a
// correctly-aligned K*L-cycle counting window regardless of position. This is
// what makes the central de-bias 2*cnt - K*L exact for ALL elements.
//
// The 'run' input advances every hop register each cycle (so the skew
// staircase fills and drains); 'valid' decides which cycles actually count.
//
// Resource note: N*N PEs, each just an XNOR + three FFs + one counter. NO
// DSP48E2 anywhere -- a key advantage of the stochastic approach.
//
// Parameters:
//   N    : array dimension (rows = cols). Default 8 -> 8x8 = 64 PEs.
//   CNTW : per-PE counter width (must hold up to K*STREAM_LEN).
//
// Inputs:
//   clk    : clock
//   rst    : synchronous active-HIGH reset
//   run    : global pipeline-advance enable
//   clr    : clear all counters + pipeline registers
//   a_left : N skewed 1-bit operands for the left edge, a_left[i] -> row i
//   b_top  : N skewed 1-bit operands for the top  edge, b_top[j]  -> column j
//   v_left : N skewed 'valid' bits for the left edge, v_left[i] -> row i
//   v_top  : N skewed 'valid' bits for the top  edge, v_top[j]  -> column j
//            (v_left and v_top are driven from the same skew network as the
//             operands, so the valid paired with 'a' and the valid paired
//             with 'b' agree at every PE.)
//
// Outputs:
//   cnt_flat : flattened N*N raw counts.
//              count(i,j) = cnt_flat[(i*N+j)*CNTW +: CNTW]
// =============================================================================

module stoch_systolic_array #(
    parameter int N    = 8,
    parameter int CNTW = 20
) (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    run,
    input  logic                    clr,
    input  logic [N-1:0]             a_left,
    input  logic [N-1:0]             b_top,
    input  logic [N-1:0]             v_left,
    input  logic [N-1:0]             v_top,
    output logic [N*N*CNTW-1:0]      cnt_flat
);

    // Inter-PE 1-bit wiring.
    //   a_h[i][j]  : A operand into PE(i,j) from the left;  column N dangles.
    //   b_v[i][j]  : B operand into PE(i,j) from above;     row N dangles.
    //   va_h[i][j] : valid paired with a_h (travels rightward).
    //   vb_v[i][j] : valid paired with b_v (travels downward).
    logic a_h  [N]  [N+1];
    logic b_v  [N+1][N];
    logic va_h [N]  [N+1];
    logic vb_v [N+1][N];

    genvar gi, gj;

    // ---- Edge injection -----------------------------------------------------
    generate
        for (gi = 0; gi < N; gi++) begin : g_left_edge
            assign a_h[gi][0]  = a_left[gi];
            assign va_h[gi][0] = v_left[gi];
        end
        for (gj = 0; gj < N; gj++) begin : g_top_edge
            assign b_v[0][gj]  = b_top[gj];
            assign vb_v[0][gj] = v_top[gj];
        end
    endgenerate

    // ---- PE fabric ----------------------------------------------------------
    // Each PE uses the valid that travels with 'a' (va_h) as its count gate;
    // the valid travelling with 'b' (vb_v) carries the identical skew and is
    // propagated downward. Both are kept so the staircase stays consistent.
    generate
        for (gi = 0; gi < N; gi++) begin : g_row
            for (gj = 0; gj < N; gj++) begin : g_col
                stoch_pe #(
                    .CNTW (CNTW)
                ) u_pe (
                    .clk     (clk),
                    .rst     (rst),
                    .run     (run),
                    .clr     (clr),
                    .a_in    (a_h[gi][gj]),
                    .b_in    (b_v[gi][gj]),
                    .v_in    (va_h[gi][gj]),
                    .a_out   (a_h[gi][gj+1]),
                    .b_out   (b_v[gi+1][gj]),
                    .v_a_out (va_h[gi][gj+1]),
                    .v_b_out (vb_v[gi+1][gj]),
                    .cnt     (cnt_flat[(gi*N + gj)*CNTW +: CNTW])
                );
            end
        end
    endgenerate

endmodule

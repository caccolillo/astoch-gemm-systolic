// =============================================================================
// stoch_systolic_array_hybrid.sv
// N x N systolic array using stoch_pe_hybrid PEs.
//
// Structurally identical to the original stoch_systolic_array.sv:
//   - SNGs at the array edges generate stochastic streams from binary
//     operand vectors a_bin (rows) and b_bin (columns).
//   - Streams flow diagonally through the array via pipeline registers
//     so each PE sees its own delayed (i+j) version.
//
// The only change is that each PE now contains its own SAR/residue
// converter and is driven by the broadcast control bus (start, clear_cnts,
// accumulate, commit, bit_idx, sar_phase, finalise) coming from
// stoch_gemm_top_hybrid.sv.
//
// Outputs
//   c_flat[i][j] : signed RESW-bit binary result for PE (i,j)
//   pe_done      : OR of all done flags (high when every PE has latched)
// =============================================================================

module stoch_systolic_array_hybrid #(
    parameter int N                  = 8,
    parameter int WIDTH              = 16,
    parameter int LFSR_W             = 16,
    parameter int RESW                = WIDTH + 2,
    parameter int STREAM_LEN_RESIDUE  = 65536,
    parameter logic [LFSR_W-1:0] SEED_BASE = 16'hACE1
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          v_in,
    input  logic [N*WIDTH-1:0]            a_bin,   // one operand per row
    input  logic [N*WIDTH-1:0]            b_bin,   // one operand per column

    // Broadcast control from the top FSM
    input  logic                          start,
    input  logic                          clear_cnts,
    input  logic                          accumulate,
    input  logic                          commit,
    input  logic [$clog2(WIDTH+1)-1:0]    bit_idx,
    input  logic                          sar_phase,
    input  logic                          finalise,

    output logic signed [N*N*RESW-1:0]    c_flat_flat,
    output logic                          pe_done
);

    // ---- Per-lane SNGs at the edges --------------------------------------
    logic [N-1:0] a_stream_edge, b_stream_edge;

    // Generate per-lane seeds (decorrelated streams across rows/columns)
    function automatic logic [LFSR_W-1:0] make_seed(int idx, int kind);
        logic [LFSR_W-1:0] s;
        s = SEED_BASE ^ LFSR_W'((idx+1) * (kind==0 ? 17 : 23));
        s[0] = 1'b1;
        return s;
    endfunction

    genvar i, j;
    generate
        for (i = 0; i < N; i++) begin : gen_a_sng
            sng #(.WIDTH(WIDTH)) u_sng_a (
                .clk      (clk),
                .rst_n    (rst_n),
                .enable   (accumulate),
                .binary_in(a_bin[i*WIDTH +: WIDTH]),
                .seed     (make_seed(i, 0)),
                .stoch_out(a_stream_edge[i])
            );
        end
        for (j = 0; j < N; j++) begin : gen_b_sng
            sng #(.WIDTH(WIDTH)) u_sng_b (
                .clk      (clk),
                .rst_n    (rst_n),
                .enable   (accumulate),
                .binary_in(b_bin[j*WIDTH +: WIDTH]),
                .seed     (make_seed(j, 1)),
                .stoch_out(b_stream_edge[j])
            );
        end
    endgenerate

    // ---- Diagonal skew pipelines for a (rightward) and b (downward) -----
    // Each PE receives a_stream[i][j] delayed by j cycles after the row edge,
    // and b_stream[i][j] delayed by i cycles after the column edge.
    logic a_grid [N][N];
    logic b_grid [N][N];

    generate
        for (i = 0; i < N; i++) begin : gen_a_rows
            assign a_grid[i][0] = a_stream_edge[i];
            for (j = 1; j < N; j++) begin : gen_a_skew
                logic a_ff;
                always_ff @(posedge clk) begin
                    if (!rst_n || start)    a_ff <= 1'b0;
                    else if (accumulate)    a_ff <= a_grid[i][j-1];
                end
                assign a_grid[i][j] = a_ff;
            end
        end
        for (j = 0; j < N; j++) begin : gen_b_cols
            assign b_grid[0][j] = b_stream_edge[j];
            for (i = 1; i < N; i++) begin : gen_b_skew
                logic b_ff;
                always_ff @(posedge clk) begin
                    if (!rst_n || start)    b_ff <= 1'b0;
                    else if (accumulate)    b_ff <= b_grid[i-1][j];
                end
                assign b_grid[i][j] = b_ff;
            end
        end
    endgenerate

    // ---- Per-PE c_flat outputs and done flags ----------------------------
    logic signed [RESW-1:0] c_arr [N][N];
    logic                   d_arr [N][N];

    generate
        for (i = 0; i < N; i++) begin : gen_pe_row
            for (j = 0; j < N; j++) begin : gen_pe_col
                stoch_pe_hybrid #(
                    .WIDTH              (WIDTH),
                    .RESW               (RESW),
                    .STREAM_LEN_RESIDUE (STREAM_LEN_RESIDUE),
                    // Distinct seed per PE so the per-PE feedback SNGs
                    // are decorrelated.
                    .SEED               (WIDTH'(SEED_BASE ^ WIDTH'((i*N + j + 1) * 31) | 1))
                ) u_pe (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .v_in       (v_in),
                    .a_stream   (a_grid[i][j]),
                    .b_stream   (b_grid[i][j]),
                    .start      (start),
                    .clear_cnts (clear_cnts),
                    .accumulate (accumulate),
                    .commit     (commit),
                    .bit_idx    (bit_idx),
                    .sar_phase  (sar_phase),
                    .finalise   (finalise),
                    .c_flat     (c_arr[i][j]),
                    .done       (d_arr[i][j])
                );
            end
        end
    endgenerate

    // ---- Flatten c_arr -> c_flat_flat (i is the slow index) -------------
    generate
        for (i = 0; i < N; i++) begin : gen_flat_row
            for (j = 0; j < N; j++) begin : gen_flat_col
                assign c_flat_flat[(i*N+j)*RESW +: RESW] = c_arr[i][j];
            end
        end
    endgenerate

    // ---- AND together the done flags (every PE finalises in the same cycle) -
    logic done_and;
    always_comb begin
        done_and = 1'b1;
        for (int ii = 0; ii < N; ii++)
            for (int jj = 0; jj < N; jj++)
                done_and = done_and & d_arr[ii][jj];
    end
    assign pe_done = done_and;

endmodule

// =============================================================================
// stoch_systolic_array_hybrid_rad.sv
// Identical to stoch_systolic_array_hybrid.sv except the two edge SNG
// generate blocks instantiate sng_rad instead of sng, with `reseed` wired to
// the same `start` pulse that already resets the diagonal skew pipelines and
// each PE's internal feedback LFSR a few lines below. See sng_rad.sv for why
// this is needed: it's what makes the wrapper-level re-run vote in
// stoch_gemm_axis_hybrid_rad.sv actually deterministic between runs.
//
// Spatial TMR of the 484-PE array itself is NOT done here -- see the header
// of stoch_gemm_top_hybrid_rad.sv for why (device utilisation / prior
// routing-failure precedent). This file's only job is making re-runs
// reproducible; protection against a fault landing on any one PE still
// comes entirely from running the tile more than once and voting, not from
// anything spatial in this module.
// =============================================================================

module stoch_systolic_array_hybrid_rad #(
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
    input  logic [N*WIDTH-1:0]            a_bin,
    input  logic [N*WIDTH-1:0]            b_bin,

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

    logic [N-1:0] a_stream_edge, b_stream_edge;

    function automatic logic [LFSR_W-1:0] make_seed(int idx, int kind);
        logic [LFSR_W-1:0] s;
        s = SEED_BASE ^ LFSR_W'((idx+1) * (kind==0 ? 17 : 23));
        s[0] = 1'b1;
        return s;
    endfunction

    genvar i, j;
    generate
        for (i = 0; i < N; i++) begin : gen_a_sng
            sng_rad #(.WIDTH(WIDTH)) u_sng_a (
                .clk      (clk),
                .rst_n    (rst_n),
                .reseed   (start),
                .enable   (accumulate),
                .binary_in(a_bin[i*WIDTH +: WIDTH]),
                .seed     (make_seed(i, 0)),
                .stoch_out(a_stream_edge[i])
            );
        end
        for (j = 0; j < N; j++) begin : gen_b_sng
            sng_rad #(.WIDTH(WIDTH)) u_sng_b (
                .clk      (clk),
                .rst_n    (rst_n),
                .reseed   (start),
                .enable   (accumulate),
                .binary_in(b_bin[j*WIDTH +: WIDTH]),
                .seed     (make_seed(j, 1)),
                .stoch_out(b_stream_edge[j])
            );
        end
    endgenerate

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

    logic signed [RESW-1:0] c_arr [N][N];
    logic                   d_arr [N][N];

    generate
        for (i = 0; i < N; i++) begin : gen_pe_row
            for (j = 0; j < N; j++) begin : gen_pe_col
                stoch_pe_hybrid #(
                    .WIDTH              (WIDTH),
                    .RESW               (RESW),
                    .STREAM_LEN_RESIDUE (STREAM_LEN_RESIDUE),
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

    generate
        for (i = 0; i < N; i++) begin : gen_flat_row
            for (j = 0; j < N; j++) begin : gen_flat_col
                assign c_flat_flat[(i*N+j)*RESW +: RESW] = c_arr[i][j];
            end
        end
    endgenerate

    logic done_and;
    always_comb begin
        done_and = 1'b1;
        for (int ii = 0; ii < N; ii++)
            for (int jj = 0; jj < N; jj++)
                done_and = done_and & d_arr[ii][jj];
    end
    assign pe_done = done_and;

endmodule

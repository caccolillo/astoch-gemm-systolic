`timescale 1ns/1ps

// =============================================================================
// s2b_counter.sv
// Stochastic-to-Binary converter using a simple serial counter.
//
// Counts the number of '1's in a stochastic bitstream over STREAM_LEN cycles.
// At the end of the window, the count is the estimate of binary_in.
//
// Output range: [0, STREAM_LEN], which corresponds to probability [0, 1].
// To recover a binary value in the same domain as the SNG (i.e., [0, 2^WIDTH-1]),
// scale by (2^WIDTH - 1) / STREAM_LEN, or simply choose STREAM_LEN = 2^WIDTH.
//
// Parameters:
//   STREAM_LEN : number of stochastic bits to integrate over. Default 256.
//
// Inputs:
//   clk       : clock
//   rst_n     : active-low synchronous reset
//   start     : pulse to begin a new conversion window
//   stoch_in  : 1-bit stochastic input
//
// Outputs:
//   binary_out : final count (valid when done=1)
//   done       : asserted for one cycle when conversion is complete
// =============================================================================

module s2b_counter #(
    parameter int STREAM_LEN = 256
) (
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            start,
    input  logic                            stoch_in,
    output logic [$clog2(STREAM_LEN+1)-1:0] binary_out,
    output logic                            done
);

    localparam int CNT_W = $clog2(STREAM_LEN + 1);
    localparam int LEN_W = $clog2(STREAM_LEN + 1);

    logic [CNT_W-1:0] count;
    logic [LEN_W-1:0] cycles;
    logic             busy;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count      <= '0;
            cycles     <= '0;
            busy       <= 1'b0;
            done       <= 1'b0;
            binary_out <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                count  <= {{(CNT_W-1){1'b0}}, stoch_in}; // first sample
                cycles <= 'd1;
                busy   <= 1'b1;
            end else if (busy) begin
                if (cycles == STREAM_LEN[LEN_W-1:0]) begin
                    binary_out <= count;
                    done       <= 1'b1;
                    busy       <= 1'b0;
                end else begin
                    count  <= count + {{(CNT_W-1){1'b0}}, stoch_in};
                    cycles <= cycles + 1'b1;
                end
            end
        end
    end

endmodule

`timescale 1ns/1ps

// =============================================================================
// sng.sv
// Binary-to-Stochastic converter (Stochastic Number Generator)
//
// Generates a unipolar stochastic bitstream where P(bit=1) = binary_in / 2^WIDTH.
// Uses an internal LFSR as the pseudo-random source and a magnitude comparator.
//
// Parameters:
//   WIDTH : bit-width of the binary input (and LFSR width). Default 8.
//
// Inputs:
//   clk       : clock
//   rst_n     : active-low synchronous reset
//   enable    : when high, generate one stochastic bit per cycle
//   binary_in : unsigned binary value, range [0, 2^WIDTH - 1]
//   seed      : LFSR seed (must be non-zero, loaded on reset)
//
// Output:
//   stoch_out : 1-bit stochastic stream
//
// Notes:
//   - The classic SNG: stoch_out = (LFSR < binary_in). This yields
//     P(stoch_out=1) = binary_in / 2^WIDTH for a uniformly distributed LFSR.
//   - The LFSR uses a maximal-length polynomial for WIDTH up to 16.
//     For other widths, replace the taps accordingly.
// =============================================================================

module sng #(
    parameter int WIDTH = 8
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              enable,
    input  logic [WIDTH-1:0]  binary_in,
    input  logic [WIDTH-1:0]  seed,
    output logic              stoch_out
);

    logic [WIDTH-1:0] lfsr;
    logic             feedback;

    // Maximal-length LFSR taps (Fibonacci form), encoded as a tap mask.
    // The feedback bit is the XOR-reduction of (lfsr & TAP_MASK).
    // Tap masks are taken from common max-length tables (e.g. XAPP052).
    // To add a new WIDTH, drop in the appropriate mask.
    localparam logic [WIDTH-1:0] TAP_MASK =
        (WIDTH == 4)  ? WIDTH'('hC)     :  // taps 4,3
        (WIDTH == 5)  ? WIDTH'('h14)    :  // taps 5,3
        (WIDTH == 6)  ? WIDTH'('h30)    :  // taps 6,5
        (WIDTH == 7)  ? WIDTH'('h60)    :  // taps 7,6
        (WIDTH == 8)  ? WIDTH'('hB8)    :  // taps 8,6,5,4
        (WIDTH == 10) ? WIDTH'('h240)   :  // taps 10,7
        (WIDTH == 12) ? WIDTH'('hE08)   :  // taps 12,11,10,4
        (WIDTH == 16) ? WIDTH'('hD008)  :  // taps 16,15,13,4
                        WIDTH'((1 << (WIDTH-1)) | 1'b1); // fallback: NOT max-length

    assign feedback = ^(lfsr & TAP_MASK);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Force non-zero seed; LFSR with all-zeros is a dead state.
            lfsr <= (seed == '0) ? {{(WIDTH-1){1'b0}}, 1'b1} : seed;
        end else if (enable) begin
            lfsr <= {lfsr[WIDTH-2:0], feedback};
        end
    end

    // Comparator: '1' is emitted with probability binary_in / 2^WIDTH.
    // Note: when binary_in == 2^WIDTH-1, the output is '1' for all but one
    // LFSR state (since LFSR never visits all-zeros), giving P ~= (2^WIDTH-1)/2^WIDTH.
    // This is the well-known small bias of LFSR-based SNGs.
    assign stoch_out = enable ? (lfsr < binary_in) : 1'b0;

endmodule

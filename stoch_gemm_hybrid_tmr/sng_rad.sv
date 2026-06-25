`timescale 1ns/1ps

// =============================================================================
// sng_rad.sv
// Same binary-to-stochastic converter as sng.sv, with one addition: a
// `reseed` input that forces the LFSR back to `seed` synchronously, exactly
// like stoch_pe_hybrid.sv's own internal feedback LFSR already does on
// `start` (see its line "else if (start) lfsr <= SEED;"). This file just
// extends that same already-proven pattern to the edge SNGs, which were the
// one place it was missing.
//
// WHY THIS MATTERS FOR RADIATION HARDENING SPECIFICALLY (not a bug in the
// original design -- the original never needed this):
// The plain sng.sv free-runs continuously, only resetting to `seed` on
// rst_n. For a single tile run that's completely fine -- the array doesn't
// care what phase of the LFSR sequence it starts from. But the wrapper-level
// re-run voting added in stoch_gemm_axis_hybrid_rad.sv depends on re-running
// the SAME tile twice and expecting a bit-identical answer in the
// fault-free case (see that file's header for why that's normally a sound,
// cheap SEU check). Without reseeding, the second internal run starts from
// wherever the LFSR happened to land after the first run finished --
// different LFSR phase, different finite-sample stochastic noise, different
// answer, even with zero faults. That shows up as a false-positive
// "mismatch" on every single tile, which is useless as a fault detector.
// Reseeding on `start` (here, wired to the array's existing `start` pulse)
// makes every internal re-run begin from byte-for-byte the same state,
// restoring the property the voting scheme needs.
// =============================================================================

module sng_rad #(
    parameter int WIDTH = 8
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              reseed,     // NEW: synchronous reseed to `seed`
    input  logic              enable,
    input  logic [WIDTH-1:0]  binary_in,
    input  logic [WIDTH-1:0]  seed,
    output logic              stoch_out
);

    logic [WIDTH-1:0] lfsr;
    logic             feedback;

    localparam logic [WIDTH-1:0] TAP_MASK =
        (WIDTH == 4)  ? WIDTH'('hC)     :
        (WIDTH == 5)  ? WIDTH'('h14)    :
        (WIDTH == 6)  ? WIDTH'('h30)    :
        (WIDTH == 7)  ? WIDTH'('h60)    :
        (WIDTH == 8)  ? WIDTH'('hB8)    :
        (WIDTH == 10) ? WIDTH'('h240)   :
        (WIDTH == 12) ? WIDTH'('hE08)   :
        (WIDTH == 16) ? WIDTH'('hD008)  :
                        WIDTH'((1 << (WIDTH-1)) | 1'b1);

    assign feedback = ^(lfsr & TAP_MASK);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= (seed == '0) ? {{(WIDTH-1){1'b0}}, 1'b1} : seed;
        end else if (reseed) begin
            lfsr <= (seed == '0) ? {{(WIDTH-1){1'b0}}, 1'b1} : seed;
        end else if (enable) begin
            lfsr <= {lfsr[WIDTH-2:0], feedback};
        end
    end

    assign stoch_out = enable ? (lfsr < binary_in) : 1'b0;

endmodule

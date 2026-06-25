`timescale 1ns/1ps

// =============================================================================
// tmr_vote3.sv
// Generic combinational 3-way bitwise majority voter for TMR'd registers.
//
// y[i] = majority(a[i], b[i], c[i])  for every bit position independently.
// mismatch is asserted whenever the three inputs are not all identical --
// i.e. whenever the voter actually had to do its job (a single bit somewhere
// flipped relative to the other two copies). This is exposed as telemetry:
// even when the vote corrects the error, a rising mismatch tells software
// "an SEU was caught here" without needing a JTAG probe or a stuck/wrong
// answer to notice.
//
// Scope note: this protects the THREE REGISTER COPIES from independent
// single-bit upsets (the dominant SEU failure mode in SRAM-based FPGA
// flip-flops/CRAM). It does NOT protect the shared combinational logic that
// computes the next-state value feeding all three copies -- a transient in
// that logic (SET) would be written identically into all three copies and
// the voter would see perfect agreement on a wrong value. Full SET coverage
// needs logic triplication too, which is a much bigger area bill; this voter
// targets the cost-effective FF-only TMR tier.
// =============================================================================

module tmr_vote3 #(
    parameter int W = 1
) (
    input  logic [W-1:0] a,
    input  logic [W-1:0] b,
    input  logic [W-1:0] c,
    output logic [W-1:0] y,
    output logic         mismatch
);

    assign y        = (a & b) | (b & c) | (a & c);
    assign mismatch = (a !== y) || (b !== y) || (c !== y);

endmodule

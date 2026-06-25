`timescale 1ns/1ps
module tb_tmr_vote3;
    logic [7:0] a, b, c, y;
    logic mismatch;
    int errors = 0;

    tmr_vote3 #(.W(8)) dut (.a(a), .b(b), .c(c), .y(y), .mismatch(mismatch));

    task automatic check(input [7:0] ta, tb, tc, input [7:0] exp_y, input exp_mm, input string name);
        a = ta; b = tb; c = tc;
        #1;
        if (y !== exp_y || mismatch !== exp_mm) begin
            $display("FAIL %s: a=%02h b=%02h c=%02h -> y=%02h mm=%0b (expected y=%02h mm=%0b)",
                      name, ta, tb, tc, y, mismatch, exp_y, exp_mm);
            errors++;
        end else begin
            $display("PASS %s: a=%02h b=%02h c=%02h -> y=%02h mm=%0b", name, ta, tb, tc, y, mismatch);
        end
    endtask

    initial begin
        // All agree -> no mismatch
        check(8'hA5, 8'hA5, 8'hA5, 8'hA5, 1'b0, "all_agree");
        // One bit flipped in 'a' only -> majority of b,c wins, mismatch flagged
        check(8'hA4, 8'hA5, 8'hA5, 8'hA5, 1'b1, "single_upset_in_a");
        // One bit flipped in 'b' only
        check(8'hA5, 8'hA1, 8'hA5, 8'hA5, 1'b1, "single_upset_in_b");
        // One bit flipped in 'c' only
        check(8'hA5, 8'hA5, 8'hE5, 8'hA5, 1'b1, "single_upset_in_c");
        // Multiple independent single-bit upsets across different copies,
        // non-overlapping bit positions -> still correctly recovered since
        // each bit position individually has 2-of-3 agreement
        check(8'b1010_0101, 8'b1110_0101, 8'b1010_0111, 8'b1010_0101, 1'b1, "multi_bit_nonoverlap");
        // Worst case: all three differ -> majority picks per-bit 2-of-3,
        // mismatch still correctly flagged so software knows to distrust this
        check(8'h00, 8'hFF, 8'h0F, 8'h0F, 1'b1, "all_three_differ");

        if (errors == 0) $display("\nALL TMR VOTER TESTS PASSED");
        else              $display("\n%0d TMR VOTER TEST(S) FAILED", errors);
        $finish;
    end
endmodule

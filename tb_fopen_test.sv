`timescale 1ns/1ps
// Minimal diagnostic: which $fopen form works in this xsim?
module tb_fopen_test;
  integer f;
  string  s;
  initial begin
    // --- Test 1: string LITERAL, absolute path -----------------------------
    f = $fopen("/home/caccolillo/BIT_SERIAL_STOCHASTIC/stoch_imgtest/meta_tb.txt", "r");
    $display("TEST1 literal-absolute        : fd=%0d  %s", f,
             (f>0)?"OPEN OK":"FAIL");
    if (f>0) $fclose(f);

    // --- Test 2: string VARIABLE holding the same literal ------------------
    s = "/home/caccolillo/BIT_SERIAL_STOCHASTIC/stoch_imgtest/meta_tb.txt";
    f = $fopen(s, "r");
    $display("TEST2 string-var              : fd=%0d  %s", f,
             (f>0)?"OPEN OK":"FAIL");
    if (f>0) $fclose(f);

    // --- Test 3: CONCATENATED string ---------------------------------------
    s = {"/home/caccolillo/BIT_SERIAL_STOCHASTIC/stoch_imgtest", "/meta_tb.txt"};
    f = $fopen(s, "r");
    $display("TEST3 concatenated string-var : fd=%0d  %s", f,
             (f>0)?"OPEN OK":"FAIL");
    $display("      (the concatenated string is: \"%s\")", s);
    if (f>0) $fclose(f);

    // --- Test 4: relative literal ------------------------------------------
    f = $fopen("meta_tb.txt", "r");
    $display("TEST4 relative literal        : fd=%0d  %s", f,
             (f>0)?"OPEN OK":"FAIL");
    if (f>0) $fclose(f);

    $finish;
  end
endmodule

## ============================================================================
## gemm_ultra96v2.xdc
## Timing / synthesis constraints for the STOCHASTIC GEMM accelerator
## (stoch_gemm_top) on the Avnet Ultra96-V2.
##
## Board  : Avnet Ultra96-V2
## Device : xczu3eg-sbva484-1-i   (Zynq UltraScale+ MPSoC, industrial grade)
## Tool   : Vivado 2022.3
##
## NOTE -- this XDC is written for stoch_gemm_top. Its ports are:
##   inputs : clk rst start k_len[*] a_bin[*] b_bin[*]
##   outputs: load_k k_idx[*] busy done c_flat[*]
##
## CLOCKING ON THE ULTRA96-V2
##   The Ultra96-V2 has no free-running user oscillator on PL pins; in a normal
##   system the PL fabric clock comes from the PS (pl_clk0). When this block is
##   integrated into a PS block design, the PS IP supplies and constrains the
##   clock -- in that case COMMENT OUT the create_clock below and let the
##   integrated constraints apply.
##
##   For STANDALONE / out-of-context synthesis of stoch_gemm_top (the usual way
##   to get a quick timing + utilisation read), the create_clock below IS used:
##   it defines the 200 MHz target on the 'clk' port so the timing report is
##   meaningful. This is the default, active configuration of this file.
## ============================================================================

## ---- Primary clock : 200 MHz target ----------------------------------------
## 5.000 ns period = 200 MHz. The stochastic PE is shallow logic (one XNOR + a
## counter increment), so this target is plausible -- but ONLY the post-route
## timing report confirms it. If WNS is negative after implementation, relax
## the period (e.g. 6.000 ns = 166.7 MHz) until WNS >= 0.
create_clock -name clk -period 5.000 [get_ports clk]

## ---- Input / output delay (standalone / OOC modelling) ---------------------
## These model interface timing for an out-of-context build. They assume the
## surrounding logic launches/captures on the same 'clk'. The 2.000 ns budget
## is a generic placeholder -- tighten to your actual interface once the block
## is integrated. When stoch_gemm_top sits inside a PS block design, REMOVE
## these and rely on the integrated constraints instead.
set_input_delay  -clock clk 2.000 \
    [get_ports {start rst {k_len[*]} {a_bin[*]} {b_bin[*]}}]
set_output_delay -clock clk 2.000 \
    [get_ports {load_k busy done {k_idx[*]} {c_flat[*]}}]

## ---- Reset -----------------------------------------------------------------
## 'rst' is a SYNCHRONOUS, active-high reset, driven from the same clock
## domain. It is a normal data input -- it gets the set_input_delay above and
## needs no false_path or special timing exception. Do NOT add an async
## reset synchroniser: the design is intentionally synchronous-reset.

## ---- Synthesis / implementation guidance -----------------------------------
## The stochastic array uses NO DSP48E2 -- each PE is an XNOR gate plus a
## counter, so multiplication is fabric logic, not DSP. Expect ~0 DSP usage and
## a LUT/FF-dominated footprint. Resource budget on the xczu3eg:
##   360 DSP48E2 | 70560 CLB LUT | 141120 CLB FF | 216 BRAM (36Kb)
## An 8x8 array (64 PEs) plus the SNG bank, skew staircases and control FSM is
## expected to be a few thousand LUTs/FFs -- a small fraction of the device.
##
## If LUT usage is higher than expected, check that the per-PE product-'1's
## counters (width grows with K*STREAM_LEN) are not being over-sized: CNTW in
## stoch_gemm_top is derived from KW and STREAM_LEN.

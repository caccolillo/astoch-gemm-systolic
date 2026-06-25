# ==============================================================================
# Multi-Cycle Path Constraints for stoch_gemm_axis_hybrid
# ==============================================================================
# Source-of-truth hierarchy (verified against RTL):
#   u_core           = stoch_gemm_top_hybrid (instance in stoch_gemm_axis_hybrid)
#     u_array        = stoch_systolic_array_hybrid
#       gen_pe_row[i].gen_pe_col[j].u_pe = stoch_pe_hybrid
#         c_flat     = per-PE final result register
#
# Filter strategy:
#   Every cell query restricts to REF_NAME =~ FD* (FDRE, FDSE, FDCE, FDPE)
#   to exclude Vivado-generated LUT cells whose names share a suffix with the
#   register (e.g. core_a_bin_reg[0]_i_10). Without this restriction Vivado
#   floods the log with [Constraints 18-401] "not a valid endpoint" warnings.
#
# Constraint #4 (s_axi_rdata) intentionally absent:
#   s_axi_rdata is driven by an always_comb mux (line 224 of the wrapper),
#   not registered. No *s_axi_rdata_reg* cells exist; the path from source
#   registers to the output port is combinational and short enough to meet
#   single-cycle timing without a multicycle.
#
# MAX_FANOUT section REMOVED:
#   Earlier attempt to constrain MAX_FANOUT=64 on FSM_onehot_state_reg
#   caused phys_opt_design to create ~96 replicas of a 6181-fanout signal.
#   On the xczu3eg (small device, ~70k LUTs, already ~80% utilised by the
#   22x22 systolic array), this drove vertical wire utilisation to 88.5%
#   and routing failed:
#       ERROR: [Route 35-5] Design is not routable as its vertical wire
#       utilisation is 88.50 %.
#   The lesson: aggressive register replication is a tool for large
#   underutilised devices, not for designs that already pack the chip.
#   The AXI-Stream register slice added in stoch_gemm_axis_wrapper_hybrid.vhd
#   does the same job (shortens the worst route) without spreading logic.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. AXI-Lite configuration registers (K_LEN, RES_PER_K)
# Written once before CTRL.START, held constant for the whole run.
# ------------------------------------------------------------------------------
set_multicycle_path -setup -from [get_cells -hierarchical -filter {(NAME =~ *reg_klen_reg* || NAME =~ *reg_res_per_k_reg*) && REF_NAME =~ FD*}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {(NAME =~ *reg_klen_reg* || NAME =~ *reg_res_per_k_reg*) && REF_NAME =~ FD*}] 1

# ------------------------------------------------------------------------------
# 2. Operand buffers -> core operand input registers
# core_kidx is stable for many cycles per term (SAR_BIT_LEN or residue phase),
# so the abuf/bbuf -> core_a_bin/core_b_bin mux+register path has 2-cycle slack.
# ------------------------------------------------------------------------------
set_multicycle_path -setup -from [get_cells -hierarchical -filter {(NAME =~ *abuf_reg* || NAME =~ *bbuf_reg*) && REF_NAME =~ FD*}] -to [get_cells -hierarchical -filter {(NAME =~ *core_a_bin_reg* || NAME =~ *core_b_bin_reg*) && REF_NAME =~ FD*}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {(NAME =~ *abuf_reg* || NAME =~ *bbuf_reg*) && REF_NAME =~ FD*}] -to [get_cells -hierarchical -filter {(NAME =~ *core_a_bin_reg* || NAME =~ *core_b_bin_reg*) && REF_NAME =~ FD*}] 1

# ------------------------------------------------------------------------------
# 3. PE result registers -> output streaming logic
# After core_done asserts, all N*N c_flat values are stable until the next
# core_start; the muxer reads them out at one PE per beat over many cycles.
# ------------------------------------------------------------------------------
set_multicycle_path -setup -from [get_cells -hierarchical -filter {NAME =~ *u_array*gen_pe_row*gen_pe_col*u_pe*c_flat_reg* && REF_NAME =~ FD*}] -to [get_cells -hierarchical -filter {(NAME =~ *reg_ocount_reg* || NAME =~ *out_idx_reg*) && REF_NAME =~ FD*}] 2
set_multicycle_path -hold  -from [get_cells -hierarchical -filter {NAME =~ *u_array*gen_pe_row*gen_pe_col*u_pe*c_flat_reg* && REF_NAME =~ FD*}] -to [get_cells -hierarchical -filter {(NAME =~ *reg_ocount_reg* || NAME =~ *out_idx_reg*) && REF_NAME =~ FD*}] 1

# ==============================================================================
# End of constraints (3 multicycle pairs)
# ==============================================================================

# =============================================================================
# gemm_multicycle.xdc
# Multicycle path constraints for the hybrid stochastic GEMM accelerator.
#
# These constraints inform Vivado that certain paths from AXI-Lite control
# registers to the GEMM FSM are functionally allowed to take multiple
# clock cycles. The registers are software-written once per job and remain
# stable while the FSM is running, so they do not need to meet the standard
# single-cycle setup requirement.
#
# Effect:
#   * Gives placement and routing more flexibility on these paths
#   * Releases timing pressure on paths that would otherwise be marginal
#     when scaling to larger N or higher clock frequencies
#   * Has no impact on functional behaviour (registers really are stable)
#
# Convention:
#   * -setup 4 -hold 3   (paired pattern; do NOT use -setup alone)
#   * The hold relaxation of N-1 compensates for the setup shift of N,
#     keeping the hold check at the same effective edge as setup
#
# Verify in batch after impl:
#   report_exceptions -multicycle_paths
#
# These constraints assume the standard cell-name pattern produced by the
# stoch_gemm_axis_hybrid wrapper. If you rename the wrapper or its
# registers, update the filter patterns below.
# =============================================================================

# ---------------------------------------------------------------------------
# K_LEN register -> GEMM FSM term counter
# Written once per tile by the userspace test app, then constant while the
# FSM is running. The FSM samples it every cycle to compare against k_ctr.
# ---------------------------------------------------------------------------
set_multicycle_path 4 -setup \
    -from [get_cells -hier -filter {NAME =~ */reg_klen_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ */u_core/*_reg[*]}]
set_multicycle_path 3 -hold  \
    -from [get_cells -hier -filter {NAME =~ */reg_klen_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ */u_core/*_reg[*]}]

# ---------------------------------------------------------------------------
# RES_PER_K register -> GEMM FSM residue-stage cycle counter
# Same pattern: written once per tile by software (replaces the original
# hardware divider that was blocking timing closure).
# ---------------------------------------------------------------------------
set_multicycle_path 4 -setup \
    -from [get_cells -hier -filter {NAME =~ */reg_res_per_k_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ */u_core/*_reg[*]}]
set_multicycle_path 3 -hold  \
    -from [get_cells -hier -filter {NAME =~ */reg_res_per_k_reg[*]}] \
    -to   [get_cells -hier -filter {NAME =~ */u_core/*_reg[*]}]

# ---------------------------------------------------------------------------
# IRQ_EN bit -> IRQ output port
# Slow-changing AXI-Lite bit; gates a single output. Multicycle relax is
# safe because the receiving side (the PS interrupt controller) samples
# the IRQ asynchronously.
# ---------------------------------------------------------------------------
set_multicycle_path 4 -setup \
    -from [get_cells -hier -filter {NAME =~ */reg_irqen_reg}] \
    -to   [get_ports irq]
set_multicycle_path 3 -hold  \
    -from [get_cells -hier -filter {NAME =~ */reg_irqen_reg}] \
    -to   [get_ports irq]

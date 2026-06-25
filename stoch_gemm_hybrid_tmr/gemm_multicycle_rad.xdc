# ==============================================================================
# gemm_multicycle_rad.xdc -- addendum for the radiation-hardened variant
# ==============================================================================
# Apply THIS FILE IN ADDITION TO gemm_multicycle.xdc when building the _rad
# variant (stoch_gemm_axis_hybrid_rad + stoch_gemm_top_hybrid_rad +
# stoch_systolic_array_hybrid_rad + sng_rad). Nothing here replaces or
# weakens the existing multicycle constraints; the three pairs in
# gemm_multicycle.xdc still apply unchanged.
#
# WHAT THIS FILE DOES NOT DO, AND WHY:
#   This is deliberately NOT a turnkey "drop in and route" constraint set.
#   It is commented-out guidance plus one real constraint (false paths
#   across the AXI-Lite TMR voters, which is safe and unconditionally
#   correct). The Pblock placement directives for state_a/b/c and
#   bit_ctr_a/b/c are left commented out on purpose -- see the warning
#   below. UNCOMMENT AND TUNE THESE YOURSELF after you've measured where
#   you actually stand on routing/utilisation with the _rad build, the same
#   way the existing MAX_FANOUT lesson in gemm_multicycle.xdc was learned
#   the hard way on this exact device.
#
# *** WARNING, READ BEFORE UNCOMMENTING ANYTHING BELOW ***
# The xczu3eg is already ~80% LUT-utilised by the 22x22 PE array at N=22,
# and a prior MAX_FANOUT=64 replication attempt on this exact FSM's state
# register blew vertical wire utilisation to 88.5% and failed routing
# (Route 35-5). Tripling state_a/b/c and bit_ctr_a/b/c does NOT cost 3x the
# *registers* (they're tiny -- a handful of FFs each), but each copy
# regenerates its OWN full fanout tree to every PE control input (up to
# ~6181 endpoints per signal at N=22, same MAX_FANOUT=128 attribute as the
# original). That's 3 separate high-fanout distribution trees instead of 1,
# competing for the same routing resources that are already tight. This
# needs its OWN dedicated 300MHz timing closure pass -- do not assume it
# closes on the first attempt just because the un-tripled version did.
#
# A Pblock that physically separates state_a/state_b/state_c (and the
# bit_ctr equivalents) is the standard technique to stop a single SEU's
# physical blast radius (or a routing congestion hotspot) from being able
# to influence more than one of the three copies, AND to give each copy's
# fanout tree its own physical real estate. But on a device this tight, a
# poorly sized/placed Pblock can just as easily CAUSE the routing failure
# instead of preventing one. Recommended approach:
#   1. Build and time-close the _rad variant WITHOUT any Pblock first.
#   2. Look at the placed design in Vivado's device view -- where did the
#      three copies land relative to each other and to the PE array?
#   3. Only if they're landing inconveniently close together (defeating the
#      point of TMR) or routing congestion is the limiter, carve out three
#      small, deliberately-separated Pblocks (e.g. one per SLR-equivalent
#      region or one per clock region) sized just large enough for one
#      copy's logic + its fanout buffers, and iterate from there.
# This is exactly the kind of utilisation-dependent, iterative call that
# needs your own validation against the live placed/routed design, not a
# constraint written ahead of time without seeing the floorplan.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. AXI-Lite TMR voters (aw_state_a/b/c, ar_state_a/b/c) -- SAFE, REAL
#    CONSTRAINT, not guidance. These are 2-bit FSMs with no meaningful
#    fanout problem (unlike the core FSM's state/bit_ctr), so there's no
#    placement concern here -- just tell the tools the three copies are
#    intentionally redundant logic, not something to optimise back into one
#    copy. (Vivado's default synthesis settings will NOT do this on their
#    own for explicitly triplicated registers fed by a generate block, but
#    KEEP_HIERARCHY belts-and-braces it against any future synthesis
#    strategy change.)
# ------------------------------------------------------------------------------
set_property KEEP_HIERARCHY TRUE [get_cells -hierarchical -filter {NAME =~ *g_tmr_aw* || NAME =~ *g_tmr_ar*}]

# ------------------------------------------------------------------------------
# 2. Core FSM TMR (state_a/b/c, bit_ctr_a/b/c) -- same KEEP_HIERARCHY
#    protection, no placement constraint. This much is safe to apply
#    unconditionally; it just stops synthesis from collapsing the
#    triplication back down (defeating the whole point) -- it does NOT
#    affect routing/utilisation, unlike a Pblock would.
# ------------------------------------------------------------------------------
set_property KEEP_HIERARCHY TRUE [get_cells -hierarchical -filter {NAME =~ *u_core*state_a_reg* || NAME =~ *u_core*state_b_reg* || NAME =~ *u_core*state_c_reg* || NAME =~ *u_core*bit_ctr_a_reg* || NAME =~ *u_core*bit_ctr_b_reg* || NAME =~ *u_core*bit_ctr_c_reg*}]

# ------------------------------------------------------------------------------
# 3. OPTIONAL Pblock guidance -- COMMENTED OUT, validate before using.
#    Uncomment and adjust the SLICE range to whatever the actual placed
#    floorplan suggests once you've done step 1-2 above. The ranges below
#    are illustrative only (rough thirds of a generic clock region) and
#    have NOT been checked against the xczu3eg's real Pblock-eligible
#    geometry -- get the real SLICE/RAMB/DSP ranges from Vivado's device
#    view (Tools -> Pblock or simply right-click a placed cell -> "Find
#    nearby cells" to scope a sensible boundary) before trusting these.
# ------------------------------------------------------------------------------
# create_pblock pblock_state_a
# add_cells_to_pblock [get_pblocks pblock_state_a] [get_cells -hierarchical -filter {NAME =~ *u_core*state_a_reg* || NAME =~ *u_core*bit_ctr_a_reg*}]
# resize_pblock [get_pblocks pblock_state_a] -add {SLICE_X0Y0:SLICE_X40Y59}
#
# create_pblock pblock_state_b
# add_cells_to_pblock [get_pblocks pblock_state_b] [get_cells -hierarchical -filter {NAME =~ *u_core*state_b_reg* || NAME =~ *u_core*bit_ctr_b_reg*}]
# resize_pblock [get_pblocks pblock_state_b] -add {SLICE_X41Y0:SLICE_X80Y59}
#
# create_pblock pblock_state_c
# add_cells_to_pblock [get_pblocks pblock_state_c] [get_cells -hierarchical -filter {NAME =~ *u_core*state_c_reg* || NAME =~ *u_core*bit_ctr_c_reg*}]
# resize_pblock [get_pblocks pblock_state_c] -add {SLICE_X81Y0:SLICE_X120Y59}

# ------------------------------------------------------------------------------
# 4. Vote sequencer's run-to-run buffers (buf_a/buf_b/buf_c, RESULT_W bits
#    each) -- no special constraint needed. These are NOT triplicated logic
#    in the TMR sense (no voter compares them combinationally on every
#    cycle); they're just three large shift-in capture registers used
#    sequentially across the (slow, multi-hundred-cycle) tile re-run
#    latency budget, so ordinary multicycle treatment is enough if timing
#    analysis flags them -- add a pair here using the same pattern as
#    constraint #3 in gemm_multicycle.xdc if Vivado's report_timing shows a
#    violation, which is not expected given how lightly loaded these paths
#    are relative to the existing c_flat -> reg_ocount path.
# ==============================================================================

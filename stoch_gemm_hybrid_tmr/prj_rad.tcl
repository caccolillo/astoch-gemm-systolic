# =============================================================================
# prj_rad.tcl
# Vivado project for the RADIATION-HARDENED AXI-wrapped stochastic GEMM.
#
# Drop-in replacement for prj.tcl.  All source files are in the same
# directory as this script (no sub-folders).
#
# Flow phases (identical structure to prj.tcl):
#   PHASE 1  -- Create the empty project
#   PHASE 2  -- Add all HDL sources + generate _rad VHDL wrapper + add XDCs
#   PHASE 3  -- update_compile_order
#   PHASE 4  -- Patch bd.tcl to reference stoch_gemm_axis_wrapper_hybrid_rad
#   PHASE 5  -- Source patched bd.tcl (creates the block design)
#   PHASE 5b -- Sanity-check PS clock (READ ONLY)
#   PHASE 6  -- Validate BD + generate output products
#   PHASE 7  -- make_wrapper, add to project, set as top
#   PHASE 8  -- Synthesis + reports
#   PHASE 9  -- Implementation + write_bitstream (single launch) + reports
#   PHASE 10 -- Write XSA for PetaLinux
#
# Required files (all in the same directory as this script):
#   -- unchanged from original project --
#   sng.sv
#   stoch_pe_hybrid.sv
#   stoch_gemm_axis_wrapper_hybrid.vhd   (patched in PHASE 2 to produce _rad variant)
#   bd.tcl                               (patched in PHASE 4)
#   gemm_multicycle.xdc
#   -- new rad-hardening files --
#   tmr_vote3.sv
#   sng_rad.sv
#   stoch_systolic_array_hybrid_rad.sv
#   stoch_gemm_top_hybrid_rad.sv
#   stoch_gemm_axis_hybrid_rad.sv
#   gemm_multicycle_rad.xdc
#   tb_radhard_fault_injection.sv
#   tb_radhard_axis_fault_injection.sv
#   tb_radhard_new_features.sv
#
# Usage (run from any directory):
#   vivado -mode batch -source /path/to/prj_rad.tcl
#
# Array sizing is controlled by the VHDL generic defaults in the
# auto-generated stoch_gemm_axis_wrapper_hybrid_rad.vhd (written to the
# project directory in PHASE 2):
#   N = 22, K_SAR_BITS = 8, SAR_BIT_LEN = 32, STREAM_LEN_RESIDUE = 65536
# To change sizing, edit stoch_gemm_axis_wrapper_hybrid.vhd and re-run.
# =============================================================================

# ---- Paths and settings -----------------------------------------------------
set origin_dir [file dirname [info script]]
set src_dir    $origin_dir
set proj_name  gemm_rad_axi
set proj_dir   [file join $origin_dir $proj_name]
set part       xczu3eg-sbva484-1-i
set board_part {avnet.com:ultra96v2:part0:1.2}

# Mirror of VHDL generic defaults (banner only — not used for synthesis).
set N_GEMM             22
set K_SAR_BITS         8
set SAR_BIT_LEN        32
set STREAM_LEN_RESIDUE 65536
set KBUF_MAX           16

# Optional command-line overrides.
if {[info exists ::argv]} {
    for {set i 0} {$i < [llength $::argv]} {incr i} {
        set arg [lindex $::argv $i]
        switch -- $arg {
            --src_dir    { incr i; set src_dir    [lindex $::argv $i] }
            --proj       { incr i; set proj_name  [lindex $::argv $i] }
            --part       { incr i; set part       [lindex $::argv $i] }
            --board_part { incr i; set board_part [lindex $::argv $i] }
            default      {}
        }
    }
}

set proj_dir    [file join $origin_dir $proj_name]
set reports_dir [file join $proj_dir reports]

puts "--------------------------------------------------------------------"
puts " prj_rad.tcl  --  RADIATION-HARDENED build"
puts "   project name : $proj_name"
puts "   project dir  : $proj_dir"
puts "   source dir   : $src_dir"
puts "   part         : $part"
puts "   board_part   : $board_part"
puts " --- GEMM sizing (VHDL generic defaults) ---"
puts "   N (array)              : $N_GEMM"
puts "   K_SAR_BITS             : $K_SAR_BITS"
puts "   SAR_BIT_LEN            : $SAR_BIT_LEN"
puts "   STREAM_LEN_RESIDUE     : $STREAM_LEN_RESIDUE"
puts " --- Rad-hardening (all ON by default) ---"
puts "   RAD_VOTE_RUNS, RAD_TMR_FSM, RAD_WATCHDOG, RAD_TMR_AXIL,"
puts "   RAD_TMR_CFG, RAD_BIST, RAD_CRC_TRAILER"
puts " --- Flow ---"
puts "   project -> synth -> impl -> bitstream -> XSA + reports"
puts "--------------------------------------------------------------------"

# ---- Pre-flight: verify every required file exists -------------------------
set required_files {
    sng.sv
    stoch_pe_hybrid.sv
    stoch_gemm_axis_wrapper_hybrid.vhd
    bd.tcl
    gemm_multicycle.xdc
    tmr_vote3.sv
    sng_rad.sv
    stoch_systolic_array_hybrid_rad.sv
    stoch_gemm_top_hybrid_rad.sv
    stoch_gemm_axis_hybrid_rad.sv
    gemm_multicycle_rad.xdc
    tb_radhard_fault_injection.sv
    tb_radhard_axis_fault_injection.sv
    tb_radhard_new_features.sv
}
foreach f $required_files {
    set path [file join $src_dir $f]
    if {![file exists $path]} {
        puts "ERROR: required source not found: $path"
        exit 1
    }
}
puts "INFO: all required source files present"

# ===========================================================================
# PHASE 1 -- Create the empty project
# ===========================================================================
puts "\n==> PHASE 1: creating empty project"

if {[file exists $proj_dir]} {
    puts "INFO: removing existing project directory $proj_dir"
    file delete -force $proj_dir
}
create_project $proj_name $proj_dir -part $part -force
file mkdir $reports_dir

if {[catch {set_property board_part $board_part [current_project]} err]} {
    puts "WARN: could not set board_part '$board_part' -- continuing without it"
}

set_property target_language    VHDL           [current_project]
set_property simulator_language Mixed          [current_project]
set_property default_lib        xil_defaultlib [current_project]

# ===========================================================================
# PHASE 2 -- Add all HDL sources
#
# vs. the baseline prj.tcl:
#   REMOVED  stoch_systolic_array_hybrid.sv  -> replaced by _rad
#   REMOVED  stoch_gemm_top_hybrid.sv        -> replaced by _rad
#   REMOVED  stoch_gemm_axis_hybrid.sv       -> replaced by _rad
#   KEPT     sng.sv, stoch_pe_hybrid.sv      (unchanged)
#   ADDED    tmr_vote3.sv, sng_rad.sv, *_rad.sv
#
# The _rad VHDL wrapper is generated here (PHASE 2b) rather than kept as a
# hand-maintained file, so the VHDL generics and port list have a single
# source of truth in stoch_gemm_axis_wrapper_hybrid.vhd.
#
# Both XDC files are added: gemm_multicycle.xdc (baseline multicycle paths)
# and gemm_multicycle_rad.xdc (KEEP_HIERARCHY on TMR registers).
# ===========================================================================
puts "\n==> PHASE 2: adding HDL sources"

set sv_files [list \
    [file normalize [file join $src_dir sng.sv]] \
    [file normalize [file join $src_dir stoch_pe_hybrid.sv]] \
    [file normalize [file join $src_dir tmr_vote3.sv]] \
    [file normalize [file join $src_dir sng_rad.sv]] \
    [file normalize [file join $src_dir stoch_systolic_array_hybrid_rad.sv]] \
    [file normalize [file join $src_dir stoch_gemm_top_hybrid_rad.sv]] \
    [file normalize [file join $src_dir stoch_gemm_axis_hybrid_rad.sv]] \
]
add_files -norecurse -fileset sources_1 $sv_files
foreach f $sv_files {
    set_property file_type SystemVerilog [get_files [file tail $f]]
}
puts "INFO: added [llength $sv_files] SystemVerilog source files"

# PHASE 2b -- Generate stoch_gemm_axis_wrapper_hybrid_rad.vhd.
#
# The baseline VHDL file defines:
#   entity    stoch_gemm_axis_wrapper_hybrid
#   component stoch_gemm_axis_hybrid       (inner SV wrapper)
#   u_axis  : stoch_gemm_axis_hybrid       (instantiation)
#
# We need:
#   entity    stoch_gemm_axis_wrapper_hybrid_rad
#   component stoch_gemm_axis_hybrid_rad
#   u_axis  : stoch_gemm_axis_hybrid_rad
#
# Two-pass substitution on each line.  The two target strings share no
# common substring so the passes are independent and commute:
#   "stoch_gemm_axis_wrapper_hybrid" is NOT a superstring of
#   "stoch_gemm_axis_hybrid" (there is "_wrapper_" between "axis_" and
#   "hybrid"), so pass 2 cannot accidentally re-match what pass 1 produced.
puts "\n==> PHASE 2b: generating stoch_gemm_axis_wrapper_hybrid_rad.vhd"

set base_vhd [file normalize [file join $src_dir stoch_gemm_axis_wrapper_hybrid.vhd]]
set rad_vhd  [file normalize [file join $proj_dir stoch_gemm_axis_wrapper_hybrid_rad.vhd]]

set fin  [open $base_vhd "r"]
set fout [open $rad_vhd  "w"]
set subs 0
while {[gets $fin line] >= 0} {
    # Pass 1: rename the VHDL entity / architecture.
    #   stoch_gemm_axis_wrapper_hybrid  ->  stoch_gemm_axis_wrapper_hybrid_rad
    set n [regsub -all -- \
        "stoch_gemm_axis_wrapper_hybrid" $line \
        "stoch_gemm_axis_wrapper_hybrid_rad" line]
    incr subs $n
    # Pass 2: rename the inner SV component declaration and instantiation.
    #   stoch_gemm_axis_hybrid  ->  stoch_gemm_axis_hybrid_rad
    # Safe because stoch_gemm_axis_wrapper_hybrid_rad (from pass 1) does not
    # contain the substring stoch_gemm_axis_hybrid.
    set m [regsub -all -- \
        "stoch_gemm_axis_hybrid" $line \
        "stoch_gemm_axis_hybrid_rad" line]
    incr subs $m
    puts $fout $line
}
close $fin
close $fout
puts "INFO: wrote [file tail $rad_vhd] ($subs substitutions)"

add_files -norecurse -fileset sources_1 $rad_vhd
set_property file_type VHDL [get_files [file tail $rad_vhd]]
puts "INFO: added [file tail $rad_vhd] to sources_1"

# Both XDC files, both PROCESSING_ORDER LATE.
foreach xdc_f {gemm_multicycle.xdc gemm_multicycle_rad.xdc} {
    set xdc_path [file normalize [file join $src_dir $xdc_f]]
    add_files -norecurse -fileset constrs_1 $xdc_path
    set_property PROCESSING_ORDER LATE [get_files $xdc_f]
    puts "INFO: added XDC $xdc_f (PROCESSING_ORDER=LATE)"
}

# Rad testbenches in sim_1.
foreach tb_f {tb_radhard_fault_injection.sv \
              tb_radhard_axis_fault_injection.sv \
              tb_radhard_new_features.sv} {
    set tb_path [file normalize [file join $src_dir $tb_f]]
    add_files -norecurse -fileset sim_1 $tb_path
    set_property file_type SystemVerilog [get_files $tb_f]
    puts "INFO: added sim testbench $tb_f"
}
# Default sim top = fast standalone core TB (no AXI overhead).
set_property top tb_radhard_fault_injection [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1000ms} \
    -objects [get_filesets sim_1]

# ===========================================================================
# PHASE 3 -- update_compile_order so all module references resolve
# ===========================================================================
puts "\n==> PHASE 3: updating compile order"
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Confirm the rad VHDL wrapper is visible to Vivado before bd.tcl runs.
set chk [get_files -filter "FILE_TYPE == \"VHDL\" && NAME =~ *wrapper_hybrid_rad*"]
if {[llength $chk] == 0} {
    puts "ERROR: stoch_gemm_axis_wrapper_hybrid_rad.vhd not found in sources_1 after compile-order update"
    exit 1
}
puts "INFO: rad VHDL wrapper confirmed in sources_1: [file tail [lindex $chk 0]]"

# ===========================================================================
# PHASE 4 -- Patch bd.tcl to reference stoch_gemm_axis_wrapper_hybrid_rad
#
# bd.tcl already contains "stoch_gemm_axis_wrapper_hybrid" in two places:
#   line ~165  list_check_mods (module-existence guard)
#   line ~297  set block_name  (create_bd_cell -reference)
#
# Strategy: protect any already-_rad strings with a marker, then replace
# all remaining "stoch_gemm_axis_wrapper_hybrid" with the _rad variant,
# then also replace bare "stoch_gemm_axis_wrapper" (without _hybrid) for
# defensive coverage -- identical to what prj.tcl does but targeting _rad.
# ===========================================================================
puts "\n==> PHASE 4: patching bd.tcl to reference stoch_gemm_axis_wrapper_hybrid_rad"

set bd_src   [file normalize [file join $src_dir bd.tcl]]
set bd_patch [file normalize [file join $proj_dir bd_rad.tcl]]

set fin  [open $bd_src   "r"]
set fout [open $bd_patch "w"]
set subs 0
while {[gets $fin line] >= 0} {
    # Protect strings already ending in _rad (defensive; won't exist in the
    # original bd.tcl, but makes the script safely re-runnable).
    regsub -all -- "stoch_gemm_axis_wrapper_hybrid_rad" $line "__RAD_MARKER__" line
    # Replace existing _hybrid occurrences and bare _wrapper occurrences.
    regsub -all -- "stoch_gemm_axis_wrapper_hybrid" $line "__HYBRID_MARKER__" line
    set n [regsub -all -- "stoch_gemm_axis_wrapper" $line \
               "stoch_gemm_axis_wrapper_hybrid_rad" line]
    regsub -all -- "__HYBRID_MARKER__" $line "stoch_gemm_axis_wrapper_hybrid_rad" line
    regsub -all -- "__RAD_MARKER__"    $line "stoch_gemm_axis_wrapper_hybrid_rad" line
    incr subs $n
    puts $fout $line
}
close $fin
close $fout
puts "INFO: wrote [file tail $bd_patch] ($subs token substitutions)"

# Quick sanity-check: confirm the two known reference sites were patched.
set chk_bd [open $bd_patch "r"]
set bd_content [read $chk_bd]
close $chk_bd
if {![string match "*stoch_gemm_axis_wrapper_hybrid_rad*" $bd_content]} {
    puts "ERROR: bd_rad.tcl does not contain 'stoch_gemm_axis_wrapper_hybrid_rad' -- patch failed"
    exit 1
}
if {[string match "*stoch_gemm_axis_wrapper_hybrid\[^_\]*" $bd_content]} {
    puts "WARN: bd_rad.tcl may still contain unpatched 'stoch_gemm_axis_wrapper_hybrid' occurrences"
}
puts "INFO: bd_rad.tcl patch verified"

# ===========================================================================
# PHASE 5 -- Source the patched bd.tcl to create the block design
# ===========================================================================
puts "\n==> PHASE 5: sourcing bd_rad.tcl to create block design"

if {[catch {source $bd_patch} bd_err]} {
    puts "ERROR: sourcing bd_rad.tcl failed: $bd_err"
    exit 1
}

set bd_designs [get_bd_designs]
if {[llength $bd_designs] == 0} {
    puts "ERROR: bd_rad.tcl did not create a block design"
    exit 1
}
set current_bd [current_bd_design]
if {$current_bd ne ""} {
    set bd_design [get_property NAME $current_bd]
} else {
    set bd_design [lindex $bd_designs 0]
}
puts "INFO: block design created: '$bd_design'"

# ===========================================================================
# PHASE 5b -- Sanity-check the PS clock (READ ONLY).
# Target: pl_clk0 = 250 MHz.  Never call set_property on the PS cell here;
# doing so triggers BD revalidation that can silently alter MIO/DDR/clock
# settings and brick FSBL boot.
# ===========================================================================
puts "\n==> PHASE 5b: verifying PS clock"

set expected_pl_clk 250.0
set tolerance_mhz   1.0
set ps_cell [get_bd_cells -quiet -filter "VLNV =~ *zynq_ultra_ps_e*"]
if {[llength $ps_cell] == 0} {
    puts "WARN: ZynqMP PS cell not found in BD -- skipping clock check"
} else {
    set clk [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $ps_cell]
    puts "INFO: PS pl_clk0 = $clk MHz (target $expected_pl_clk MHz)"
    if {abs($clk - $expected_pl_clk) > $tolerance_mhz} {
        puts "ERROR: pl_clk0 = $clk MHz, expected ~$expected_pl_clk MHz."
        puts "       Open the BD in the GUI, set PL Fabric Clock 0 to $expected_pl_clk MHz,"
        puts "       re-save, and re-run this script."
        exit 1
    }
}

# ===========================================================================
# PHASE 6 -- Validate the BD and generate all output products
# ===========================================================================
puts "\n==> PHASE 6: validating BD and generating output products"

save_bd_design
if {[catch {validate_bd_design} err]} {
    puts "WARN: validate_bd_design: $err"
}

set bd_files [get_files -filter "FILE_TYPE == \"Block Designs\""]
if {[llength $bd_files] == 0} {
    puts "ERROR: no Block Design file found in project"
    exit 1
}
set bd_file [lindex $bd_files 0]
puts "INFO: BD file: $bd_file"

generate_target all [get_files $bd_file]
puts "INFO: output products generated"

# ===========================================================================
# PHASE 7 -- Make the HDL wrapper for the BD, add it to the project,
#            and set it as the top-level module
# ===========================================================================
puts "\n==> PHASE 7: making BD HDL wrapper and setting as top"

# target_language is VHDL (set in PHASE 1) so make_wrapper emits a .vhd file.
set wrapper_out [make_wrapper -files [list $bd_file] -top -force]
if {[llength $wrapper_out] == 0} {
    puts "ERROR: make_wrapper returned empty -- check BD for errors"
    exit 1
}
set wrapper [lindex $wrapper_out 0]
puts "INFO: make_wrapper produced: $wrapper"

add_files -norecurse $wrapper
update_compile_order -fileset sources_1

set wrapper_name [file rootname [file tail $wrapper]]
set_property top $wrapper_name [get_filesets sources_1]
update_compile_order -fileset sources_1

set actual_top [get_property top [get_filesets sources_1]]
if {$actual_top ne $wrapper_name} {
    puts "ERROR: top is '$actual_top', expected '$wrapper_name'"
    exit 1
}
puts "INFO: top module set to '$wrapper_name' (confirmed)"

# ===========================================================================
# Helper: write timing/utilisation reports after synth or impl
# ===========================================================================
proc write_run_reports {run_name dir} {
    if {$run_name eq "synth_1"} {
        open_run synth_1 -name synth_1
    } else {
        open_run impl_1 -name impl_1
    }
    set prefix [file join $dir $run_name]
    report_timing_summary -file ${prefix}_timing_summary.rpt -warn_on_violation
    report_timing -setup -max_paths 20 -path_type full_clock \
        -file ${prefix}_timing_setup_worst20.rpt
    report_timing -hold  -max_paths 20 -path_type full_clock \
        -file ${prefix}_timing_hold_worst20.rpt
    report_utilization              -file ${prefix}_utilization.rpt
    report_utilization -hierarchical -file ${prefix}_utilization_hier.rpt
    report_clock_interaction        -file ${prefix}_clock_interaction.rpt
    if {$run_name eq "impl_1"} {
        report_drc   -file ${prefix}_drc.rpt
        report_power -file ${prefix}_power.rpt
    }
    close_design
    # Print WNS line to console
    puts "------------------------------------------------------------------"
    puts " $run_name timing summary:"
    set f [open ${prefix}_timing_summary.rpt r]
    set hit 0
    while {[gets $f line] >= 0} {
        if {[regexp {WNS\(ns\)} $line]} { set hit 1; continue }
        if {$hit && [regexp {^\s*\-?\d+\.\d+\s+\-?\d+\.\d+} $line]} {
            puts "   $line"; break
        }
    }
    close $f
    puts "------------------------------------------------------------------"
}

# ===========================================================================
# PHASE 8 -- Synthesis
# ===========================================================================
puts "\n==> PHASE 8: launching synthesis"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synthesis failed -- check $reports_dir and the Vivado log"
    exit 1
}
puts "INFO: synthesis complete"
write_run_reports synth_1 $reports_dir

# ===========================================================================
# PHASE 9 -- Implementation + write_bitstream (single launch)
#
# Start with Performance_ExtraTimingOpt (same as baseline prj.tcl).
# If you see negative WNS, switch to the commented line below --
# Performance_ExplorePostRoutePhysOpt is the strategy that closed timing
# at 285 MHz on the baseline silicon.  The _rad additions (~100 LUT,
# ~90 FF for TMR/CRC/BIST) are unlikely to disturb timing, but if they do:
#   1. Uncomment Performance_ExplorePostRoutePhysOpt below.
#   2. Enable the Pblock guidance in gemm_multicycle_rad.xdc after
#      checking it against your placed floorplan.
# ===========================================================================
puts "\n==> PHASE 9: launching implementation + write_bitstream"
# set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property strategy Performance_ExtraTimingOpt           [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set impl_prog [get_property PROGRESS [get_runs impl_1]]
puts "INFO: impl_1 PROGRESS='$impl_prog'"
if {$impl_prog != "100%"} {
    puts "ERROR: implementation or bitstream step failed"
    exit 1
}
puts "INFO: implementation + bitstream complete"
write_run_reports impl_1 $reports_dir

set bit_path [file join $proj_dir $proj_name.runs impl_1 ${wrapper_name}.bit]
if {[file exists $bit_path]} {
    puts "INFO: bitstream confirmed at $bit_path"
} else {
    puts "ERROR: bitstream not found at expected path $bit_path"
    exit 1
}

# ===========================================================================
# PHASE 10 -- Write XSA for PetaLinux
# ===========================================================================
puts "\n==> PHASE 10: writing .xsa"
set xsa_path [file join $proj_dir ${proj_name}.xsa]
if {[catch {write_hw_platform -fixed -include_bit -force $xsa_path} err]} {
    puts "ERROR: write_hw_platform failed: $err"
    exit 1
}
if {![file exists $xsa_path]} {
    puts "ERROR: XSA not found at $xsa_path after write_hw_platform"
    exit 1
}
puts "INFO: XSA written to $xsa_path ([file size $xsa_path] bytes)"

puts "\n=================================================================="
puts " DONE  --  RADIATION-HARDENED BUILD"
puts ""
puts " Project   : $proj_dir/$proj_name.xpr"
puts " BD design : $bd_design"
puts " Top       : $wrapper_name"
puts " Array     : ${N_GEMM}x${N_GEMM} ([expr {$N_GEMM * $N_GEMM}] PEs)"
puts " Reports   : $reports_dir/"
puts " Bitstream : $bit_path"
puts " XSA       : $xsa_path"
puts ""
puts " Rad-hardening active (all default ON):"
puts "   Core FSM TMR + bit_ctr TMR         RAD_TMR_FSM=1"
puts "   Watchdog on FSM stalls              RAD_WATCHDOG=1"
puts "   AXI-Lite FSM TMR                   RAD_TMR_AXIL=1"
puts "   Config register TMR (K_LEN etc.)   RAD_TMR_CFG=1"
puts "   Temporal re-run vote (x3)          RAD_VOTE_RUNS=3"
puts "   CRC32 trailer on AXI-S output      RAD_CRC_TRAILER=1"
puts "   BIST (CTRL bit 2)                  RAD_BIST=1"
puts ""
puts " See RADIATION_HARDENING_NOTES.md for fault register map,"
puts " CRC32 Python verifier, and BIST procedure."
puts ""
puts " To rebuild:  vivado -mode batch -source prj_rad.tcl"
puts "=================================================================="

# =============================================================================
# prj_gemm_hybrid_axi.tcl
# Full Vivado project for the AXI-wrapped HYBRID stochastic GEMM.
#
# Flow phases (each phase depends on the previous one):
#
#   PHASE 1 -- Create the empty project
#   PHASE 2 -- Add ALL HDL sources (SV + VHDL + testbench + XDC)
#   PHASE 3 -- update_compile_order so Vivado has indexed everything
#   PHASE 4 -- Patch bd.tcl (substitute hybrid wrapper module name)
#   PHASE 5 -- Source patched bd.tcl, which creates the block design
#   PHASE 5b -- Override GEMM generics (e.g. N=10) on the BD cell
#   PHASE 6 -- Validate + generate output products
#   PHASE 7 -- Make VHDL wrapper for BD, add to project, set as top
#   PHASE 8 -- Run synthesis + write timing/utilisation reports
#   PHASE 9 -- Run implementation + write timing/utilisation reports
#   PHASE 10 -- Write bitstream + XSA
#
# Required source files alongside this script:
#   sng.sv
#   stoch_pe_hybrid.sv
#   stoch_systolic_array_hybrid.sv
#   stoch_gemm_top_hybrid.sv
#   stoch_gemm_axis_hybrid.sv
#   stoch_gemm_axis_wrapper_hybrid.vhd
#   tb_stoch_gemm_hybrid.sv
#   bd.tcl                              (the original block-design script)
#   gemm_multicycle.xdc                 (multicycle path exceptions)
#
# Usage:
#   vivado -mode batch -source prj_gemm_hybrid_axi.tcl
#       -> full flow: project -> synth -> impl -> bitstream -> XSA + reports
#
# Array sizing is NOT a command-line argument. The current values come
# from VHDL generic defaults in stoch_gemm_axis_wrapper_hybrid.vhd:
#   N = 22, K_SAR_BITS = 8, SAR_BIT_LEN = 32,
#   STREAM_LEN_RESIDUE = 65536, KBUF_MAX = 64
#
# To retarget, edit the VHDL file and re-run this script.
# =============================================================================

# ---- Defaults --------------------------------------------------------------
set origin_dir [file dirname [info script]]
set src_dir    $origin_dir
set proj_name  gemm_hybrid_axi
set proj_dir   [file join $origin_dir $proj_name]
set part       xczu3eg-sbva484-1-i
set board_part {avnet.com:ultra96v2:part0:1.2}

# GEMM array sizing - these mirror the VHDL generic defaults in
# stoch_gemm_axis_wrapper_hybrid.vhd. They are NOT used to override the
# BD here (that path corrupts the PS config and breaks boot). Update both
# the VHDL file AND these comment-values together when retargeting.
#
# Current setting: 22x22 (484 PEs) -- requires ZU9EG or larger.
# To target ZU3EG (Ultra96-V2), set N=8 in the VHDL wrapper.
set N_GEMM     22
set K_SAR_BITS 8
set SAR_BIT_LEN 32
set STREAM_LEN_RESIDUE 65536
set KBUF_MAX   64

# Flow runs all phases unconditionally. Only project / part / src_dir
# can be overridden at the command line; ARRAY SIZING IS NOT OVERRIDABLE
# from the Tcl any more -- edit stoch_gemm_axis_wrapper_hybrid.vhd to
# change N, K_SAR_BITS, SAR_BIT_LEN, STREAM_LEN_RESIDUE, KBUF_MAX.
if {[info exists ::argv]} {
    for {set i 0} {$i < [llength $::argv]} {incr i} {
        set arg [lindex $::argv $i]
        switch -- $arg {
            --src_dir    { incr i; set src_dir   [lindex $::argv $i] }
            --proj       { incr i; set proj_name [lindex $::argv $i] }
            --part       { incr i; set part      [lindex $::argv $i] }
            --board_part { incr i; set board_part [lindex $::argv $i] }
            default      {}
        }
    }
}

# Recompute proj_dir if --proj was passed
set proj_dir [file join $origin_dir $proj_name]
set reports_dir [file join $proj_dir reports]

puts "------------------------------------------------------------------"
puts " prj_gemm_hybrid_axi.tcl"
puts "   project name : $proj_name"
puts "   project dir  : $proj_dir"
puts "   source dir   : $src_dir"
puts "   part         : $part"
puts "   board_part   : $board_part"
puts " --- GEMM sizing ---"
puts "   N (array)              : $N_GEMM"
puts "   K_SAR_BITS             : $K_SAR_BITS"
puts "   SAR_BIT_LEN            : $SAR_BIT_LEN"
puts "   STREAM_LEN_RESIDUE     : $STREAM_LEN_RESIDUE"
puts " --- Flow ---"
puts "   Will run: project -> synth -> impl -> bitstream -> XSA + reports"
puts "------------------------------------------------------------------"

# ---- Verify all expected sources -------------------------------------------
set required {
    sng.sv
    stoch_pe_hybrid.sv
    stoch_systolic_array_hybrid.sv
    stoch_gemm_top_hybrid.sv
    stoch_gemm_axis_hybrid.sv
    stoch_gemm_axis_wrapper_hybrid.vhd
    tb_stoch_gemm_hybrid.sv
    bd.tcl
    gemm_multicycle.xdc
}
foreach f $required {
    set path [file join $src_dir $f]
    if {![file exists $path]} {
        puts "ERROR: required source not found: $path"
        exit 1
    }
}

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

if {[catch {set_property board_part $board_part [current_project]} bd_err]} {
    puts "WARN: could not set board_part to '$board_part' -- continuing without it"
}

set_property target_language     VHDL          [current_project]
set_property simulator_language  Mixed         [current_project]
set_property default_lib         xil_defaultlib [current_project]

# ===========================================================================
# PHASE 2 -- Add ALL HDL sources BEFORE sourcing bd.tcl
# ===========================================================================
puts "\n==> PHASE 2: adding HDL sources"

set sv_files [list \
    [file normalize [file join $src_dir sng.sv]] \
    [file normalize [file join $src_dir stoch_pe_hybrid.sv]] \
    [file normalize [file join $src_dir stoch_systolic_array_hybrid.sv]] \
    [file normalize [file join $src_dir stoch_gemm_top_hybrid.sv]] \
    [file normalize [file join $src_dir stoch_gemm_axis_hybrid.sv]] \
]
add_files -norecurse -fileset sources_1 $sv_files
foreach f $sv_files {
    set_property file_type SystemVerilog [get_files [file tail $f]]
}
puts "INFO: added [llength $sv_files] SystemVerilog files"

set vhd_file [file normalize [file join $src_dir stoch_gemm_axis_wrapper_hybrid.vhd]]
add_files -norecurse -fileset sources_1 $vhd_file
set_property file_type VHDL [get_files [file tail $vhd_file]]
puts "INFO: added VHDL wrapper [file tail $vhd_file]"

# Multicycle path constraints (required).
# Sets multi-cycle exceptions on AXI-Lite control registers (K_LEN,
# RES_PER_K, IRQ_EN) which are software-written once per job and stable
# while the FSM runs, so they do not need single-cycle setup.
# PROCESSING_ORDER LATE ensures these exceptions apply on top of the
# clock/timing constraints inferred from the block design.
set mc_xdc [file normalize [file join $src_dir gemm_multicycle.xdc]]
add_files -norecurse -fileset constrs_1 $mc_xdc
set_property PROCESSING_ORDER LATE [get_files [file tail $mc_xdc]]
puts "INFO: added multicycle constraints [file tail $mc_xdc] (PROCESSING_ORDER=LATE)"


set tb_file [file normalize [file join $src_dir tb_stoch_gemm_hybrid.sv]]
add_files -norecurse -fileset sim_1 $tb_file
set_property file_type SystemVerilog [get_files [file tail $tb_file]]
set_property top tb_stoch_gemm_hybrid [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1000ms} \
    -objects [get_filesets sim_1]
puts "INFO: added simulation testbench [file tail $tb_file]"

# ===========================================================================
# PHASE 3 -- update_compile_order so module references resolve
# ===========================================================================
puts "\n==> PHASE 3: updating compile order"
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set wrapper_vhd_added [get_files -filter "FILE_TYPE == \"VHDL\" && NAME =~ *stoch_gemm_axis_wrapper_hybrid*"]
if {[llength $wrapper_vhd_added] == 0} {
    puts "ERROR: stoch_gemm_axis_wrapper_hybrid.vhd not present in sources_1"
    exit 1
}
puts "INFO: hybrid wrapper VHDL is in sources_1 -- ready for BD"

# ===========================================================================
# PHASE 4 -- Patch bd.tcl: rewrite references to use the hybrid wrapper
# ===========================================================================
puts "\n==> PHASE 4: patching bd.tcl"

set bd_src   [file normalize [file join $src_dir bd.tcl]]
set bd_patch [file normalize [file join $proj_dir bd_hybrid.tcl]]

set fin  [open $bd_src "r"]
set fout [open $bd_patch "w"]
set sub_count 0
while {[gets $fin line] >= 0} {
    # Two-step replacement to avoid double-hybridizing:
    #   1. Protect existing "..._hybrid" tokens with a marker
    #   2. Replace bare "..._wrapper" with "..._wrapper_hybrid"
    #   3. Restore protected tokens
    regsub -all -- "stoch_gemm_axis_wrapper_hybrid" $line "__HYBRID_MARKER__" line
    set n [regsub -all -- "stoch_gemm_axis_wrapper" $line \
                  "stoch_gemm_axis_wrapper_hybrid" line]
    regsub -all -- "__HYBRID_MARKER__" $line "stoch_gemm_axis_wrapper_hybrid" line
    incr sub_count $n
    puts $fout $line
}
close $fin
close $fout
puts "INFO: wrote $bd_patch (with $sub_count token substitutions)"

# ===========================================================================
# PHASE 5 -- Source patched bd.tcl. This creates the block design.
# ===========================================================================
puts "\n==> PHASE 5: sourcing patched bd.tcl to create block design"

if {[catch {source $bd_patch} bd_err]} {
    puts "ERROR: bd.tcl sourcing failed: $bd_err"
    exit 1
}

set bd_designs [get_bd_designs]
if {[llength $bd_designs] == 0} {
    puts "ERROR: bd.tcl did not create a block design"
    exit 1
}
set current_bd [current_bd_design]
if {$current_bd ne ""} {
    set bd_design [get_property NAME $current_bd]
} else {
    set bd_design [lindex $bd_designs 0]
}
puts "INFO: detected [llength $bd_designs] BD design(s); using '$bd_design'"

# ===========================================================================
# PHASE 5b -- Sanity-check the PS configuration (READ ONLY)
#
# Important: we DO NOT use set_property to override the GEMM cell's
# generics here, even though Vivado nominally allows it. Doing so triggers
# Vivado BD revalidation, which has been observed to silently change PS
# settings (pl_clk0 jumping to 250 MHz, MIO reassignment, DDR retiming).
# Those changes cascade into FSBL PSU init code that hangs at boot before
# any UART output.
#
# Instead, the array sizing (N, K_SAR_BITS, SAR_BIT_LEN, STREAM_LEN_RESIDUE,
# KBUF_MAX) lives as VHDL generics in stoch_gemm_axis_wrapper_hybrid.vhd.
# Edit those defaults to retarget; do NOT touch the BD's CONFIG.* here.
#
# This phase just READS the PS clock setting and warns if it has drifted
# away from the expected 99.99 MHz.
# ===========================================================================
puts "\n==> PHASE 5b: verifying PS clock configuration"

set ps_cell [get_bd_cells -quiet -filter "VLNV =~ *zynq_ultra_ps_e*"]
if {[llength $ps_cell] == 0} {
    puts "WARN: ZynqMP PS cell not found in BD"
} else {
    set current_pl_clk [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $ps_cell]
    puts "INFO: PS cell '$ps_cell' has pl_clk0 = $current_pl_clk MHz"
    if {abs($current_pl_clk - 99.999001) > 1.0} {
        puts "ERROR: pl_clk0 = $current_pl_clk MHz, expected ~99.99 MHz."
        puts "        The BD's PS configuration has drifted from the original."
        puts "        Open the BD in GUI, fix the PS PL Fabric Clock to 99.999,"
        puts "        re-save the BD, and re-run this script."
        exit 1
    }
}

puts "INFO: Array sizing comes from VHDL generics in"
puts "      stoch_gemm_axis_wrapper_hybrid.vhd (edit there to retarget)."

# ===========================================================================
# PHASE 6 -- Validate and generate output products for the BD
# ===========================================================================
puts "\n==> PHASE 6: validating BD and generating output products"

save_bd_design
if {[catch {validate_bd_design} validate_err]} {
    puts "WARN: validate_bd_design returned: $validate_err"
}

set bd_files [get_files -filter "FILE_TYPE == \"Block Designs\""]
if {[llength $bd_files] == 0} {
    puts "ERROR: no Block Designs file in sources_1"
    exit 1
}
set bd_file [lindex $bd_files 0]
puts "INFO: BD file: $bd_file"

generate_target all [get_files $bd_file]

# ===========================================================================
# PHASE 7 -- Make VHDL wrapper for BD, add to project, set as top
# ===========================================================================
puts "\n==> PHASE 7: making BD HDL wrapper and setting top"

set wrapper [make_wrapper -files [get_files $bd_file] -top -force]
if {$wrapper eq ""} {
    puts "ERROR: make_wrapper returned empty"
    exit 1
}
add_files -norecurse $wrapper

set wrapper_name [file rootname [file tail $wrapper]]
set_property top $wrapper_name [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "INFO: top module set to '$wrapper_name'"

# ===========================================================================
# Helper: write reports after a run
# ===========================================================================
proc write_run_reports {run_name dir} {
    # Open the run's design in memory so report_* commands work
    if {$run_name eq "synth_1"} {
        open_run synth_1 -name synth_1
    } else {
        open_run impl_1 -name impl_1
    }

    set prefix [file join $dir "${run_name}"]
    puts "INFO: writing reports prefix=$prefix"

    # Timing summary
    report_timing_summary -file ${prefix}_timing_summary.rpt -warn_on_violation
    # Worst N setup and hold paths in detail
    report_timing -setup -max_paths 20 -path_type full_clock \
        -file ${prefix}_timing_setup_worst20.rpt
    report_timing -hold  -max_paths 20 -path_type full_clock \
        -file ${prefix}_timing_hold_worst20.rpt
    # Utilization
    report_utilization -file ${prefix}_utilization.rpt
    report_utilization -hierarchical -file ${prefix}_utilization_hier.rpt
    # Clock interaction
    report_clock_interaction -file ${prefix}_clock_interaction.rpt
    # DRC
    if {$run_name eq "impl_1"} {
        report_drc -file ${prefix}_drc.rpt
        report_power -file ${prefix}_power.rpt
    }

    close_design

    # Also print a one-line summary to the console
    puts "------------------------------------------------------------------"
    puts " $run_name timing summary:"
    set f [open ${prefix}_timing_summary.rpt r]
    set hit_wns 0
    while {[gets $f line] >= 0} {
        if {[regexp {WNS\(ns\)} $line]} { set hit_wns 1; continue }
        if {$hit_wns && [regexp {^\s*\-?\d+\.\d+\s+\-?\d+\.\d+} $line]} {
            puts "   $line"
            break
        }
    }
    close $f
    puts "------------------------------------------------------------------"
}

# ===========================================================================
# PHASE 8 -- Synthesis with reports
# ===========================================================================
puts "\n==> PHASE 8: launching synthesis"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synthesis failed"
    exit 1
}
puts "INFO: synthesis done"
write_run_reports synth_1 $reports_dir

# ===========================================================================
# PHASE 9 -- Implementation with reports
# ===========================================================================
puts "\n==> PHASE 9: launching implementation"
launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: implementation failed"
    exit 1
}
puts "INFO: implementation done"
write_run_reports impl_1 $reports_dir

# ===========================================================================
# PHASE 10 -- Bitstream
# ===========================================================================
puts "\n==> PHASE 10: generating bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set bit_path [file join $proj_dir $proj_name.runs impl_1 ${wrapper_name}.bit]
if {[file exists $bit_path]} {
    puts "INFO: bitstream at $bit_path"
} else {
    puts "WARN: bitstream file not found at $bit_path"
}

# ===========================================================================
# PHASE 11 -- Write XSA for PetaLinux
# ===========================================================================
puts "\n==> PHASE 11: writing .xsa for PetaLinux"
set xsa_path [file join $proj_dir ${proj_name}.xsa]
if {[catch {
    write_hw_platform -fixed -include_bit -force $xsa_path
} xsa_err]} {
    puts "ERROR: write_hw_platform failed: $xsa_err"
} else {
    puts "INFO: XSA at $xsa_path"
}

puts "\n=================================================================="
puts " DONE."
puts ""
puts " Project    : $proj_dir/$proj_name.xpr"
puts " BD design  : $bd_design"
puts " Top module : $wrapper_name"
puts " Array size : ${N_GEMM}x${N_GEMM} ($N_GEMM\u00d7$N_GEMM = [expr $N_GEMM * $N_GEMM] PEs)"
puts " Reports    : $reports_dir/"
puts " XSA        : $proj_dir/$proj_name.xsa"
puts ""
puts " Re-run after editing array size in stoch_gemm_axis_wrapper_hybrid.vhd:"
puts "   vivado -mode batch -source prj_gemm_hybrid_axi.tcl"
puts "==================================================================""

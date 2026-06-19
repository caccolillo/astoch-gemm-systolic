# =============================================================================
# prj_gemm_hybrid_axi.tcl
# Full Vivado project for the AXI-wrapped HYBRID stochastic GEMM.
#
# Flow phases (each phase depends on the previous one):
#
#   PHASE 1  -- Create the empty project
#   PHASE 2  -- Add ALL HDL sources (SV + VHDL + testbench + XDC)
#   PHASE 3  -- update_compile_order so Vivado has indexed everything
#   PHASE 4  -- Patch bd.tcl (substitute hybrid wrapper module name)
#   PHASE 5  -- Source patched bd.tcl, which creates the block design
#   PHASE 5b -- Sanity-check the PS configuration (READ ONLY)
#   PHASE 6  -- Validate + generate output products
#   PHASE 7  -- Make VHDL wrapper for BD, add to project, set as top
#   PHASE 8  -- Synthesis + reports
#   PHASE 9  -- Implementation THROUGH write_bitstream (single launch) + reports
#   PHASE 10 -- Write XSA for PetaLinux
#
# Required source files alongside this script:
#   sng.sv
#   stoch_pe_hybrid.sv
#   stoch_systolic_array_hybrid.sv
#   stoch_gemm_top_hybrid.sv
#   stoch_gemm_axis_hybrid.sv
#   stoch_gemm_axis_wrapper_hybrid.vhd
#   tb_stoch_gemm_hybrid.sv               (inner-core testbench, default top)
#   tb_stoch_gemm_axis_hybrid_n22.sv      (AXI-Stream wrapper testbench, N=22)
#   bd.tcl                                (the original block-design script)
#   gemm_multicycle.xdc                   (multicycle path exceptions)
#
# Usage:
#   vivado -mode batch -source prj_gemm_hybrid_axi.tcl
#       -> full flow: project -> synth -> impl -> bitstream -> XSA + reports
#
# Array sizing comes from VHDL generic defaults in
# stoch_gemm_axis_wrapper_hybrid.vhd:
#   N = 22, K_SAR_BITS = 8, SAR_BIT_LEN = 32,
#   STREAM_LEN_RESIDUE = 65536, KBUF_MAX = 16
# To retarget, edit the VHDL file and re-run this script.
# =============================================================================

# ---- Defaults --------------------------------------------------------------
set origin_dir [file dirname [info script]]
set src_dir    $origin_dir
set proj_name  gemm_hybrid_axi
set proj_dir   [file join $origin_dir $proj_name]
set part       xczu3eg-sbva484-1-i
set board_part {avnet.com:ultra96v2:part0:1.2}

# Mirror of the VHDL generic defaults (used for the final banner only).
set N_GEMM             22
set K_SAR_BITS         8
set SAR_BIT_LEN        32
set STREAM_LEN_RESIDUE 65536
set KBUF_MAX           16

# Only project / part / src_dir overridable from the command line. Array
# sizing is NOT overridable here -- edit stoch_gemm_axis_wrapper_hybrid.vhd.
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
    tb_stoch_gemm_axis_hybrid_n22.sv
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

# Multicycle path constraints (PROCESSING_ORDER LATE).
set mc_xdc [file normalize [file join $src_dir gemm_multicycle.xdc]]
add_files -norecurse -fileset constrs_1 $mc_xdc
set_property PROCESSING_ORDER LATE [get_files [file tail $mc_xdc]]
puts "INFO: added multicycle constraints [file tail $mc_xdc] (PROCESSING_ORDER=LATE)"

set tb_file [file normalize [file join $src_dir tb_stoch_gemm_hybrid.sv]]
add_files -norecurse -fileset sim_1 $tb_file
set_property file_type SystemVerilog [get_files [file tail $tb_file]]
puts "INFO: added simulation testbench [file tail $tb_file]"

set tb_wrap_file [file normalize [file join $src_dir tb_stoch_gemm_axis_hybrid_n22.sv]]
add_files -norecurse -fileset sim_1 $tb_wrap_file
set_property file_type SystemVerilog [get_files [file tail $tb_wrap_file]]
puts "INFO: added wrapper-level testbench [file tail $tb_wrap_file]"

# Default sim top = inner-core TB. Swap the comments to use the wrapper TB.
set_property top tb_stoch_gemm_hybrid           [get_filesets sim_1]
# set_property top tb_stoch_gemm_axis_hybrid_n22 [get_filesets sim_1]

set_property -name {xsim.simulate.runtime} -value {1000ms} \
    -objects [get_filesets sim_1]

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
# PHASE 4 -- Patch bd.tcl: substitute the bare wrapper name with the hybrid one
# (No-op if bd.tcl already references the hybrid wrapper. The two-pass marker
# substitution prevents accidental double-hybridisation in either case.)
# ===========================================================================
puts "\n==> PHASE 4: patching bd.tcl"

set bd_src   [file normalize [file join $src_dir bd.tcl]]
set bd_patch [file normalize [file join $proj_dir bd_hybrid.tcl]]

set fin  [open $bd_src "r"]
set fout [open $bd_patch "w"]
set sub_count 0
while {[gets $fin line] >= 0} {
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
# PHASE 5b -- Sanity-check the PS configuration (READ ONLY).
# Never use set_property on the PS cell here -- triggers Vivado BD
# revalidation that has been observed to silently change pl_clk0 / MIO /
# DDR settings and brick FSBL boot.
#
# Target: pl_clk0 = 250 MHz. This is the rate the multicycle constraints in
# gemm_multicycle.xdc and the synthesis runs were timed against. Running
# the bitstream produces 2.7x the throughput of the previous 100 MHz BD
# (gemm-test: 0.749 ms -> 0.279 ms per tile), and the kernel confirms the
# clock framework is restoring this rate via "restored PL clock at 250 MHz"
# on driver close. If you see a drift here, the BD has been edited.
# ===========================================================================
puts "\n==> PHASE 5b: verifying PS clock configuration"

set expected_pl_clk 250.0
set tolerance_mhz   1.0

set ps_cell [get_bd_cells -quiet -filter "VLNV =~ *zynq_ultra_ps_e*"]
if {[llength $ps_cell] == 0} {
    puts "WARN: ZynqMP PS cell not found in BD"
} else {
    set current_pl_clk [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $ps_cell]
    puts "INFO: PS cell '$ps_cell' has pl_clk0 = $current_pl_clk MHz (expected $expected_pl_clk MHz)"
    if {abs($current_pl_clk - $expected_pl_clk) > $tolerance_mhz} {
        puts "ERROR: pl_clk0 = $current_pl_clk MHz, expected ~$expected_pl_clk MHz."
        puts "        The BD's PS configuration has drifted from the timed target."
        puts "        Open the BD in GUI, set the PS PL Fabric Clock 0 to $expected_pl_clk MHz,"
        puts "        re-save the BD, and re-run this script. (Going below this will"
        puts "        slow gemm-test proportionally; going above risks timing violations"
        puts "        unless gemm_multicycle.xdc has been re-tuned for the new period.)"
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
# (target_language = VHDL was set in PHASE 1, so make_wrapper emits VHDL.)
# ===========================================================================
puts "\n==> PHASE 7: making BD HDL wrapper and setting top"

# make_wrapper can return a list. Take the first element defensively.
set wrapper_out [make_wrapper -files [list $bd_file] -top -force]
if {[llength $wrapper_out] == 0} {
    puts "ERROR: make_wrapper returned empty"
    exit 1
}
set wrapper [lindex $wrapper_out 0]
puts "INFO: make_wrapper produced: $wrapper"
puts "INFO:   extension: [file extension $wrapper] (expecting .vhd for VHDL flow)"

add_files -norecurse $wrapper

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
# Helper: write reports after a run
# ===========================================================================
proc write_run_reports {run_name dir} {
    if {$run_name eq "synth_1"} {
        open_run synth_1 -name synth_1
    } else {
        open_run impl_1 -name impl_1
    }

    set prefix [file join $dir "${run_name}"]
    puts "INFO: writing reports prefix=$prefix"

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

    # One-line console summary
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
# PHASE 9 -- Implementation THROUGH write_bitstream (single launch) + reports
# The default impl_1 strategy stops after route_design and does NOT write
# the bitstream. Using -to_step write_bitstream extends the run in one go.
# Re-launching impl_1 twice (once for impl, once for bitstream) is unreliable:
# wait_on_run sometimes returns immediately on a run already at 100%, leaving
# the bitstream step in flight when the next phase starts.
# ===========================================================================
puts "\n==> PHASE 9: launching implementation + write_bitstream (single run)"
#set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property strategy Performance_ExtraTimingOpt          [get_runs impl_1]
#set_property strategy Performance_NetDelay_high [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set impl_status [get_property STATUS   [get_runs impl_1]]
set impl_prog   [get_property PROGRESS [get_runs impl_1]]
puts "INFO: impl_1 STATUS='$impl_status' PROGRESS='$impl_prog'"
if {$impl_prog != "100%"} {
    puts "ERROR: implementation+bitstream failed"
    exit 1
}
puts "INFO: implementation + bitstream done"
write_run_reports impl_1 $reports_dir

set bit_path [file join $proj_dir $proj_name.runs impl_1 ${wrapper_name}.bit]
if {[file exists $bit_path]} {
    puts "INFO: bitstream confirmed at $bit_path"
} else {
    puts "ERROR: bitstream not found at $bit_path -- XSA will be incomplete"
    exit 1
}

# ===========================================================================
# PHASE 10 -- Write XSA for PetaLinux
# ===========================================================================
puts "\n==> PHASE 10: writing .xsa for PetaLinux"
set xsa_path [file join $proj_dir ${proj_name}.xsa]
if {[catch {
    write_hw_platform -fixed -include_bit -force $xsa_path
} xsa_err]} {
    puts "ERROR: write_hw_platform failed: $xsa_err"
    exit 1
}
if {[file exists $xsa_path]} {
    puts "INFO: XSA at $xsa_path ([file size $xsa_path] bytes)"
} else {
    puts "ERROR: write_hw_platform reported success but $xsa_path is missing"
    exit 1
}

puts "\n=================================================================="
puts " DONE."
puts ""
puts " Project    : $proj_dir/$proj_name.xpr"
puts " BD design  : $bd_design"
puts " Top module : $wrapper_name"
puts " Array size : ${N_GEMM}x${N_GEMM} ([expr $N_GEMM * $N_GEMM] PEs)"
puts " Reports    : $reports_dir/"
puts " Bitstream  : $bit_path"
puts " XSA        : $xsa_path"
puts ""
puts " Re-run after editing array size in stoch_gemm_axis_wrapper_hybrid.vhd:"
puts "   vivado -mode batch -source prj_gemm_hybrid_axi.tcl"
puts "=================================================================="

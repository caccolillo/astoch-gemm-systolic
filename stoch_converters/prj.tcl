# =============================================================================
# prj_s2b_all.tcl
# Single Vivado project containing all stochastic-to-binary converters and
# TWO simulation sets:
#
#   sim_compare -- the 2-way comparison: plain counter vs original SAR
#                  (top module: tb_s2b_compare)
#   sim_hybrid  -- the 3-way comparison at WIDTH=16: counter, SAR, hybrid
#                  (top module: tb_s2b_hybrid)
#
# Source files expected next to this script:
#   sng.sv
#   s2b_counter.sv
#   s2b_sar.sv
#   s2b_hybrid.sv
#   tb_s2b_compare.sv
#   tb_s2b_hybrid.sv
#
# Usage:
#   vivado -mode batch -source prj_s2b_all.tcl
#   vivado -mode batch -source prj_s2b_all.tcl -tclargs --run_compare
#   vivado -mode batch -source prj_s2b_all.tcl -tclargs --run_hybrid
#   vivado -mode batch -source prj_s2b_all.tcl -tclargs --run_compare --run_hybrid
#
# In the GUI:
#   Open the project, then in the Sources panel right-click the simulation
#   set you want and choose 'Make active'. Then 'Run Behavioral Simulation'.
# =============================================================================

set origin_dir [file dirname [info script]]
set src_dir    $origin_dir
set proj_name  s2b_all
set proj_dir   [file join $origin_dir $proj_name]
set part       xczu3eg-sbva484-1-i
set run_compare 0
set run_hybrid  0

# ---- Argument parsing -------------------------------------------------------
if {[info exists ::argv]} {
    for {set i 0} {$i < [llength $::argv]} {incr i} {
        set arg [lindex $::argv $i]
        switch -- $arg {
            --src_dir      { incr i; set src_dir   [lindex $::argv $i] }
            --proj         { incr i; set proj_name [lindex $::argv $i] }
            --part         { incr i; set part      [lindex $::argv $i] }
            --run_compare  { set run_compare 1 }
            --run_hybrid   { set run_hybrid  1 }
            --run_all      { set run_compare 1; set run_hybrid 1 }
            default        {}
        }
    }
}

puts "------------------------------------------------------------------"
puts " prj_s2b_all.tcl"
puts "   project name   : $proj_name"
puts "   project dir    : $proj_dir"
puts "   source dir     : $src_dir"
puts "   part           : $part"
puts "   auto-run compare : $run_compare"
puts "   auto-run hybrid  : $run_hybrid"
puts "------------------------------------------------------------------"

# ---- Verify sources --------------------------------------------------------
set required {
    sng.sv
    s2b_counter.sv
    s2b_sar.sv
    s2b_hybrid.sv
    tb_s2b_compare.sv
    tb_s2b_hybrid.sv
}
foreach f $required {
    set path [file join $src_dir $f]
    if {![file exists $path]} {
        puts "ERROR: required source not found: $path"
        exit 1
    }
}

# ---- (Re)create project ----------------------------------------------------
if {[file exists $proj_dir]} {
    puts "INFO: removing existing project directory $proj_dir"
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force
set_property target_language    Verilog        [current_project]
set_property simulator_language Mixed          [current_project]
set_property default_lib        xil_defaultlib [current_project]

# ---- Synthesisable RTL (shared) -------------------------------------------
set rtl_files [list \
    [file normalize [file join $src_dir sng.sv]] \
    [file normalize [file join $src_dir s2b_counter.sv]] \
    [file normalize [file join $src_dir s2b_sar.sv]] \
    [file normalize [file join $src_dir s2b_hybrid.sv]] \
]
add_files -norecurse -fileset sources_1 $rtl_files
set_property file_type SystemVerilog \
    [get_files -of_objects [get_filesets sources_1]]
update_compile_order -fileset sources_1

# ---- Two simulation sets ---------------------------------------------------
# Vivado's auto-created 'sim_1' fileset cannot be deleted (it's the default
# and the project must always have one simset).  We RE-USE sim_1 as the
# 'compare' simset by adding the compare testbench to it, and rename the
# label so it appears clearly in the Sources panel.  Then we create a second
# fileset 'sim_hybrid' for the hybrid testbench.

# ---- Sim set 1: re-use sim_1 for the compare testbench --------------------
set tb_compare [file normalize [file join $src_dir tb_s2b_compare.sv]]
add_files -norecurse -fileset sim_1 $tb_compare
set_property file_type SystemVerilog [get_files $tb_compare]
set_property top tb_s2b_compare [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {10000ms} \
    -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} \
    -objects [get_filesets sim_1]
update_compile_order -fileset sim_1

# ---- Sim set 2: new fileset for the hybrid testbench ----------------------
create_fileset -simset sim_hybrid

set tb_hybrid [file normalize [file join $src_dir tb_s2b_hybrid.sv]]
add_files -norecurse -fileset sim_hybrid $tb_hybrid
set_property file_type SystemVerilog [get_files $tb_hybrid]
set_property top tb_s2b_hybrid [get_filesets sim_hybrid]
set_property -name {xsim.simulate.runtime} -value {10000ms} \
    -objects [get_filesets sim_hybrid]
set_property -name {xsim.simulate.log_all_signals} -value {true} \
    -objects [get_filesets sim_hybrid]
update_compile_order -fileset sim_hybrid

# ---- Default active simset is sim_1 (compare) -----------------------------
current_fileset -simset [get_filesets sim_1]

puts "INFO: project created at $proj_dir"
puts "INFO: simulation sets: sim_1 (tb_s2b_compare, default), sim_hybrid (tb_s2b_hybrid)"

# ---- Optional auto-run ----------------------------------------------------
proc run_sim {simset_name csv_name} {
    puts "INFO: launching simulation '$simset_name'"
    current_fileset -simset [get_filesets $simset_name]
    launch_simulation -simset [get_filesets $simset_name]
    run all
    set sim_dir [get_property DIRECTORY [current_sim]]
    if {[file exists [file join $sim_dir $csv_name]]} {
        puts "INFO: '$simset_name' results CSV at [file join $sim_dir $csv_name]"
    } else {
        puts "WARN: CSV $csv_name not found in $sim_dir"
    }
    close_sim
}

if {$run_compare} { run_sim sim_1      s2b_compare_log.csv }
if {$run_hybrid}  { run_sim sim_hybrid s2b_hybrid_log.csv  }

puts "------------------------------------------------------------------"
puts " Done."
puts ""
puts " GUI:"
puts "   vivado $proj_dir/$proj_name.xpr"
puts "   In the Sources panel right-click 'sim_1' or 'sim_hybrid'"
puts "   and choose 'Make active', then click 'Run Behavioral Simulation'."
puts ""
puts " Batch:"
puts "   vivado -mode batch -source prj_s2b_all.tcl -tclargs --run_compare"
puts "   vivado -mode batch -source prj_s2b_all.tcl -tclargs --run_hybrid"
puts "   vivado -mode batch -source prj_s2b_all.tcl -tclargs --run_all"
puts "------------------------------------------------------------------"

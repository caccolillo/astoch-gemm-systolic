# =============================================================================
# prj_gemm_hybrid_axi.tcl
# Vivado project for the AXI-wrapped hybrid GEMM (synthesis-ready).
#
# This project lets you synthesize and check timing on the hybrid version
# of the GEMM with its full AXI infrastructure -- the same flow you used
# for the original GEMM, just with the hybrid converter inside.
#
# Required sources next to this script:
#   sng.sv                              (shared with original)
#   stoch_pe_hybrid.sv                  (new, hybrid PE)
#   stoch_systolic_array_hybrid.sv      (new, hybrid array)
#   stoch_gemm_top_hybrid.sv            (new, hybrid top FSM)
#   stoch_gemm_axis_hybrid.sv           (new, hybrid AXI wrapper SV)
#   stoch_gemm_axis_wrapper_hybrid.vhd  (new, hybrid AXI wrapper VHDL)
#   tb_stoch_gemm_hybrid.sv             (testbench)
#
# Usage:
#   vivado -mode batch -source prj_gemm_hybrid_axi.tcl
#
# After project creation:
#   Run Synthesis to check resource utilization
#   Run Implementation to verify timing closure
#   Run Behavioral Simulation to verify functionality
#
# To use in your existing GEMM block design:
#   1. Generate this project for synthesis check (timing, area)
#   2. In your block design Tcl (bd.tcl), change the line:
#        create_bd_cell -type module -reference stoch_gemm_axis_wrapper ...
#      to:
#        create_bd_cell -type module -reference stoch_gemm_axis_wrapper_hybrid ...
#   3. Replace stoch_gemm_axis.sv and stoch_gemm_axis_wrapper.vhd in your
#      project sources with the *_hybrid versions, and add the new RTL files
#      (stoch_pe_hybrid, stoch_systolic_array_hybrid, stoch_gemm_top_hybrid)
#   4. Regenerate the bitstream
#   5. Use gemm_test_uio_hybrid.c on the board -- it auto-detects hybrid
#      mode via the INFO2 register and applies the right decode formula
# =============================================================================

set origin_dir [file dirname [info script]]
set src_dir    $origin_dir
set proj_name  gemm_hybrid_axi
set proj_dir   [file join $origin_dir $proj_name]
set part       xczu3eg-sbva484-1-i

if {[info exists ::argv]} {
    for {set i 0} {$i < [llength $::argv]} {incr i} {
        set arg [lindex $::argv $i]
        switch -- $arg {
            --src_dir { incr i; set src_dir   [lindex $::argv $i] }
            --proj    { incr i; set proj_name [lindex $::argv $i] }
            --part    { incr i; set part      [lindex $::argv $i] }
            default   {}
        }
    }
}

puts "------------------------------------------------------------------"
puts " prj_gemm_hybrid_axi.tcl"
puts "   project name : $proj_name"
puts "   project dir  : $proj_dir"
puts "   source dir   : $src_dir"
puts "   part         : $part"
puts "------------------------------------------------------------------"

set required {
    sng.sv
    stoch_pe_hybrid.sv
    stoch_systolic_array_hybrid.sv
    stoch_gemm_top_hybrid.sv
    stoch_gemm_axis_hybrid.sv
    stoch_gemm_axis_wrapper_hybrid.vhd
    tb_stoch_gemm_hybrid.sv
}

foreach f $required {
    set path [file join $src_dir $f]
    if {![file exists $path]} {
        puts "ERROR: required source not found: $path"
        exit 1
    }
}

if {[file exists $proj_dir]} {
    puts "INFO: removing existing project directory $proj_dir"
    file delete -force $proj_dir
}

create_project $proj_name $proj_dir -part $part -force
set_property target_language     VHDL          [current_project]
set_property simulator_language  Mixed         [current_project]
set_property default_lib         xil_defaultlib [current_project]

# ---- Synthesis sources ----
set sv_files [list \
    [file normalize [file join $src_dir sng.sv]] \
    [file normalize [file join $src_dir stoch_pe_hybrid.sv]] \
    [file normalize [file join $src_dir stoch_systolic_array_hybrid.sv]] \
    [file normalize [file join $src_dir stoch_gemm_top_hybrid.sv]] \
    [file normalize [file join $src_dir stoch_gemm_axis_hybrid.sv]] \
]
add_files -norecurse -fileset sources_1 $sv_files
set_property file_type SystemVerilog [get_files $sv_files]

set vhd_file [file normalize [file join $src_dir stoch_gemm_axis_wrapper_hybrid.vhd]]
add_files -norecurse -fileset sources_1 $vhd_file
set_property file_type VHDL [get_files $vhd_file]

# Top synthesis module is the VHDL wrapper (entry point for the block design)
set_property top stoch_gemm_axis_wrapper_hybrid [get_filesets sources_1]

# ---- Simulation source ----
set tb_file [file normalize [file join $src_dir tb_stoch_gemm_hybrid.sv]]
add_files -norecurse -fileset sim_1 $tb_file
set_property file_type SystemVerilog [get_files $tb_file]
set_property top tb_stoch_gemm_hybrid [get_filesets sim_1]

set_property -name {xsim.simulate.runtime} -value {1000ms} \
    -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "INFO: project created at $proj_dir"
puts "INFO: synthesis top is stoch_gemm_axis_wrapper_hybrid (the VHDL entity)"
puts "INFO: sim top is tb_stoch_gemm_hybrid"
puts ""
puts " Next steps:"
puts "   1. vivado $proj_dir/$proj_name.xpr"
puts "   2. Run Synthesis -- check LUT/FF/BRAM/DSP utilisation"
puts "   3. Run Implementation -- verify 100 MHz timing closure"
puts "   4. Run Behavioral Simulation -- verify functionality"
puts ""
puts " To integrate into your existing block design:"
puts "   See the comment header in prj_gemm_hybrid_axi.tcl for instructions"
puts "------------------------------------------------------------------"

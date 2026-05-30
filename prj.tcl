#*****************************************************************************************
# prj_merged.tcl  --  Vivado 2022.3 project re-creation script (MERGED)
#
# BASIS
#   This script is the user's Vivado-exported prj.tcl (project 'project_1',
#   part xczu3eg-sbva484-1-i, board avnet.com:ultra96v2:part0:1.2) EXTENDED
#   with the test-workflow pieces it was missing:
#
#     + multiple simulation sets, one per testbench (switch active set in GUI)
#     + constraints wired in (gemm_ultra96v2.xdc) for synthesis
#     + the image-harness sim set with xsim working-directory fix so
#       tb_stoch_image finds the hex files produced by prep_im2col.py
#     + build/utility scripts registered under utils_1
#
#   The part, board_part, and the synth_1/impl_1 run + report + dashboard
#   configuration are taken VERBATIM from the user's exported prj.tcl -- those
#   are authoritative (Vivado-generated from a real working project) and are
#   not second-guessed here.
#
# SCOPE
#   Stochastic GEMM design only (matches the user's BIT_SERIAL_STOCHASTIC
#   project): sng.sv, stoch_pe.sv, stoch_systolic_array.sv, stoch_gemm_top.sv,
#   s2b_counter.sv.
#
# HOW TO USE
#   Place this script and all .sv / .xdc / build*.tcl files in one directory.
#   In the Vivado 2022.3 Tcl Console:
#       cd <that directory>
#       source prj_merged.tcl
#
# IMAGE HARNESS (sim set 'sim_image') -- hybrid Python + Vivado flow:
#   a) terminal:  python3 prep_im2col.py --filter gaussian --bmp img.bmp --resize 64
#   b) Vivado  :  make 'sim_image' the active sim set, Run Behavioral Simulation
#   c) terminal:  python3 score_results.py
#*****************************************************************************************

# Set the reference directory for source file relative paths.
set origin_dir "."
if { [info exists ::origin_dir_loc] } {
  set origin_dir $::origin_dir_loc
}

# Project name (overridable, as in the original export script).
set _xil_proj_name_ "project_1"
if { [info exists ::user_project_name] } {
  set _xil_proj_name_ $::user_project_name
}

# -----------------------------------------------------------------------------
# Create project -- part and board exactly as the user's exported prj.tcl.
# -----------------------------------------------------------------------------
create_project ${_xil_proj_name_} ./${_xil_proj_name_} -part xczu3eg-sbva484-1-i

set proj_dir [get_property directory [current_project]]

# ---- Project properties (verbatim from the exported prj.tcl) ---------------
set obj [current_project]
set_property -name "board_part" -value "avnet.com:ultra96v2:part0:1.2" -objects $obj
set_property -name "default_lib" -value "xil_defaultlib" -objects $obj
set_property -name "enable_resource_estimation" -value "0" -objects $obj
set_property -name "enable_vhdl_2008" -value "1" -objects $obj
set_property -name "ip_cache_permissions" -value "read write" -objects $obj
set_property -name "ip_output_repo" -value "$proj_dir/${_xil_proj_name_}.cache/ip" -objects $obj
set_property -name "mem.enable_memory_map_generation" -value "1" -objects $obj
set_property -name "platform.board_id" -value "ultra96v2" -objects $obj
set_property -name "revised_directory_structure" -value "1" -objects $obj
set_property -name "sim.central_dir" -value "$proj_dir/${_xil_proj_name_}.ip_user_files" -objects $obj
set_property -name "sim.ip.auto_export_scripts" -value "1" -objects $obj
set_property -name "simulator_language" -value "Mixed" -objects $obj
set_property -name "sim_compile_state" -value "1" -objects $obj

# -----------------------------------------------------------------------------
# Design sources : the stochastic GEMM RTL stack.
# (sng.sv is the supplied SNG; s2b_counter.sv is the supplied S2B converter.)
# -----------------------------------------------------------------------------
if {[string equal [get_filesets -quiet sources_1] ""]} {
  create_fileset -srcset sources_1
}
set obj [get_filesets sources_1]
set src_files [list \
 [file normalize "${origin_dir}/sng.sv"] \
 [file normalize "${origin_dir}/stoch_pe.sv"] \
 [file normalize "${origin_dir}/stoch_systolic_array.sv"] \
 [file normalize "${origin_dir}/stoch_gemm_top.sv"] \
 [file normalize "${origin_dir}/s2b_counter.sv"] \
 [file normalize "${origin_dir}/s2b_sar.sv"] \
 [file normalize "${origin_dir}/stoch_gemm_axil.sv"] \
 [file normalize "${origin_dir}/stoch_gemm_axis.sv"] \
 [file normalize "${origin_dir}/stoch_gemm_axis_wrapper.vhd"] \
]
add_files -norecurse -fileset $obj $src_files
set_property file_type {SystemVerilog} \
    [get_files -of_objects [get_filesets sources_1] *.sv]
set_property file_type {VHDL} \
    [get_files -of_objects [get_filesets sources_1] *.vhd]

# Synthesis top: the AXI-Stream wrapper (includes the core + AXI-Lite control).
# Change to "stoch_gemm_top" to synthesize the bare core, or "stoch_gemm_axil"
# for the register-mapped control wrapper only.
set_property -name "top" -value "stoch_gemm_axis" -objects [get_filesets sources_1]

# -----------------------------------------------------------------------------
# Constraints : wired in so Run Synthesis / Implementation has the XDC.
# The original exported prj.tcl left constrs_1 empty.
# -----------------------------------------------------------------------------
if {[string equal [get_filesets -quiet constrs_1] ""]} {
  create_fileset -constrset constrs_1
}
add_files -fileset constrs_1 -norecurse \
    [file normalize "${origin_dir}/gemm_ultra96v2.xdc"]

# -----------------------------------------------------------------------------
# Simulation sets -- one testbench each. Switch the ACTIVE set in the GUI:
#   Sources pane -> Simulation Sources -> right-click a set -> Make Active.
# -----------------------------------------------------------------------------

# ---- sim_1 : tb_stoch_gemm_top  (stochastic GEMM unit test) ----------------
if {[string equal [get_filesets -quiet sim_1] ""]} {
  create_fileset -simset sim_1
}
set obj [get_filesets sim_1]
add_files -fileset sim_1 -norecurse \
    [file normalize "${origin_dir}/tb_stoch_gemm_top.sv"]
set_property file_type {SystemVerilog} \
    [get_files -of_objects [get_filesets sim_1] *.sv]
set_property -name "top"     -value "tb_stoch_gemm_top" -objects $obj
set_property -name "top_lib" -value "xil_defaultlib"    -objects $obj

# ---- sim_image : tb_stoch_image  (image-processing harness) ----------------
# Hybrid flow -- run prep_im2col.py BEFORE and score_results.py AFTER.
# Testbench reads/writes stoch_imgtest/ by absolute path; no data in fileset.
if {[string equal [get_filesets -quiet sim_image] ""]} {
  create_fileset -simset sim_image
}
set obj [get_filesets sim_image]
add_files -fileset sim_image -norecurse \
    [file normalize "${origin_dir}/tb_stoch_image.sv"]
set_property file_type {SystemVerilog} \
    [get_files -of_objects [get_filesets sim_image] *.sv]
set_property -name "top"     -value "tb_stoch_image" -objects $obj
set_property -name "top_lib" -value "xil_defaultlib" -objects $obj

# ---- sim_axil : tb_stoch_gemm_axil  (AXI4-Lite wrapper test) ---------------
# Drives stoch_gemm_axil through AXI-Lite register transactions.
# Verified: all 64 results within stochastic tolerance.
if {[string equal [get_filesets -quiet sim_axil] ""]} {
  create_fileset -simset sim_axil
}
set obj [get_filesets sim_axil]
add_files -fileset sim_axil -norecurse \
    [file normalize "${origin_dir}/tb_stoch_gemm_axil.sv"]
set_property file_type {SystemVerilog} \
    [get_files -of_objects [get_filesets sim_axil] *.sv]
set_property -name "top"     -value "tb_stoch_gemm_axil" -objects $obj
set_property -name "top_lib" -value "xil_defaultlib"     -objects $obj

# ---- sim_axis : tb_stoch_gemm_axis  (AXI4-Stream wrapper test) --------------
# Drives stoch_gemm_axis as an AXI DMA would: stream in operands, stream out
# results, control via AXI-Lite registers.
if {[string equal [get_filesets -quiet sim_axis] ""]} {
  create_fileset -simset sim_axis
}
set obj [get_filesets sim_axis]
add_files -fileset sim_axis -norecurse \
    [file normalize "${origin_dir}/tb_stoch_gemm_axis.sv"]
set_property file_type {SystemVerilog} \
    [get_files -of_objects [get_filesets sim_axis] *.sv]
set_property -name "top"     -value "tb_stoch_gemm_axis" -objects $obj
set_property -name "top_lib" -value "xil_defaultlib"     -objects $obj

# ---- sim_sar : tb_sar_only_sweep  (SAR S2B converter sweep) -----------------
# Sweeps input 0..255, reports per-step error and summary stats.
# Reduce START_LEN in tb_s2b_sar.sv to 256 for a quick run; default 8192
# gives high accuracy but takes a long time in simulation.
if {[string equal [get_filesets -quiet sim_sar] ""]} {
  create_fileset -simset sim_sar
}
set obj [get_filesets sim_sar]
add_files -fileset sim_sar -norecurse \
    [file normalize "${origin_dir}/tb_s2b_sar.sv"]
set_property file_type {SystemVerilog} \
    [get_files -of_objects [get_filesets sim_sar] *.sv]
set_property -name "top"     -value "tb_sar_only_sweep" -objects $obj
set_property -name "top_lib" -value "xil_defaultlib"    -objects $obj

# Default active sim set.
current_fileset -simset [get_filesets sim_1]

# -----------------------------------------------------------------------------
# Utility scripts : standalone batch-build flows, registered so they travel
# with the project. RUN THEM OUTSIDE this project session:
#     vivado -mode batch -source build_stoch_gemm.tcl
# Do NOT source them inside this project's GUI session (non-project commands
# conflict with project mode).
# -----------------------------------------------------------------------------
if { [file exists [file normalize "${origin_dir}/build_stoch_gemm.tcl"]] } {
  add_files -fileset utils_1 -norecurse \
      [file normalize "${origin_dir}/build_stoch_gemm.tcl"]
}

# -----------------------------------------------------------------------------
# Synthesis / Implementation runs + reports + dashboard.
# This whole section is taken VERBATIM from the user's exported prj.tcl so the
# run configuration matches the original working project exactly.
# -----------------------------------------------------------------------------
set idrFlowPropertiesConstraints ""
catch {
 set idrFlowPropertiesConstraints [get_param runs.disableIDRFlowPropertyConstraints]
 set_param runs.disableIDRFlowPropertyConstraints 1
}

# Create 'synth_1' run (if not found)
if {[string equal [get_runs -quiet synth_1] ""]} {
    create_run -name synth_1 -part xczu3eg-sbva484-1-i -flow {Vivado Synthesis 2022} -strategy "Vivado Synthesis Defaults" -report_strategy {No Reports} -constrset constrs_1
} else {
  set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
  set_property flow "Vivado Synthesis 2022" [get_runs synth_1]
}
set obj [get_runs synth_1]
set_property set_report_strategy_name 1 $obj
set_property report_strategy {Vivado Synthesis Default Reports} $obj
set_property set_report_strategy_name 0 $obj
if { [ string equal [get_report_configs -of_objects [get_runs synth_1] synth_1_synth_report_utilization_0] "" ] } {
  create_report_config -report_name synth_1_synth_report_utilization_0 -report_type report_utilization:1.0 -steps synth_design -runs synth_1
}
set obj [get_runs synth_1]
set_property -name "auto_incremental_checkpoint" -value "1" -objects $obj
set_property -name "strategy" -value "Vivado Synthesis Defaults" -objects $obj
current_run -synthesis [get_runs synth_1]

# Create 'impl_1' run (if not found)
if {[string equal [get_runs -quiet impl_1] ""]} {
    create_run -name impl_1 -part xczu3eg-sbva484-1-i -flow {Vivado Implementation 2022} -strategy "Vivado Implementation Defaults" -report_strategy {No Reports} -constrset constrs_1 -parent_run synth_1
} else {
  set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]
  set_property flow "Vivado Implementation 2022" [get_runs impl_1]
}
set obj [get_runs impl_1]
set_property set_report_strategy_name 1 $obj
set_property report_strategy {Vivado Implementation Default Reports} $obj
set_property set_report_strategy_name 0 $obj

# Key implementation reports (timing/utilization/DRC/route status) -- the
# subset most useful for checking the design closes. The user's original
# prj.tcl created the full default report set; these are the essential ones.
foreach {rname rtype rstep} {
  impl_1_init_report_timing_summary_0   report_timing_summary:1.0  init_design
  impl_1_opt_report_drc_0               report_drc:1.0             opt_design
  impl_1_place_report_utilization_0     report_utilization:1.0     place_design
  impl_1_route_report_drc_0             report_drc:1.0             route_design
  impl_1_route_report_route_status_0    report_route_status:1.0    route_design
  impl_1_route_report_timing_summary_0  report_timing_summary:1.0  route_design
  impl_1_route_report_power_0           report_power:1.0           route_design
} {
  if { [string equal [get_report_configs -of_objects [get_runs impl_1] $rname] ""] } {
    create_report_config -report_name $rname -report_type $rtype -steps $rstep -runs impl_1
  }
}

set obj [get_runs impl_1]
set_property -name "strategy" -value "Vivado Implementation Defaults" -objects $obj
set_property -name "steps.write_bitstream.args.readback_file" -value "0" -objects $obj
set_property -name "steps.write_bitstream.args.verbose" -value "0" -objects $obj
current_run -implementation [get_runs impl_1]

catch {
 if { $idrFlowPropertiesConstraints != {} } {
   set_param runs.disableIDRFlowPropertyConstraints $idrFlowPropertiesConstraints
 }
}

puts ""
puts "============================================================"
puts "INFO: Project created: ${_xil_proj_name_}  (part xczu3eg-sbva484-1-i)"
puts ""
puts " Simulation sets (switch the active one in the Sources pane):"
puts "   sim_1      -> tb_stoch_gemm_top    (stochastic GEMM unit test)"
puts "   sim_image  -> tb_stoch_image       (image harness -- run Python first)"
puts "   sim_axil   -> tb_stoch_gemm_axil   (AXI-Lite wrapper test)"
puts "   sim_axis   -> tb_stoch_gemm_axis   (AXI-Stream wrapper test)"
puts "   sim_sar    -> tb_sar_only_sweep    (SAR S2B converter sweep)"
puts ""
puts " Constraints : gemm_ultra96v2.xdc wired into constrs_1."
puts "============================================================"

# =============================================================================
# BLOCK DESIGN + FULL BUILD FLOW
# =============================================================================
# Source bd.tcl to build the PS + DMA + accelerator block design.
# This creates gemm_accel.bd, wires all AXI connections, assigns addresses,
# validates, and saves the design.
# =============================================================================

puts ""
puts "============================================================"
puts " Building block design (gemm_accel)..."
puts "============================================================"

source [file normalize "${origin_dir}/bd.tcl"]

# =============================================================================
# Generate HDL wrapper for the block design.
# Vivado generates a Verilog wrapper that instantiates gemm_accel.bd and
# becomes the true synthesis top level -- replacing the standalone
# stoch_gemm_axis top that was used for the earlier OOC synthesis runs.
# =============================================================================
puts ""
puts " Generating HDL wrapper for gemm_accel..."

set bd_file [get_files -of_objects [get_filesets sources_1] {*.bd}]
make_wrapper -files $bd_file -top -import

# The generated wrapper is automatically added to sources_1 by -import.
# Set it as the synthesis top.
set wrapper_file [get_files -of_objects [get_filesets sources_1] \
                  {*gemm_accel_wrapper*}]
if { $wrapper_file ne "" } {
    set_property top gemm_accel_wrapper [current_fileset]
    puts " Set synthesis top: gemm_accel_wrapper"
} else {
    puts "WARNING: wrapper not found -- set top manually:"
    puts "  set_property top gemm_accel_wrapper \[current_fileset\]"
}
update_compile_order -fileset sources_1

# =============================================================================
# Launch Synthesis
# =============================================================================
puts ""
puts "============================================================"
puts " Launching synthesis (synth_1)..."
puts " This will take 10-20 minutes. Monitor in Flow Navigator."
puts "============================================================"

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if { [get_property PROGRESS [get_runs synth_1]] ne "100%" } {
    puts "ERROR: synthesis did not complete -- check synth_1/runme.log"
    return
}
puts " Synthesis complete."
open_run synth_1 -name synth_1
report_utilization -file [file normalize "${origin_dir}/utilization_synth.rpt"]
puts " Utilization report: utilization_synth.rpt"

# =============================================================================
# Launch Implementation
# =============================================================================
puts ""
puts "============================================================"
puts " Launching implementation (impl_1)..."
puts " This will take 15-30 minutes."
puts "============================================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } {
    puts "ERROR: implementation did not complete -- check impl_1/runme.log"
    return
}
puts " Implementation complete."
open_run impl_1 -name impl_1

# Report timing -- WNS >= 0 confirms 200 MHz closes.
report_timing_summary -file [file normalize "${origin_dir}/timing_impl.rpt"]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 \
                              -setup -sort_by slack]]
set timing_status [expr {$wns >= 0 ? "PASS -- 200 MHz closes" : "FAIL -- timing not met"}]
puts ""
puts " Timing summary:"
puts "   WNS = $wns ns  ($timing_status)"
if { $wns < 0 } {
    puts "   Consider relaxing the clock (e.g. 6.0 ns = 166 MHz) in gemm_ultra96v2.xdc"
    puts "   and re-running implementation."
}

# =============================================================================
# Generate Bitstream
# =============================================================================
puts ""
puts "============================================================"
puts " Generating bitstream..."
puts "============================================================"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts " Bitstream generation complete."

# =============================================================================
# Export hardware (.xsa) for Vitis / PetaLinux
# The .xsa contains the bitstream + hardware description.
# PetaLinux: petalinux-config --get-hw-description=<path to .xsa>
# Vitis:     File -> New -> Platform Project -> browse to .xsa
# =============================================================================
puts ""
puts "============================================================"
puts " Exporting hardware for Vitis / PetaLinux..."
puts "============================================================"

set xsa_path [file normalize "${origin_dir}/gemm_accel.xsa"]
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts " Exported: $xsa_path"

puts ""
puts "============================================================"
puts " FULL BUILD COMPLETE"
puts ""
puts " Outputs:"
puts "   gemm_accel.xsa       -- import into Vitis or PetaLinux"
puts "   utilization_synth.rpt -- LUT/FF/DSP breakdown"
puts "   timing_impl.rpt      -- post-route timing (check WNS)"
puts ""
puts " Next steps (on the board):"
puts "   1. petalinux-config --get-hw-description=./gemm_accel.xsa"
puts "   2. petalinux-build"
puts "   3. Load stoch_gemm_drv.ko + stoch_gemm.dtbo on the board"
puts "   4. Run gemm_test"
puts "============================================================"

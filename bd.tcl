# =============================================================================
# create_bd.tcl
# Creates the Vivado block design for the stochastic GEMM accelerator on the
# Avnet Ultra96-V2 (xczu3eg-sbva484-1-i, Vivado 2022.2).
#
# Topology
#   Zynq UltraScale+ PS8
#     GP0 (M_AXI_HPM0_FPD, 32-bit) -> AXI Interconnect
#       -> stoch_gemm_axis  AXI-Lite control   @ 0xA000_0000  (4 KB)
#       -> axi_dma          AXI-Lite control   @ 0xA001_0000  (64 KB)
#     HP0 (S_AXI_HP0_FPD, 128-bit) <- axi_dma  MM2S/S2MM (DDR access)
#     IRQ_F2P[0]  <- stoch_gemm_axis irq
#     IRQ_F2P[1]  <- axi_dma mm2s_introut
#     IRQ_F2P[2]  <- axi_dma s2mm_introut
#     pl_clk0     -> 200 MHz -> everything
#
# AXI DMA wiring
#   MM2S (memory -> stream): DDR -> stoch_gemm_axis s_axis  (operand feed)
#   S2MM (stream -> memory): stoch_gemm_axis m_axis -> DDR  (result drain)
#
# HOW TO USE
#   In Vivado 2022.2 Tcl Console (project must already be open):
#       source create_bd.tcl
#   Then:
#       validate_bd_design
#       make_wrapper -files [get_files *.bd] -top
#       add_files [glob .srcs/*/bd/*/hdl/*.v]
#       set_property top <wrapper_name> [current_fileset]
#       save_bd_design
#
# ADDRESS MAP (set explicitly below -- matches the Linux driver)
#   stoch_gemm_axis  AXI-Lite  : 0xA000_0000 -- 0xA000_0FFF  (4 KB)
#   axi_dma          AXI-Lite  : 0xA001_0000 -- 0xA001_FFFF  (64 KB)
# =============================================================================

# ---- Open or create the block design ----------------------------------------
set bd_name "gemm_accel"
if { [get_bd_designs -quiet $bd_name] eq "" } {
    create_bd_design $bd_name
}
current_bd_design $bd_name

# =============================================================================
# 1. Zynq UltraScale+ PS
# =============================================================================
set ps [ create_bd_cell -type ip \
         -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0 ]

# Apply the Ultra96-V2 board preset directly via set_property.
# apply_board_connection is skipped -- it requires a board interface named
# "preset" which is not always available in this context, and the explicit
# set_property calls below are the authoritative PS configuration anyway.

# Enable the ports we need.
set_property -dict [ list \
    CONFIG.PSU__USE__M_AXI_GP0          {1} \
    CONFIG.PSU__USE__S_AXI_GP2          {1} \
    CONFIG.PSU__USE__IRQ0               {1} \
    CONFIG.PSU__NUM_FABRIC_RESETS       {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} \
] $ps

# HP0 (S_AXI_GP2) data width 128-bit for DMA throughput.
set_property CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} $ps

# =============================================================================
# 2. AXI DMA
# =============================================================================
set dma [ create_bd_cell -type ip \
          -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0 ]

set_property -dict [ list \
    CONFIG.c_include_sg          {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_mm2s_burst_size     {16} \
    CONFIG.c_s2mm_burst_size     {16} \
    CONFIG.c_m_axi_mm2s_data_width  {32} \
    CONFIG.c_m_axi_s2mm_data_width  {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_addr_width          {32} \
] $dma

# =============================================================================
# 3. stoch_gemm_axis -- instantiated via its VHDL wrapper.
#    Vivado block designs cannot directly reference a SystemVerilog top file.
#    stoch_gemm_axis_wrapper.vhd declares a VHDL entity with identical ports
#    and instantiates stoch_gemm_axis as a component -- Vivado links the SV
#    implementation during synthesis. Add both files to sources_1 first.
# =============================================================================
set gemm [ create_bd_cell -type module \
           -reference stoch_gemm_axis_wrapper stoch_gemm_axis_0 ]

# =============================================================================
# 4. AXI Interconnect  (GP0 -> two AXI-Lite slaves)
# =============================================================================
set ic [ create_bd_cell -type ip \
         -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0 ]
set_property -dict [ list \
    CONFIG.NUM_MI {2} \
] $ic

# =============================================================================
# 4b. SmartConnect (merges DMA MM2S + S2MM onto single HP0 slave port).
#     Must be instantiated here -- before section 6 -- so the aclk pin
#     exists when the clock connect_bd_net is executed.
# =============================================================================
set sc [ create_bd_cell -type ip \
         -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0 ]
set_property -dict [ list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {1} \
] $sc

# =============================================================================
# 5. Processor System Reset
# =============================================================================
set rst [ create_bd_cell -type ip \
          -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0 ]

# =============================================================================
# 6. Clocking and reset wiring
# =============================================================================
# pl_clk0 (200 MHz) drives everything including the PS AXI interface clocks.
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
    [get_bd_pins axi_interconnect_0/ACLK] \
    [get_bd_pins axi_interconnect_0/S00_ACLK] \
    [get_bd_pins axi_interconnect_0/M00_ACLK] \
    [get_bd_pins axi_interconnect_0/M01_ACLK] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins stoch_gemm_axis_0/aclk] \
    [get_bd_pins smartconnect_0/aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk] \
    [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

# pl_resetn0 -> proc_sys_reset -> peripheral_aresetn.
connect_bd_net \
    [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net \
    [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_interconnect_0/ARESETN] \
    [get_bd_pins axi_interconnect_0/S00_ARESETN] \
    [get_bd_pins axi_interconnect_0/M00_ARESETN] \
    [get_bd_pins axi_interconnect_0/M01_ARESETN] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins stoch_gemm_axis_0/aresetn]

# =============================================================================
# 7. AXI control path: PS GP0 -> Interconnect -> slaves
# =============================================================================
connect_bd_intf_net \
    [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins axi_interconnect_0/S00_AXI]

# M00 -> stoch_gemm_axis AXI-Lite
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
    [get_bd_intf_pins stoch_gemm_axis_0/S_AXI]

# M01 -> axi_dma AXI-Lite
connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# =============================================================================
# 8. AXI data path: DMA <-> SmartConnect <-> HP0 <-> DDR
#    MM2S and S2MM are two separate AXI master ports. HP0 is a single AXI
#    slave port. The SmartConnect (instantiated in section 4b) merges them.
# =============================================================================

# Reset for the SmartConnect.
connect_bd_net \
    [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins smartconnect_0/aresetn]

# DMA MM2S -> SmartConnect S00
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins smartconnect_0/S00_AXI]

# DMA S2MM -> SmartConnect S01
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins smartconnect_0/S01_AXI]

# SmartConnect M00 -> PS HP0
connect_bd_intf_net \
    [get_bd_intf_pins smartconnect_0/M00_AXI] \
    [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

# =============================================================================
# 9. AXI-Stream: DMA <-> stoch_gemm_axis
# =============================================================================
# MM2S: DMA reads DDR -> streams operands to the accelerator input FIFO.
connect_bd_intf_net \
    [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins stoch_gemm_axis_0/S_AXIS]

# S2MM: accelerator result stream -> DMA writes to DDR.
connect_bd_intf_net \
    [get_bd_intf_pins stoch_gemm_axis_0/M_AXIS] \
    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# =============================================================================
# 10. Interrupts: IRQ_F2P
# =============================================================================
# Concat three interrupt lines into the PS IRQ_F2P port.
set xlconcat [ create_bd_cell -type ip \
               -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0 ]
set_property CONFIG.NUM_PORTS {3} $xlconcat

connect_bd_net \
    [get_bd_pins stoch_gemm_axis_0/irq] \
    [get_bd_pins xlconcat_0/In0]
connect_bd_net \
    [get_bd_pins axi_dma_0/mm2s_introut] \
    [get_bd_pins xlconcat_0/In1]
connect_bd_net \
    [get_bd_pins axi_dma_0/s2mm_introut] \
    [get_bd_pins xlconcat_0/In2]
connect_bd_net \
    [get_bd_pins xlconcat_0/dout] \
    [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

# =============================================================================
# 11. Address assignment
# =============================================================================
# stoch_gemm_axis AXI-Lite slave @ 0xA000_0000, 4 KB
assign_bd_address \
    [get_bd_addr_segs stoch_gemm_axis_0/S_AXI/reg0]
set_property offset 0xA0000000 \
    [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_stoch_gemm_axis_0_reg0}]
set_property range 4K \
    [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_stoch_gemm_axis_0_reg0}]

# axi_dma AXI-Lite slave @ 0xA001_0000, 64 KB
assign_bd_address \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg]
set_property offset 0xA0010000 \
    [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_dma_0_Reg}]
set_property range 64K \
    [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_axi_dma_0_Reg}]

# HP0 slave (DMA accesses DDR through this port) -- full 2 GB DDR range.
assign_bd_address \
    [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW]

# Auto-assign any remaining unassigned segments (SmartConnect internals,
# additional DMA master views, etc.) with Vivado default ranges.
# assign_bd_address with no arguments assigns everything still unassigned.
assign_bd_address

# =============================================================================
# 12. Layout and save
# =============================================================================
regenerate_bd_layout
validate_bd_design
save_bd_design

puts ""
puts "============================================================"
puts " Block design '$bd_name' created."
puts ""
puts " NEXT STEPS:"
puts "   1. make_wrapper -files \[get_files *.bd\] -top"
puts "   2. Add the generated wrapper .v to sources."
puts "   3. Set it as the synthesis top."
puts "   4. Run Synthesis + Implementation."
puts "   5. Export hardware (.xsa) for PetaLinux/Vitis."
puts ""
puts " ADDRESS MAP:"
puts "   stoch_gemm_axis  AXI-Lite : 0xA0000000  (4 KB)"
puts "   axi_dma          AXI-Lite : 0xA0010000  (64 KB)"
puts "   IRQ_F2P[0] : stoch_gemm_axis irq"
puts "   IRQ_F2P[1] : axi_dma mm2s"
puts "   IRQ_F2P[2] : axi_dma s2mm"
puts "============================================================"

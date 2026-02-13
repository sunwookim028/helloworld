# Integration Script for HBM Loopback Module
# This TCL script adds the hbm_loopback module to the AVED block design
#
# Usage: Source this after create_bd_design.tcl in the build flow
# Or manually source in Vivado GUI to add the module

# Add RTL source
add_files -norecurse ../../../hw/rtl/hbm_loopback.v
update_compile_order -fileset sources_1

# Create the hbm_loopback instance
create_bd_cell -type module -reference hbm_loopback hbm_loopback_0

# Connect to AXI NoC for HBM access
# The loopback module's AXI4 master connects to the NoC
# which then routes to HBM

# First, we need to add another slave interface to the NoC
# Modify axi_noc_cips to have one more slave interface
set_property -dict [list CONFIG.NUM_SI {5}] [get_bd_cells axi_noc_cips]

# Connect the loopback module's AXI4 master to NoC S04_AXI
connect_bd_intf_net [get_bd_intf_pins hbm_loopback_0/m_axi] [get_bd_intf_pins axi_noc_cips/S04_AXI]

# Configure the new NoC slave interface for HBM access
set_property -dict [list \
  CONFIG.CONNECTIONS {HBM0_PORT0 {read_bw {250} write_bw {250} read_avg_burst {4} write_avg_burst {4}}} \
  CONFIG.CATEGORY {pl} \
] [get_bd_intf_pins /axi_noc_cips/S04_AXI]

# Connect clock for the new NoC interface
set_property CONFIG.NUM_CLKS {6} [get_bd_cells axi_noc_cips]
connect_bd_net [get_bd_pins clock_reset/clk_usr_0] [get_bd_pins axi_noc_cips/aclk5]
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S04_AXI}] [get_bd_pins /axi_noc_cips/aclk5]

# Connect the loopback module's AXI-Lite slave to the PCIe management interface
# This allows the host to access the loopback registers via PCIe

# Modify the pcie_slr0_mgmt_sc SmartConnect to have one more master
set_property CONFIG.NUM_MI {5} [get_bd_cells base_logic/pcie_slr0_mgmt_sc]

# Connect loopback AXI-Lite slave to the SmartConnect
connect_bd_intf_net [get_bd_intf_pins base_logic/pcie_slr0_mgmt_sc/M04_AXI] [get_bd_intf_pins hbm_loopback_0/s_axil]

# Connect clocks and resets for loopback module
connect_bd_net [get_bd_pins clock_reset/clk_usr_0] [get_bd_pins hbm_loopback_0/aclk]
connect_bd_net [get_bd_pins clock_reset/resetn_usr_0_periph] [get_bd_pins hbm_loopback_0/aresetn]

# Assign address for the loopback registers
# Place it at 0x020101050000 (after the existing management registers)
assign_bd_address -offset 0x020101050000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces cips/CPM_PCIE_NOC_0] \
  [get_bd_addr_segs hbm_loopback_0/s_axil/reg0] -force

assign_bd_address -offset 0x020101050000 -range 0x00001000 \
  -target_address_space [get_bd_addr_spaces cips/CPM_PCIE_NOC_1] \
  [get_bd_addr_segs hbm_loopback_0/s_axil/reg0] -force

# Assign HBM address space for the loopback module
assign_bd_address -offset 0x004000000000 -range 0x40000000 \
  -target_address_space [get_bd_addr_spaces hbm_loopback_0/m_axi] \
  [get_bd_addr_segs axi_noc_cips/S04_AXI/HBM0_PC0] -force

# Validate and save
validate_bd_design
save_bd_design

puts "INFO: HBM Loopback module successfully integrated into block design"
puts "INFO: Loopback register base address: 0x020101050000"
puts "INFO: HBM access address: 0x004000000000"

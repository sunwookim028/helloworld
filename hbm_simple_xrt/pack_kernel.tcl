# ==============================================================================
# pack_kernel.tcl — Package krnl_vadd RTL as a Vitis .xo kernel object
#
# Uses EXPLICIT interface definitions (not auto-inference) following
# the official Xilinx RTL kernel packaging pattern.
#
# Usage (from Makefile):
#   vivado -mode batch -source pack_kernel.tcl -notrace
#
# Produces: krnl_vadd.xo
# ==============================================================================

set kernel_name "krnl_vadd"
set xo_path     "krnl_vadd.xo"
set part        "xcu280-fsvh2892-2L-e"

# RTL source files
set rtl_files [list \
    "src/krnl_vadd.sv" \
    "src/krnl_vadd_ctrl.v" \
    "src/krnl_vadd_rd_mst.v" \
    "src/krnl_vadd_wr_mst.v" \
    "src/fifo4.sv" \
]

puts "INFO: Packaging RTL kernel '$kernel_name'"

# ==============================================================================
# 1. Create temporary Vivado project and add RTL sources
# ==============================================================================
set proj_dir "./_pack_project"
create_project -force ${kernel_name}_pack $proj_dir -part $part

foreach f $rtl_files {
    if {![file exists $f]} {
        error "RTL source file not found: $f"
    }
}
add_files $rtl_files
set_property top $kernel_name [current_fileset]
update_compile_order -fileset sources_1

# ==============================================================================
# 2. Package as Vivado IP
# ==============================================================================
set ip_dir "./ip_repo"

ipx::package_project \
    -root_dir    $ip_dir \
    -vendor      user.org \
    -library     user \
    -taxonomy    /UserIP \
    -import_files \
    -set_current true

set core [ipx::current_core]

# ==============================================================================
# 3. Mark as Vitis RTL kernel
# ==============================================================================
set_property sdx_kernel true       $core
set_property sdx_kernel_type rtl   $core
set_property ipi_drc {ignore_freq_hz true} $core

# ==============================================================================
# 4. Verify/fix AXI interface inference
# ==============================================================================

# --- Clock and Reset ---
# These should be auto-inferred from ap_clk and ap_rst_n port names.
# Verify they exist:
set clk_intf [ipx::get_bus_interfaces ap_clk -of_objects $core -quiet]
if {$clk_intf eq ""} {
    puts "WARNING: ap_clk interface not inferred, creating manually"
    set clk_intf [ipx::add_bus_interface ap_clk $core]
    set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $clk_intf
    set_property bus_type_vlnv xilinx.com:signal:clock:1.0 $clk_intf
    set_property interface_mode slave $clk_intf
    ipx::add_port_map CLK $clk_intf
    set_property physical_name ap_clk [ipx::get_port_maps CLK -of_objects $clk_intf]
}

set rst_intf [ipx::get_bus_interfaces ap_rst_n -of_objects $core -quiet]
if {$rst_intf eq ""} {
    puts "WARNING: ap_rst_n interface not inferred, creating manually"
    set rst_intf [ipx::add_bus_interface ap_rst_n $core]
    set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 $rst_intf
    set_property bus_type_vlnv xilinx.com:signal:reset:1.0 $rst_intf
    set_property interface_mode slave $rst_intf
    ipx::add_port_map RST $rst_intf
    set_property physical_name ap_rst_n [ipx::get_port_maps RST -of_objects $rst_intf]
    set_property value ACTIVE_LOW [ipx::add_bus_parameter POLARITY $rst_intf]
}

# --- AXI4-Lite Slave: s_axi_control ---
set ctrl_intf [ipx::get_bus_interfaces s_axi_control -of_objects $core -quiet]
if {$ctrl_intf eq ""} {
    puts "WARNING: s_axi_control not inferred, will add manually"
    ipx::infer_bus_interface \
        {s_axi_control_awaddr s_axi_control_awprot s_axi_control_awvalid s_axi_control_awready \
         s_axi_control_wdata  s_axi_control_wstrb  s_axi_control_wvalid  s_axi_control_wready \
         s_axi_control_bresp  s_axi_control_bvalid s_axi_control_bready \
         s_axi_control_araddr s_axi_control_arprot s_axi_control_arvalid s_axi_control_arready \
         s_axi_control_rdata  s_axi_control_rresp  s_axi_control_rvalid  s_axi_control_rready} \
        xilinx.com:interface:aximm_rtl:1.0 \
        [ipx::current_core]
    set ctrl_intf [ipx::get_bus_interfaces s_axi_control -of_objects $core]
}
puts "INFO: s_axi_control interface: [get_property NAME $ctrl_intf]"

# --- AXI4 Master: m_axi_gmem0 ---
set gmem0_intf [ipx::get_bus_interfaces m_axi_gmem0 -of_objects $core -quiet]
if {$gmem0_intf eq ""} {
    puts "WARNING: m_axi_gmem0 not inferred, will add manually"
    ipx::infer_bus_interface \
        {m_axi_gmem0_araddr m_axi_gmem0_arlen m_axi_gmem0_arsize m_axi_gmem0_arburst \
         m_axi_gmem0_arcache m_axi_gmem0_arprot m_axi_gmem0_arqos m_axi_gmem0_arvalid m_axi_gmem0_arready \
         m_axi_gmem0_rdata m_axi_gmem0_rresp m_axi_gmem0_rlast m_axi_gmem0_rvalid m_axi_gmem0_rready \
         m_axi_gmem0_awaddr m_axi_gmem0_awlen m_axi_gmem0_awsize m_axi_gmem0_awburst \
         m_axi_gmem0_awcache m_axi_gmem0_awprot m_axi_gmem0_awqos m_axi_gmem0_awvalid m_axi_gmem0_awready \
         m_axi_gmem0_wdata m_axi_gmem0_wstrb m_axi_gmem0_wlast m_axi_gmem0_wvalid m_axi_gmem0_wready \
         m_axi_gmem0_bresp m_axi_gmem0_bvalid m_axi_gmem0_bready} \
        xilinx.com:interface:aximm_rtl:1.0 \
        [ipx::current_core]
    set gmem0_intf [ipx::get_bus_interfaces m_axi_gmem0 -of_objects $core]
}
puts "INFO: m_axi_gmem0 interface: [get_property NAME $gmem0_intf]"

# --- AXI4 Master: m_axi_gmem1 ---
set gmem1_intf [ipx::get_bus_interfaces m_axi_gmem1 -of_objects $core -quiet]
if {$gmem1_intf eq ""} {
    puts "WARNING: m_axi_gmem1 not inferred, will add manually"
    ipx::infer_bus_interface \
        {m_axi_gmem1_araddr m_axi_gmem1_arlen m_axi_gmem1_arsize m_axi_gmem1_arburst \
         m_axi_gmem1_arcache m_axi_gmem1_arprot m_axi_gmem1_arqos m_axi_gmem1_arvalid m_axi_gmem1_arready \
         m_axi_gmem1_rdata m_axi_gmem1_rresp m_axi_gmem1_rlast m_axi_gmem1_rvalid m_axi_gmem1_rready \
         m_axi_gmem1_awaddr m_axi_gmem1_awlen m_axi_gmem1_awsize m_axi_gmem1_awburst \
         m_axi_gmem1_awcache m_axi_gmem1_awprot m_axi_gmem1_awqos m_axi_gmem1_awvalid m_axi_gmem1_awready \
         m_axi_gmem1_wdata m_axi_gmem1_wstrb m_axi_gmem1_wlast m_axi_gmem1_wvalid m_axi_gmem1_wready \
         m_axi_gmem1_bresp m_axi_gmem1_bvalid m_axi_gmem1_bready} \
        xilinx.com:interface:aximm_rtl:1.0 \
        [ipx::current_core]
    set gmem1_intf [ipx::get_bus_interfaces m_axi_gmem1 -of_objects $core]
}
puts "INFO: m_axi_gmem1 interface: [get_property NAME $gmem1_intf]"

# --- AXI4 Master: m_axi_gmem2 ---
set gmem2_intf [ipx::get_bus_interfaces m_axi_gmem2 -of_objects $core -quiet]
if {$gmem2_intf eq ""} {
    puts "WARNING: m_axi_gmem2 not inferred, will add manually"
    ipx::infer_bus_interface \
        {m_axi_gmem2_awaddr m_axi_gmem2_awlen m_axi_gmem2_awsize m_axi_gmem2_awburst \
         m_axi_gmem2_awcache m_axi_gmem2_awprot m_axi_gmem2_awqos m_axi_gmem2_awvalid m_axi_gmem2_awready \
         m_axi_gmem2_wdata m_axi_gmem2_wstrb m_axi_gmem2_wlast m_axi_gmem2_wvalid m_axi_gmem2_wready \
         m_axi_gmem2_bresp m_axi_gmem2_bvalid m_axi_gmem2_bready \
         m_axi_gmem2_araddr m_axi_gmem2_arlen m_axi_gmem2_arsize m_axi_gmem2_arburst \
         m_axi_gmem2_arcache m_axi_gmem2_arprot m_axi_gmem2_arqos m_axi_gmem2_arvalid m_axi_gmem2_arready \
         m_axi_gmem2_rdata m_axi_gmem2_rresp m_axi_gmem2_rlast m_axi_gmem2_rvalid m_axi_gmem2_rready} \
        xilinx.com:interface:aximm_rtl:1.0 \
        [ipx::current_core]
    set gmem2_intf [ipx::get_bus_interfaces m_axi_gmem2 -of_objects $core]
}
puts "INFO: m_axi_gmem2 interface: [get_property NAME $gmem2_intf]"

# ==============================================================================
# 5. Associate all bus interfaces with ap_clk (single-shot, not per-interface)
# ==============================================================================
# Using set_property on ASSOCIATED_BUSIF directly (colon-separated) is more
# reliable than calling ipx::associate_bus_interfaces multiple times.
# Use get-or-add pattern in case auto-inference already created the parameter.
set busif_param [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects [ipx::get_bus_interfaces ap_clk -of_objects $core] -quiet]
if {$busif_param eq ""} {
    set busif_param [ipx::add_bus_parameter ASSOCIATED_BUSIF [ipx::get_bus_interfaces ap_clk -of_objects $core]]
}
set_property value "s_axi_control:m_axi_gmem0:m_axi_gmem1:m_axi_gmem2" $busif_param

set reset_param [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects [ipx::get_bus_interfaces ap_clk -of_objects $core] -quiet]
if {$reset_param eq ""} {
    set reset_param [ipx::add_bus_parameter ASSOCIATED_RESET [ipx::get_bus_interfaces ap_clk -of_objects $core]]
}
set_property value "ap_rst_n" $reset_param

# ==============================================================================
# 6. Set up register map for s_axi_control (kernel arguments)
# ==============================================================================
# Create address space for each AXI master
ipx::add_address_space gmem0_space $core
set_property master_address_space_ref gmem0_space \
    [ipx::get_bus_interfaces m_axi_gmem0 -of_objects $core]
set_property range 16E [ipx::get_address_spaces gmem0_space -of_objects $core]
set_property width 64  [ipx::get_address_spaces gmem0_space -of_objects $core]

ipx::add_address_space gmem1_space $core
set_property master_address_space_ref gmem1_space \
    [ipx::get_bus_interfaces m_axi_gmem1 -of_objects $core]
set_property range 16E [ipx::get_address_spaces gmem1_space -of_objects $core]
set_property width 64  [ipx::get_address_spaces gmem1_space -of_objects $core]

ipx::add_address_space gmem2_space $core
set_property master_address_space_ref gmem2_space \
    [ipx::get_bus_interfaces m_axi_gmem2 -of_objects $core]
set_property range 16E [ipx::get_address_spaces gmem2_space -of_objects $core]
set_property width 64  [ipx::get_address_spaces gmem2_space -of_objects $core]

# Create memory map for s_axi_control with register definitions
set mem_map [ipx::add_memory_map s_axi_control $core]
set_property slave_memory_map_ref s_axi_control \
    [ipx::get_bus_interfaces s_axi_control -of_objects $core]

set addr_block [ipx::add_address_block Reg0 $mem_map]
set_property range  0x40   $addr_block
set_property width  32     $addr_block
set_property usage  register $addr_block

# ap_ctrl register (0x00)
set reg [ipx::add_register CTRL $addr_block]
set_property address_offset 0x00 $reg
set_property size           32   $reg

# in1 register (0x10)
set reg [ipx::add_register in1 $addr_block]
set_property address_offset 0x10 $reg
set_property size           64   $reg

# in2 register (0x18)
set reg [ipx::add_register in2 $addr_block]
set_property address_offset 0x18 $reg
set_property size           64   $reg

# out_r register (0x20)
set reg [ipx::add_register out_r $addr_block]
set_property address_offset 0x20 $reg
set_property size           64   $reg

# size register (0x28)
set reg [ipx::add_register size $addr_block]
set_property address_offset 0x28 $reg
set_property size           32   $reg

# ==============================================================================
# 7. Save the IP
# ==============================================================================
set_property core_revision 2 $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core

close_project

# ==============================================================================
# 8. Create the .xo via package_xo
# ==============================================================================
if {[file exists $xo_path]} {
    file delete -force $xo_path
}

package_xo \
    -xo_path      $xo_path \
    -kernel_name  $kernel_name \
    -ip_directory $ip_dir \
    -kernel_xml   kernel.xml \
    -ctrl_protocol ap_ctrl_hs

puts "INFO: Successfully created $xo_path"

# ==============================================================================
# 9. Clean up temporary directories
# ==============================================================================
file delete -force $proj_dir

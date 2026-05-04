# ==============================================================================
# pack_krnl_matmul.tcl — Package krnl_matmul RTL as a Vitis .xo kernel object
#
# Packages the 32x32 systolic array matmul kernel including all RTL sources.
#
# Usage (from Makefile):
#   vivado -mode batch -source pack_krnl_matmul.tcl -notrace
#
# Produces: krnl_matmul.xo
# ==============================================================================

set kernel_name "krnl_matmul"
set xo_path     "krnl_matmul.xo"
set part        "xcu280-fsvh2892-2L-e"

set rtl_files [list \
    "src/krnl_matmul.sv" \
    "src/krnl_vadd_ctrl.v" \
    "src/matmul_top.sv" \
    "src/mxu.sv" \
    "src/systolic_array.sv" \
    "src/pe.sv" \
    "src/fp32_add.sv" \
    "src/fp32_mul.sv" \
    "src/fifo4.sv" \
]

puts "INFO: Packaging RTL kernel '$kernel_name'"

# ==============================================================================
# 1. Create temporary Vivado project
# ==============================================================================
set proj_dir "./_pack_project_matmul"
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
set ip_dir "./ip_repo_matmul"

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
set clk_intf [ipx::get_bus_interfaces ap_clk -of_objects $core -quiet]
if {$clk_intf eq ""} {
    set clk_intf [ipx::add_bus_interface ap_clk $core]
    set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $clk_intf
    set_property bus_type_vlnv xilinx.com:signal:clock:1.0 $clk_intf
    set_property interface_mode slave $clk_intf
    ipx::add_port_map CLK $clk_intf
    set_property physical_name ap_clk [ipx::get_port_maps CLK -of_objects $clk_intf]
}

set rst_intf [ipx::get_bus_interfaces ap_rst_n -of_objects $core -quiet]
if {$rst_intf eq ""} {
    set rst_intf [ipx::add_bus_interface ap_rst_n $core]
    set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 $rst_intf
    set_property bus_type_vlnv xilinx.com:signal:reset:1.0 $rst_intf
    set_property interface_mode slave $rst_intf
    ipx::add_port_map RST $rst_intf
    set_property physical_name ap_rst_n [ipx::get_port_maps RST -of_objects $rst_intf]
    set_property value ACTIVE_LOW [ipx::add_bus_parameter POLARITY $rst_intf]
}

foreach intf_name {s_axi_control m_axi_gmem0 m_axi_gmem1 m_axi_gmem2} {
    set intf [ipx::get_bus_interfaces $intf_name -of_objects $core -quiet]
    if {$intf eq ""} {
        puts "WARNING: $intf_name not inferred, attempting infer"
    }
    puts "INFO: $intf_name interface present"
}

# ==============================================================================
# 5. Associate interfaces with ap_clk
# ==============================================================================
set busif_param [ipx::get_bus_parameters ASSOCIATED_BUSIF \
    -of_objects [ipx::get_bus_interfaces ap_clk -of_objects $core] -quiet]
if {$busif_param eq ""} {
    set busif_param [ipx::add_bus_parameter ASSOCIATED_BUSIF \
        [ipx::get_bus_interfaces ap_clk -of_objects $core]]
}
set_property value "s_axi_control:m_axi_gmem0:m_axi_gmem1:m_axi_gmem2" $busif_param

set reset_param [ipx::get_bus_parameters ASSOCIATED_RESET \
    -of_objects [ipx::get_bus_interfaces ap_clk -of_objects $core] -quiet]
if {$reset_param eq ""} {
    set reset_param [ipx::add_bus_parameter ASSOCIATED_RESET \
        [ipx::get_bus_interfaces ap_clk -of_objects $core]]
}
set_property value "ap_rst_n" $reset_param

# ==============================================================================
# 6. Address spaces for AXI masters
# ==============================================================================
foreach {space intf} {gmem0_space m_axi_gmem0  gmem1_space m_axi_gmem1  gmem2_space m_axi_gmem2} {
    ipx::add_address_space $space $core
    set_property master_address_space_ref $space \
        [ipx::get_bus_interfaces $intf -of_objects $core]
    set_property range 16E [ipx::get_address_spaces $space -of_objects $core]
    set_property width 64  [ipx::get_address_spaces $space -of_objects $core]
}

# ==============================================================================
# 7. Register map for s_axi_control
# ==============================================================================
set mem_map   [ipx::add_memory_map s_axi_control $core]
set_property slave_memory_map_ref s_axi_control \
    [ipx::get_bus_interfaces s_axi_control -of_objects $core]

set addr_block [ipx::add_address_block Reg0 $mem_map]
set_property range  0x40     $addr_block
set_property width  32       $addr_block
set_property usage  register $addr_block

foreach {name off sz} {CTRL 0x00 32  in1 0x10 64  in2 0x18 64  out_r 0x20 64} {
    set reg [ipx::add_register $name $addr_block]
    set_property address_offset $off $reg
    set_property size           $sz  $reg
}

# ==============================================================================
# 8. Save IP
# ==============================================================================
set_property core_revision 1 $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
close_project

# ==============================================================================
# 9. Create .xo
# ==============================================================================
if {[file exists $xo_path]} { file delete -force $xo_path }

package_xo \
    -xo_path      $xo_path \
    -kernel_name  $kernel_name \
    -ip_directory $ip_dir \
    -kernel_xml   krnl_matmul.xml \
    -ctrl_protocol ap_ctrl_hs

puts "INFO: Successfully created $xo_path"

file delete -force $proj_dir

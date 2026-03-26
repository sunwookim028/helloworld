# package_kernel.tcl — Package RTL sources as a Vitis kernel (.xo)
#
# Usage (called from Makefile):
#   vivado -mode batch -source package_kernel.tcl \
#          -tclargs <kernel_name> <xo_output_path> <kernel_xml> <rtl_file1> [rtl_file2 ...]
#
# Requires: Vivado 2023.2 (or 2022.1+) with Vitis install (package_xo command).
# The package_xo command is provided by sourcing the Vitis helper TCL script
# that Vivado loads automatically when Vitis is installed.
#
# Change from previous version: RTL files are now passed as explicit arguments
# instead of globbing a directory. This allows packaging only the VADD DMA
# engine without pulling in unrelated RTL (e.g. systolic array modules).

set kernel_name [lindex $argv 0]   ;# e.g. krnl_vadd
set xo_path     [lindex $argv 1]   ;# e.g. krnl_vadd.xo
set kernel_xml  [lindex $argv 2]   ;# e.g. kernel.xml

# Remaining args are individual RTL source file paths
set rtl_files [lrange $argv 3 end]

if {[llength $rtl_files] == 0} {
    error "No RTL source files specified. Pass files as: <kern> <xo> <xml> file1.sv file2.v ..."
}

# Target part for Alveo U280
set part "xcu280-fsvh2892-2L-e"

puts "INFO: Packaging kernel '$kernel_name'"
puts "INFO:   Output XO   : $xo_path"
puts "INFO:   kernel.xml  : $kernel_xml"
puts "INFO:   RTL files   : $rtl_files"

# ---------------------------------------------------------------------------
# 1. Create a temporary Vivado project
# ---------------------------------------------------------------------------
set proj_dir "./kernel_pack_tmp"
create_project -force ${kernel_name}_pack $proj_dir -part $part

# ---------------------------------------------------------------------------
# 2. Add RTL source files (explicit list, not glob)
# ---------------------------------------------------------------------------
foreach f $rtl_files {
    if {![file exists $f]} {
        error "RTL source file not found: $f"
    }
}
add_files $rtl_files
set_property top $kernel_name [current_fileset]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------------
# 3. Package as Vivado IP
# ---------------------------------------------------------------------------
set ip_dir "./packaged_kernel_${kernel_name}"

ipx::package_project \
    -root_dir    $ip_dir \
    -vendor      user.org \
    -library     user \
    -taxonomy    /UserIP \
    -import_files \
    -set_current false

# ---------------------------------------------------------------------------
# 4. Open the IP for editing — associate AXI interfaces with ap_clk
# ---------------------------------------------------------------------------
ipx::edit_ip_in_project \
    -upgrade true \
    -name    tmp_edit_project \
    -directory $ip_dir \
    $ip_dir/component.xml

set core [ipx::current_core]

# Associate all bus interfaces with ap_clk
foreach bus_intf [ipx::get_bus_interfaces -of_objects $core] {
    set intf_name [get_property NAME $bus_intf]
    # Skip clock/reset interfaces themselves
    if {$intf_name eq "ap_clk" || $intf_name eq "ap_rst_n"} { continue }
    catch {
        ipx::associate_bus_interfaces \
            -busif $intf_name \
            -clock ap_clk \
            $core
    }
}

# Set core metadata
set_property core_revision 1 $core
ipx::update_checksums $core
ipx::save_core $core

close_project -delete

# ---------------------------------------------------------------------------
# 5. Create the .xo kernel object
# ---------------------------------------------------------------------------
# Remove stale .xo if it exists
if {[file exists $xo_path]} {
    file delete -force $xo_path
}

package_xo \
    -xo_path     $xo_path \
    -kernel_name $kernel_name \
    -ip_directory $ip_dir \
    -kernel_xml  $kernel_xml

puts "INFO: Successfully created $xo_path"

# Clean up temporary project directory
file delete -force $proj_dir

echo "Setting up Vitis environment ..."

# function to check if a tool is available
function check_tool {
    if [ -x "$(command -v $1)" ]; then
        echo "  $1 is `which $1`"
	return 0
    else
        echo "ERROR: $1 is not available"
        return 1
    fi
}

## dev tools
if [ $HOSTNAME = brg-zhang-xcel.ece.cornell.edu ]; then
    echo "On deployment server $HOSTNAME, using Vitis-2023.2"
    export XILINXD_LICENSE_FILE=2100@flex.ece.cornell.edu
    source /opt/xilinx/Vitis/2023.2/settings64.sh > /dev/null
else
    version=2023.2
    if [ ! -z "$1" ]; then
        version=$1
    fi
    echo "On development server $HOSTNAME, using Vitis-$version"
    # source /opt/xilinx/Vitis/$version/settings64.sh > /dev/null (broken)
    # temporary workaround
    source /opt/xilinx/Vitis/$version/.settings64-Vitis_Embedded_Development.sh > /dev/null
    source /opt/xilinx/Vivado/$version/.settings64-Vivado.sh > /dev/null
    source /opt/xilinx/Model_Composer/$version/.settings64-Model_Composer.sh > /dev/null
    source /opt/xilinx/Vitis_HLS/$version/.settings64-Vitis_HLS.sh > /dev/null
fi

echo "Vitis app dev tools:"
check_tool g++
check_tool v++

echo "HLS dev tools:"
check_tool vitis_hls
if [ -z "$XILINX_HLS" ]; then
    export XILINX_HLS=$(which vitis_hls)
fi

echo "RTL dev tools:"
check_tool vivado
check_tool xvlog
check_tool xelab
check_tool xsim

## runtime tools
if [ $HOSTNAME = brg-zhang-xcel.ece.cornell.edu ]; then
    echo "On deployment server $HOSTNAME, loading XRT"
    source /opt/xilinx/xrt/setup.sh > /dev/null
    echo "Runtime tools:"
    check_tool vitis_analyzer
    check_tool xbutil
else
    echo "XRT is not available on development server $HOSTNAME, Vitis sw_emu/hw_emu/hw is not supported"
fi

echo "Setup finished."
#!/bin/sh

# 
# v++(TM)
# runme.sh: a v++-generated Runs Script for UNIX
# Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
# Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
# 

if [ -z "$PATH" ]; then
  PATH=/opt/xilinx/Vitis_HLS/2023.2/bin:/opt/xilinx/Vitis/2023.2/bin:/opt/xilinx/Vitis/2023.2/bin
else
  PATH=/opt/xilinx/Vitis_HLS/2023.2/bin:/opt/xilinx/Vitis/2023.2/bin:/opt/xilinx/Vitis/2023.2/bin:$PATH
fi
export PATH

if [ -z "$LD_LIBRARY_PATH" ]; then
  LD_LIBRARY_PATH=
else
  LD_LIBRARY_PATH=:$LD_LIBRARY_PATH
fi
export LD_LIBRARY_PATH

HD_PWD='/work/shared/users/phd/sk3463/projects/helloworld/hbm_simple_xrt/_x/krnl_vadd_desc/krnl_vadd_desc'
cd "$HD_PWD"

HD_LOG=runme.log
/bin/touch $HD_LOG

ISEStep="./ISEWrap.sh"
EAStep()
{
     $ISEStep $HD_LOG "$@" >> $HD_LOG 2>&1
     if [ $? -ne 0 ]
     then
         exit
     fi
}

# EAStep vitis_hls -f krnl_vadd_desc.tcl -messageDb vitis_hls.pb

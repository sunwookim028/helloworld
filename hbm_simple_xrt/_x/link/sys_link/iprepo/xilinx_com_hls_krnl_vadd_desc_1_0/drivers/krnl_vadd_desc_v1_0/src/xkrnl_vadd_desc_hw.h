// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2023.2 (64-bit)
// Tool Version Limit: 2023.10
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
// control
// 0x00 : Control signals
//        bit 0  - ap_start (Read/Write/COH)
//        bit 1  - ap_done (Read)
//        bit 2  - ap_idle (Read)
//        bit 3  - ap_ready (Read/COR)
//        bit 4  - ap_continue (Read/Write/SC)
//        bit 7  - auto_restart (Read/Write)
//        bit 9  - interrupt (Read)
//        others - reserved
// 0x04 : Global Interrupt Enable Register
//        bit 0  - Global Interrupt Enable (Read/Write)
//        others - reserved
// 0x08 : IP Interrupt Enable Register (Read/Write)
//        bit 0 - enable ap_done interrupt (Read/Write)
//        bit 1 - enable ap_ready interrupt (Read/Write)
//        others - reserved
// 0x0c : IP Interrupt Status Register (Read/TOW)
//        bit 0 - ap_done (Read/TOW)
//        bit 1 - ap_ready (Read/TOW)
//        others - reserved
// 0x10 : Data signal of desc_mem
//        bit 31~0 - desc_mem[31:0] (Read/Write)
// 0x14 : Data signal of desc_mem
//        bit 31~0 - desc_mem[63:32] (Read/Write)
// 0x18 : reserved
// 0x1c : Data signal of data_mem0
//        bit 31~0 - data_mem0[31:0] (Read/Write)
// 0x20 : Data signal of data_mem0
//        bit 31~0 - data_mem0[63:32] (Read/Write)
// 0x24 : reserved
// 0x28 : Data signal of data_mem1
//        bit 31~0 - data_mem1[31:0] (Read/Write)
// 0x2c : Data signal of data_mem1
//        bit 31~0 - data_mem1[63:32] (Read/Write)
// 0x30 : reserved
// 0x34 : Data signal of data_mem2
//        bit 31~0 - data_mem2[31:0] (Read/Write)
// 0x38 : Data signal of data_mem2
//        bit 31~0 - data_mem2[63:32] (Read/Write)
// 0x3c : reserved
// 0x40 : Data signal of first_desc_addr
//        bit 31~0 - first_desc_addr[31:0] (Read/Write)
// 0x44 : Data signal of first_desc_addr
//        bit 31~0 - first_desc_addr[63:32] (Read/Write)
// 0x48 : reserved
// 0x4c : Data signal of max_descriptors
//        bit 31~0 - max_descriptors[31:0] (Read/Write)
// 0x50 : reserved
// (SC = Self Clear, COR = Clear on Read, TOW = Toggle on Write, COH = Clear on Handshake)

#define XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL              0x00
#define XKRNL_VADD_DESC_CONTROL_ADDR_GIE                  0x04
#define XKRNL_VADD_DESC_CONTROL_ADDR_IER                  0x08
#define XKRNL_VADD_DESC_CONTROL_ADDR_ISR                  0x0c
#define XKRNL_VADD_DESC_CONTROL_ADDR_DESC_MEM_DATA        0x10
#define XKRNL_VADD_DESC_CONTROL_BITS_DESC_MEM_DATA        64
#define XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM0_DATA       0x1c
#define XKRNL_VADD_DESC_CONTROL_BITS_DATA_MEM0_DATA       64
#define XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM1_DATA       0x28
#define XKRNL_VADD_DESC_CONTROL_BITS_DATA_MEM1_DATA       64
#define XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM2_DATA       0x34
#define XKRNL_VADD_DESC_CONTROL_BITS_DATA_MEM2_DATA       64
#define XKRNL_VADD_DESC_CONTROL_ADDR_FIRST_DESC_ADDR_DATA 0x40
#define XKRNL_VADD_DESC_CONTROL_BITS_FIRST_DESC_ADDR_DATA 64
#define XKRNL_VADD_DESC_CONTROL_ADDR_MAX_DESCRIPTORS_DATA 0x4c
#define XKRNL_VADD_DESC_CONTROL_BITS_MAX_DESCRIPTORS_DATA 32


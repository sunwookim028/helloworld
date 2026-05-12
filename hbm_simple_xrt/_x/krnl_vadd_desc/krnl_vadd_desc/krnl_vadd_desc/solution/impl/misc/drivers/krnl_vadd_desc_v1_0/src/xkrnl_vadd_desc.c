// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2023.2 (64-bit)
// Tool Version Limit: 2023.10
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
/***************************** Include Files *********************************/
#include "xkrnl_vadd_desc.h"

/************************** Function Implementation *************************/
#ifndef __linux__
int XKrnl_vadd_desc_CfgInitialize(XKrnl_vadd_desc *InstancePtr, XKrnl_vadd_desc_Config *ConfigPtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(ConfigPtr != NULL);

    InstancePtr->Control_BaseAddress = ConfigPtr->Control_BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    return XST_SUCCESS;
}
#endif

void XKrnl_vadd_desc_Start(XKrnl_vadd_desc *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL) & 0x80;
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL, Data | 0x01);
}

u32 XKrnl_vadd_desc_IsDone(XKrnl_vadd_desc *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL);
    return (Data >> 1) & 0x1;
}

u32 XKrnl_vadd_desc_IsIdle(XKrnl_vadd_desc *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL);
    return (Data >> 2) & 0x1;
}

u32 XKrnl_vadd_desc_IsReady(XKrnl_vadd_desc *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL);
    // check ap_start to see if the pcore is ready for next input
    return !(Data & 0x1);
}

void XKrnl_vadd_desc_Continue(XKrnl_vadd_desc *InstancePtr) {
    u32 Data;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL) & 0x80;
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL, Data | 0x10);
}

void XKrnl_vadd_desc_EnableAutoRestart(XKrnl_vadd_desc *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL, 0x80);
}

void XKrnl_vadd_desc_DisableAutoRestart(XKrnl_vadd_desc *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_AP_CTRL, 0);
}

void XKrnl_vadd_desc_Set_desc_mem(XKrnl_vadd_desc *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DESC_MEM_DATA, (u32)(Data));
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DESC_MEM_DATA + 4, (u32)(Data >> 32));
}

u64 XKrnl_vadd_desc_Get_desc_mem(XKrnl_vadd_desc *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DESC_MEM_DATA);
    Data += (u64)XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DESC_MEM_DATA + 4) << 32;
    return Data;
}

void XKrnl_vadd_desc_Set_data_mem0(XKrnl_vadd_desc *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM0_DATA, (u32)(Data));
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM0_DATA + 4, (u32)(Data >> 32));
}

u64 XKrnl_vadd_desc_Get_data_mem0(XKrnl_vadd_desc *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM0_DATA);
    Data += (u64)XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM0_DATA + 4) << 32;
    return Data;
}

void XKrnl_vadd_desc_Set_data_mem1(XKrnl_vadd_desc *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM1_DATA, (u32)(Data));
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM1_DATA + 4, (u32)(Data >> 32));
}

u64 XKrnl_vadd_desc_Get_data_mem1(XKrnl_vadd_desc *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM1_DATA);
    Data += (u64)XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM1_DATA + 4) << 32;
    return Data;
}

void XKrnl_vadd_desc_Set_data_mem2(XKrnl_vadd_desc *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM2_DATA, (u32)(Data));
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM2_DATA + 4, (u32)(Data >> 32));
}

u64 XKrnl_vadd_desc_Get_data_mem2(XKrnl_vadd_desc *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM2_DATA);
    Data += (u64)XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_DATA_MEM2_DATA + 4) << 32;
    return Data;
}

void XKrnl_vadd_desc_Set_first_desc_addr(XKrnl_vadd_desc *InstancePtr, u64 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_FIRST_DESC_ADDR_DATA, (u32)(Data));
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_FIRST_DESC_ADDR_DATA + 4, (u32)(Data >> 32));
}

u64 XKrnl_vadd_desc_Get_first_desc_addr(XKrnl_vadd_desc *InstancePtr) {
    u64 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_FIRST_DESC_ADDR_DATA);
    Data += (u64)XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_FIRST_DESC_ADDR_DATA + 4) << 32;
    return Data;
}

void XKrnl_vadd_desc_Set_max_descriptors(XKrnl_vadd_desc *InstancePtr, u32 Data) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_MAX_DESCRIPTORS_DATA, Data);
}

u32 XKrnl_vadd_desc_Get_max_descriptors(XKrnl_vadd_desc *InstancePtr) {
    u32 Data;

    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Data = XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_MAX_DESCRIPTORS_DATA);
    return Data;
}

void XKrnl_vadd_desc_InterruptGlobalEnable(XKrnl_vadd_desc *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_GIE, 1);
}

void XKrnl_vadd_desc_InterruptGlobalDisable(XKrnl_vadd_desc *InstancePtr) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_GIE, 0);
}

void XKrnl_vadd_desc_InterruptEnable(XKrnl_vadd_desc *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_IER);
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_IER, Register | Mask);
}

void XKrnl_vadd_desc_InterruptDisable(XKrnl_vadd_desc *InstancePtr, u32 Mask) {
    u32 Register;

    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    Register =  XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_IER);
    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_IER, Register & (~Mask));
}

void XKrnl_vadd_desc_InterruptClear(XKrnl_vadd_desc *InstancePtr, u32 Mask) {
    Xil_AssertVoid(InstancePtr != NULL);
    Xil_AssertVoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    XKrnl_vadd_desc_WriteReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_ISR, Mask);
}

u32 XKrnl_vadd_desc_InterruptGetEnabled(XKrnl_vadd_desc *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_IER);
}

u32 XKrnl_vadd_desc_InterruptGetStatus(XKrnl_vadd_desc *InstancePtr) {
    Xil_AssertNonvoid(InstancePtr != NULL);
    Xil_AssertNonvoid(InstancePtr->IsReady == XIL_COMPONENT_IS_READY);

    return XKrnl_vadd_desc_ReadReg(InstancePtr->Control_BaseAddress, XKRNL_VADD_DESC_CONTROL_ADDR_ISR);
}


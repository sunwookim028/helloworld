// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2023.2 (64-bit)
// Tool Version Limit: 2023.10
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
#ifndef __linux__

#include "xstatus.h"
#ifdef SDT
#include "xparameters.h"
#endif
#include "xkrnl_vadd_desc.h"

extern XKrnl_vadd_desc_Config XKrnl_vadd_desc_ConfigTable[];

#ifdef SDT
XKrnl_vadd_desc_Config *XKrnl_vadd_desc_LookupConfig(UINTPTR BaseAddress) {
	XKrnl_vadd_desc_Config *ConfigPtr = NULL;

	int Index;

	for (Index = (u32)0x0; XKrnl_vadd_desc_ConfigTable[Index].Name != NULL; Index++) {
		if (!BaseAddress || XKrnl_vadd_desc_ConfigTable[Index].Control_BaseAddress == BaseAddress) {
			ConfigPtr = &XKrnl_vadd_desc_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XKrnl_vadd_desc_Initialize(XKrnl_vadd_desc *InstancePtr, UINTPTR BaseAddress) {
	XKrnl_vadd_desc_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XKrnl_vadd_desc_LookupConfig(BaseAddress);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XKrnl_vadd_desc_CfgInitialize(InstancePtr, ConfigPtr);
}
#else
XKrnl_vadd_desc_Config *XKrnl_vadd_desc_LookupConfig(u16 DeviceId) {
	XKrnl_vadd_desc_Config *ConfigPtr = NULL;

	int Index;

	for (Index = 0; Index < XPAR_XKRNL_VADD_DESC_NUM_INSTANCES; Index++) {
		if (XKrnl_vadd_desc_ConfigTable[Index].DeviceId == DeviceId) {
			ConfigPtr = &XKrnl_vadd_desc_ConfigTable[Index];
			break;
		}
	}

	return ConfigPtr;
}

int XKrnl_vadd_desc_Initialize(XKrnl_vadd_desc *InstancePtr, u16 DeviceId) {
	XKrnl_vadd_desc_Config *ConfigPtr;

	Xil_AssertNonvoid(InstancePtr != NULL);

	ConfigPtr = XKrnl_vadd_desc_LookupConfig(DeviceId);
	if (ConfigPtr == NULL) {
		InstancePtr->IsReady = 0;
		return (XST_DEVICE_NOT_FOUND);
	}

	return XKrnl_vadd_desc_CfgInitialize(InstancePtr, ConfigPtr);
}
#endif

#endif


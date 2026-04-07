// ==============================================================
// Vitis HLS - High-Level Synthesis from C, C++ and OpenCL v2023.2 (64-bit)
// Tool Version Limit: 2023.10
// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2023 Advanced Micro Devices, Inc. All Rights Reserved.
// 
// ==============================================================
#ifndef XKRNL_VADD_DESC_H
#define XKRNL_VADD_DESC_H

#ifdef __cplusplus
extern "C" {
#endif

/***************************** Include Files *********************************/
#ifndef __linux__
#include "xil_types.h"
#include "xil_assert.h"
#include "xstatus.h"
#include "xil_io.h"
#else
#include <stdint.h>
#include <assert.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stddef.h>
#endif
#include "xkrnl_vadd_desc_hw.h"

/**************************** Type Definitions ******************************/
#ifdef __linux__
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#else
typedef struct {
#ifdef SDT
    char *Name;
#else
    u16 DeviceId;
#endif
    u64 Control_BaseAddress;
} XKrnl_vadd_desc_Config;
#endif

typedef struct {
    u64 Control_BaseAddress;
    u32 IsReady;
} XKrnl_vadd_desc;

typedef u32 word_type;

/***************** Macros (Inline Functions) Definitions *********************/
#ifndef __linux__
#define XKrnl_vadd_desc_WriteReg(BaseAddress, RegOffset, Data) \
    Xil_Out32((BaseAddress) + (RegOffset), (u32)(Data))
#define XKrnl_vadd_desc_ReadReg(BaseAddress, RegOffset) \
    Xil_In32((BaseAddress) + (RegOffset))
#else
#define XKrnl_vadd_desc_WriteReg(BaseAddress, RegOffset, Data) \
    *(volatile u32*)((BaseAddress) + (RegOffset)) = (u32)(Data)
#define XKrnl_vadd_desc_ReadReg(BaseAddress, RegOffset) \
    *(volatile u32*)((BaseAddress) + (RegOffset))

#define Xil_AssertVoid(expr)    assert(expr)
#define Xil_AssertNonvoid(expr) assert(expr)

#define XST_SUCCESS             0
#define XST_DEVICE_NOT_FOUND    2
#define XST_OPEN_DEVICE_FAILED  3
#define XIL_COMPONENT_IS_READY  1
#endif

/************************** Function Prototypes *****************************/
#ifndef __linux__
#ifdef SDT
int XKrnl_vadd_desc_Initialize(XKrnl_vadd_desc *InstancePtr, UINTPTR BaseAddress);
XKrnl_vadd_desc_Config* XKrnl_vadd_desc_LookupConfig(UINTPTR BaseAddress);
#else
int XKrnl_vadd_desc_Initialize(XKrnl_vadd_desc *InstancePtr, u16 DeviceId);
XKrnl_vadd_desc_Config* XKrnl_vadd_desc_LookupConfig(u16 DeviceId);
#endif
int XKrnl_vadd_desc_CfgInitialize(XKrnl_vadd_desc *InstancePtr, XKrnl_vadd_desc_Config *ConfigPtr);
#else
int XKrnl_vadd_desc_Initialize(XKrnl_vadd_desc *InstancePtr, const char* InstanceName);
int XKrnl_vadd_desc_Release(XKrnl_vadd_desc *InstancePtr);
#endif

void XKrnl_vadd_desc_Start(XKrnl_vadd_desc *InstancePtr);
u32 XKrnl_vadd_desc_IsDone(XKrnl_vadd_desc *InstancePtr);
u32 XKrnl_vadd_desc_IsIdle(XKrnl_vadd_desc *InstancePtr);
u32 XKrnl_vadd_desc_IsReady(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_Continue(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_EnableAutoRestart(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_DisableAutoRestart(XKrnl_vadd_desc *InstancePtr);

void XKrnl_vadd_desc_Set_desc_mem(XKrnl_vadd_desc *InstancePtr, u64 Data);
u64 XKrnl_vadd_desc_Get_desc_mem(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_Set_data_mem0(XKrnl_vadd_desc *InstancePtr, u64 Data);
u64 XKrnl_vadd_desc_Get_data_mem0(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_Set_data_mem1(XKrnl_vadd_desc *InstancePtr, u64 Data);
u64 XKrnl_vadd_desc_Get_data_mem1(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_Set_data_mem2(XKrnl_vadd_desc *InstancePtr, u64 Data);
u64 XKrnl_vadd_desc_Get_data_mem2(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_Set_first_desc_addr(XKrnl_vadd_desc *InstancePtr, u64 Data);
u64 XKrnl_vadd_desc_Get_first_desc_addr(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_Set_max_descriptors(XKrnl_vadd_desc *InstancePtr, u32 Data);
u32 XKrnl_vadd_desc_Get_max_descriptors(XKrnl_vadd_desc *InstancePtr);

void XKrnl_vadd_desc_InterruptGlobalEnable(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_InterruptGlobalDisable(XKrnl_vadd_desc *InstancePtr);
void XKrnl_vadd_desc_InterruptEnable(XKrnl_vadd_desc *InstancePtr, u32 Mask);
void XKrnl_vadd_desc_InterruptDisable(XKrnl_vadd_desc *InstancePtr, u32 Mask);
void XKrnl_vadd_desc_InterruptClear(XKrnl_vadd_desc *InstancePtr, u32 Mask);
u32 XKrnl_vadd_desc_InterruptGetEnabled(XKrnl_vadd_desc *InstancePtr);
u32 XKrnl_vadd_desc_InterruptGetStatus(XKrnl_vadd_desc *InstancePtr);

#ifdef __cplusplus
}
#endif

#endif

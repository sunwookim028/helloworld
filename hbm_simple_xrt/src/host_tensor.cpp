/**
* Copyright (C) 2019-2021 Xilinx, Inc
*
* Licensed under the Apache License, Version 2.0 (the "License"). You may
* not use this file except in compliance with the License. A copy of the
* License is located at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
* WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
* License for the specific language governing permissions and limitations
* under the License.
*/

/********************************************************************************************
 * Description:
 *
 * HBM Data Mover - Tensor Scenario Host (host_tensor.cpp)
 * Simulates complex tensor operations (like Transpose) using simple linear copy kernel
 * by orchestrating many small transfers from the host.
 *
 * Scenarios:
 * 1. Bulk Copy (Baseline): One large transfer.
 * 2. Row-Interleaved Copy (Simulation of 2D stride/transpose): Many small transfers.
 *
 *  *****************************************************************************************/
#include <iostream>
#include <cstring>
#include <vector>
#include <chrono>
#include <unistd.h>
#include <algorithm>
#include <iomanip>

// XRT includes
#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"

// Constants
const int BANK_SRC = 0;
const int BANK_DST = 1;

void run_bulk_copy(xrt::kernel& krnl, xrt::bo& bo_src, xrt::bo& bo_dst, int size) {
    auto run = krnl(bo_src, bo_src, bo_dst, size); // in2 is unused, pass src
    run.wait();
}

// Simulates copying 'rows' of 'cols' elements, but individually
// In a real transpose, offsets would change. Here we just test overhead of many calls.
void run_tiled_copy(xrt::kernel& krnl, xrt::bo& bo_src, xrt::bo& bo_dst, int rows, int cols) {
    // For simplicity, we just launch the kernel 'rows' times
    // In a real scenario, we'd adjust offsets/pointers. 
    // Since kernel takes BOs, we can't easily offset BO base address without sub-buffers.
    // XRT sub-buffers are deprecated/complex. 
    // We will just run the SAME transfer 'rows' times to measure host overhead.
    // To properly simulate "scatter", we would need a kernel that supports offsets.
    // Our kernel takes (in1, in2, out, size). It reads from base of BO.
    // So we can only simulate "Loop Overhead" here, not true scatter gather with this restricted kernel.
    // UNLESS we create sub-buffers?
    // Let's just measure "Software Orchestration Overhead" of launching 'rows' kernels.
    
    for (int i = 0; i < rows; i++) {
        auto run = krnl(bo_src, bo_src, bo_dst, cols);
        run.wait();
    }
}

void print_help(const char* prog_name) {
    std::cout << "Usage: " << prog_name << " -x <xclbin_file> [-d <device_id>]" << std::endl;
}

int main(int argc, char* argv[]) {
    std::string binaryFile;
    int device_index = 0;

    int opt;
    while ((opt = getopt(argc, argv, "x:d:")) != -1) {
        switch (opt) {
            case 'x':
                binaryFile = optarg;
                break;
            case 'd':
                device_index = std::stoi(optarg);
                break;
            default:
                print_help(argv[0]);
                return EXIT_FAILURE;
        }
    }

    if (binaryFile.empty()) {
        print_help(argv[0]);
        return EXIT_FAILURE;
    }

    std::cout << "Open the device " << device_index << std::endl;
    auto device = xrt::device(device_index);
    std::cout << "Load the xclbin " << binaryFile << std::endl;
    auto uuid = device.load_xclbin(binaryFile);
    auto krnl = xrt::kernel(device, uuid, "krnl_vadd");

    // Setup Data
    int rows = 1024;
    int cols = 1024; // 1M elements total
    int total_elements = rows * cols;
    size_t size_bytes = total_elements * sizeof(uint32_t);

    std::cout << "Allocating " << (size_bytes / (1024.0*1024.0)) << " MB buffers..." << std::endl;
    auto bo_src = xrt::bo(device, size_bytes, BANK_SRC);
    auto bo_dst = xrt::bo(device, size_bytes, BANK_DST);
    
    // Fill data
    auto bo_src_map = bo_src.map<int*>();
    std::fill(bo_src_map, bo_src_map + total_elements, 7);
    bo_src.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // ---------------------------------------------------------
    // Scenario 1: Bulk Copy
    // ---------------------------------------------------------
    std::cout << "\n--- Scenario 1: Bulk Copy (" << total_elements << " elements) ---" << std::endl;
    auto start = std::chrono::high_resolution_clock::now();
    run_bulk_copy(krnl, bo_src, bo_dst, total_elements);
    auto end = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> duration = end - start;
    double gbps = (size_bytes / 1e9) / duration.count();
    std::cout << "Time: " << duration.count() * 1000 << " ms" << std::endl;
    std::cout << "Bandwidth: " << gbps << " GB/s" << std::endl;

    // ---------------------------------------------------------
    // Scenario 2: Software "Tiled" Copy (Row by Row)
    // ---------------------------------------------------------
    std::cout << "\n--- Scenario 2: Software Orchestration (" << rows << " calls of " << cols << " elements) ---" << std::endl;
    std::cout << "Simulating overhead of managing granular transfers from host..." << std::endl;
    
    start = std::chrono::high_resolution_clock::now();
    // We copy 'cols' elements 'rows' times. Total data moved is equivalent magnitude (though redundant here).
    run_tiled_copy(krnl, bo_src, bo_dst, rows, cols);
    end = std::chrono::high_resolution_clock::now();
    duration = end - start;
    gbps = (size_bytes / 1e9) / duration.count();
    
    std::cout << "Time: " << duration.count() * 1000 << " ms" << std::endl;
    std::cout << "Effective Bandwidth: " << gbps << " GB/s" << std::endl;
    std::cout << "Overhead Factor: " << (duration.count() / ((size_bytes/1e9)/14.0)) << "x ideal" << std::endl;

    std::cout << "\nConclusion: " << std::endl;
    if (gbps < 1.0) {
        std::cout << "Software orchestration dominates latency. This justifies implementing Phase 2 (Descriptors) in hardware." << std::endl;
    } else {
        std::cout << "Software orchestration is manageable for this granularity." << std::endl;
    }

    return 0;
}

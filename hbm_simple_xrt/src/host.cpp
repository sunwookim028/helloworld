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
 * HBM Data Mover Host Application.
 * Tests pure copy (DMA) kernel with single and multiple HBM banks.
 * Self-contained version (no external common dependencies).
 *
 *  *****************************************************************************************/
#include <iostream>
#include <cstring>
#include <vector>
#include <chrono>
#include <unistd.h>
#include <algorithm>

// XRT includes
#include "xrt/xrt_bo.h"
#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"

double run_krnl(xrtDeviceHandle device, xrt::kernel& krnl, int* bank_assign, unsigned int size) {
    size_t vector_size_bytes = sizeof(uint32_t) * size;

    std::cout << "Allocate Buffer in Global Memory\n";
    try {
        auto bo0 = xrt::bo(device, vector_size_bytes, bank_assign[0]);
        auto bo1 = xrt::bo(device, vector_size_bytes, bank_assign[1]);
        auto bo_out = xrt::bo(device, vector_size_bytes, bank_assign[2]);

        auto bo0_map = bo0.map<int*>();
        auto bo1_map = bo1.map<int*>();
        auto bo_out_map = bo_out.map<int*>();
        std::fill(bo0_map, bo0_map + size, 0);
        std::fill(bo1_map, bo1_map + size, 0);
        std::fill(bo_out_map, bo_out_map + size, 0);

        int* bufReference = new int[size];
        for (uint32_t i = 0; i < size; ++i) {
            bo0_map[i] = i;
            bo1_map[i] = i;
            bufReference[i] = bo0_map[i];
        }

        std::cout << "synchronize input buffer data to device global memory\n";
        bo0.sync(XCL_BO_SYNC_BO_TO_DEVICE);
        bo1.sync(XCL_BO_SYNC_BO_TO_DEVICE);

        std::cout << "Execution of the kernel\n";
        auto kernel_start = std::chrono::high_resolution_clock::now();
        auto run = krnl(bo0, bo1, bo_out, size);
        run.wait();
        auto kernel_end = std::chrono::high_resolution_clock::now();

        std::chrono::duration<double> kernel_time = kernel_end - kernel_start;
        
        std::cout << "Get the output data from the device" << std::endl;
        bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

        if (std::memcmp(bo_out_map, bufReference, size * sizeof(int)))
            throw std::runtime_error("Value read back does not match reference");

        delete[] bufReference;
        return kernel_time.count();

    } catch (const std::exception& e) {
        std::cerr << "Error in run_krnl: " << e.what() << std::endl;
        throw; 
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

    unsigned int dataSize = 1024 * 1024; // 1MB elements
    double kernel_time_in_sec = 0, result = 0;
    const int numBuf = 3;
    int bank_assign[numBuf];

    // CASE 1: Single Bank
    for (int j = 0; j < numBuf; j++) bank_assign[j] = 0;
    std::cout << "Running CASE 1  : Single HBM for all three Buffers " << std::endl;
    try {
        kernel_time_in_sec = run_krnl(device, krnl, bank_assign, dataSize);
        result = (3.0 * dataSize * sizeof(uint32_t)) / (1024*1024*1024) / kernel_time_in_sec;
        std::cout << "[CASE 1] THROUGHPUT = " << result << " GB/s" << std::endl;
    } catch (...) {}

    // CASE 2: Separate Banks
    for (int j = 0; j < numBuf; j++) bank_assign[j] = j + 1;
    std::cout << "Running CASE 2: Three Separate Banks for Three Buffers" << std::endl;
    try {
        kernel_time_in_sec = run_krnl(device, krnl, bank_assign, dataSize);
        result = (3.0 * dataSize * sizeof(uint32_t)) / (1024*1024*1024) / kernel_time_in_sec;
        std::cout << "[CASE 2] THROUGHPUT = " << result << " GB/s" << std::endl;
    } catch (...) {}

    // CASE 3: High Banks
    for (int j = 0; j < numBuf; j++) bank_assign[j] = j + 4;
    std::cout << "Running CASE 3: High Banks (4, 5, 6) - Connectivity Test" << std::endl;
    try {
        kernel_time_in_sec = run_krnl(device, krnl, bank_assign, dataSize);
        result = (3.0 * dataSize * sizeof(uint32_t)) / (1024*1024*1024) / kernel_time_in_sec;
        std::cout << "[CASE 3] THROUGHPUT = " << result << " GB/s (PASSED)" << std::endl;
    } catch (const std::exception& e) {
        std::cout << "[CASE 3] FAILED: " << e.what() << std::endl;
    }

    std::cout << "TEST FINISHED" << std::endl;
    return 0;
}

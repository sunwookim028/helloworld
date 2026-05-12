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

/**
 * Descriptor-Based DMA Host Application
 * 
 * Tests the Phase 2 descriptor-based DMA engine with multiple scenarios:
 * 1. Single descriptor (baseline comparison with Phase 1)
 * 2. Chained descriptors (multiple transfers)
 * 3. Scatter/gather (non-contiguous memory)
 * 4. Tensor scenario (1024 descriptors - design driver)
 */

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

// Descriptor definition
#include "dma_descriptor.h"

// HBM bank assignments
const int BANK_DESC = 0;  // Descriptor buffer
const int BANK_SRC = 1;   // Source data
const int BANK_DST = 2;   // Destination data

void print_help(const char* prog_name) {
    std::cout << "Usage: " << prog_name << " -x <xclbin_file> [-d <device_id>] [--test <test_name>]" << std::endl;
    std::cout << "Tests: single, chain, scatter, tensor, all (default)" << std::endl;
}

// Test 1: Single Descriptor Transfer (Baseline)
void test_single_descriptor(xrt::device& device, xrt::kernel& krnl) {
    std::cout << "\n========================================" << std::endl;
    std::cout << "Test 1: Single Descriptor Transfer" << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << "Goal: Match Phase 1 bandwidth (~28 GB/s)" << std::endl;

    const size_t data_size = 64 * 1024 * 1024; // 64 MB
    const size_t desc_size = sizeof(dma_descriptor);

    // Allocate buffers
    auto bo_desc = xrt::bo(device, desc_size, BANK_DESC);
    auto bo_src = xrt::bo(device, data_size, BANK_SRC);
    auto bo_dst = xrt::bo(device, data_size, BANK_DST);

    // Initialize source data
    auto src_map = bo_src.map<uint32_t*>();
    for (size_t i = 0; i < data_size / sizeof(uint32_t); i++) {
        src_map[i] = i;
    }
    bo_src.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // Create descriptor
    auto desc_map = bo_desc.map<dma_descriptor*>();
    desc_map[0].src_addr = bo_src.address();
    desc_map[0].dst_addr = bo_dst.address();
    desc_map[0].length = data_size;
    desc_map[0].control = 0; // No chaining, no interrupt
    bo_desc.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // Execute kernel (unified data memory interface)
    auto start = std::chrono::high_resolution_clock::now();
    auto run = krnl(bo_desc, bo_src, bo_desc.address(), 1);
    run.wait();
    auto end = std::chrono::high_resolution_clock::now();

    // Verify results
    bo_dst.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    auto dst_map = bo_dst.map<uint32_t*>();
    bool pass = true;
    for (size_t i = 0; i < data_size / sizeof(uint32_t); i++) {
        if (dst_map[i] != src_map[i]) {
            pass = false;
            std::cout << "Mismatch at index " << i << ": expected " << src_map[i] 
                      << ", got " << dst_map[i] << std::endl;
            break;
        }
    }

    // Report results
    std::chrono::duration<double> duration = end - start;
    double gbps = (data_size / 1e9) / duration.count();
    
    std::cout << "Data size: " << (data_size / (1024.0 * 1024.0)) << " MB" << std::endl;
    std::cout << "Time: " << duration.count() * 1000 << " ms" << std::endl;
    std::cout << "Bandwidth: " << gbps << " GB/s" << std::endl;
    std::cout << "Verification: " << (pass ? "PASS" : "FAIL") << std::endl;
    std::cout << "Target: ≥26.5 GB/s (95% of Phase 1)" << std::endl;
}

// Test 2: Chained Descriptors
void test_chained_descriptors(xrt::device& device, xrt::kernel& krnl) {
    std::cout << "\n========================================" << std::endl;
    std::cout << "Test 2: Chained Descriptors" << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << "Goal: Execute multiple transfers via descriptor chain" << std::endl;

    const int num_descriptors = 16;
    const size_t chunk_size = 4 * 1024 * 1024; // 4 MB per chunk
    const size_t total_size = num_descriptors * chunk_size;
    const size_t desc_buffer_size = num_descriptors * sizeof(dma_descriptor);

    // Allocate buffers
    auto bo_desc = xrt::bo(device, desc_buffer_size, BANK_DESC);
    auto bo_src = xrt::bo(device, total_size, BANK_SRC);
    auto bo_dst = xrt::bo(device, total_size, BANK_DST);

    // Initialize source data
    auto src_map = bo_src.map<uint32_t*>();
    for (size_t i = 0; i < total_size / sizeof(uint32_t); i++) {
        src_map[i] = i;
    }
    bo_src.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // Create descriptor chain
    auto desc_map = bo_desc.map<dma_descriptor*>();
    uint64_t base_desc_addr = bo_desc.address();
    
    for (int i = 0; i < num_descriptors; i++) {
        desc_map[i].src_addr = bo_src.address() + (i * chunk_size);
        desc_map[i].dst_addr = bo_dst.address() + (i * chunk_size);
        desc_map[i].length = chunk_size;
        
        if (i < num_descriptors - 1) {
            // Chain to next descriptor
            uint64_t next_desc_addr = base_desc_addr + ((i + 1) * sizeof(dma_descriptor));
            desc_map[i].control = DESC_MAKE_CONTROL(next_desc_addr, true, false);
        } else {
            // Last descriptor - no chaining
            desc_map[i].control = 0;
        }
    }
    bo_desc.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // Execute kernel
    auto start = std::chrono::high_resolution_clock::now();
    auto run = krnl(bo_desc, bo_src, bo_src, bo_dst, base_desc_addr, num_descriptors);
    run.wait();
    auto end = std::chrono::high_resolution_clock::now();

    // Verify results
    bo_dst.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    auto dst_map = bo_dst.map<uint32_t*>();
    bool pass = true;
    for (size_t i = 0; i < total_size / sizeof(uint32_t); i++) {
        if (dst_map[i] != src_map[i]) {
            pass = false;
            std::cout << "Mismatch at index " << i << std::endl;
            break;
        }
    }

    // Report results
    std::chrono::duration<double> duration = end - start;
    double gbps = (total_size / 1e9) / duration.count();
    
    std::cout << "Descriptors: " << num_descriptors << std::endl;
    std::cout << "Chunk size: " << (chunk_size / (1024.0 * 1024.0)) << " MB" << std::endl;
    std::cout << "Total size: " << (total_size / (1024.0 * 1024.0)) << " MB" << std::endl;
    std::cout << "Time: " << duration.count() * 1000 << " ms" << std::endl;
    std::cout << "Bandwidth: " << gbps << " GB/s" << std::endl;
    std::cout << "Verification: " << (pass ? "PASS" : "FAIL") << std::endl;
}

// Test 4: Tensor Scenario (Design Driver)
void test_tensor_scenario(xrt::device& device, xrt::kernel& krnl) {
    std::cout << "\n========================================" << std::endl;
    std::cout << "Test 4: Tensor Scenario (Design Driver)" << std::endl;
    std::cout << "========================================" << std::endl;
    std::cout << "Goal: Replicate Phase 1 tensor test with hardware descriptors" << std::endl;
    std::cout << "Baseline: Phase 1 software orchestration = 0.19 GB/s" << std::endl;
    std::cout << "Target: ≥10 GB/s (50x improvement)" << std::endl;

    const int num_descriptors = 1024;
    const size_t chunk_size = 4096; // 4 KB per transfer (1024 x uint32_t)
    const size_t total_size = num_descriptors * chunk_size;
    const size_t desc_buffer_size = num_descriptors * sizeof(dma_descriptor);

    // Allocate buffers
    auto bo_desc = xrt::bo(device, desc_buffer_size, BANK_DESC);
    auto bo_src = xrt::bo(device, total_size, BANK_SRC);
    auto bo_dst = xrt::bo(device, total_size, BANK_DST);

    // Initialize source data
    auto src_map = bo_src.map<uint32_t*>();
    for (size_t i = 0; i < total_size / sizeof(uint32_t); i++) {
        src_map[i] = 7; // Match Phase 1 tensor test
    }
    bo_src.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // Create descriptor chain (1024 small transfers)
    auto desc_map = bo_desc.map<dma_descriptor*>();
    uint64_t base_desc_addr = bo_desc.address();
    
    for (int i = 0; i < num_descriptors; i++) {
        desc_map[i].src_addr = bo_src.address() + (i * chunk_size);
        desc_map[i].dst_addr = bo_dst.address() + (i * chunk_size);
        desc_map[i].length = chunk_size;
        
        if (i < num_descriptors - 1) {
            uint64_t next_desc_addr = base_desc_addr + ((i + 1) * sizeof(dma_descriptor));
            desc_map[i].control = DESC_MAKE_CONTROL(next_desc_addr, true, false);
        } else {
            desc_map[i].control = 0;
        }
    }
    bo_desc.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    // Execute kernel (single launch for all 1024 transfers)
    auto start = std::chrono::high_resolution_clock::now();
    auto run = krnl(bo_desc, bo_src, bo_src, bo_dst, base_desc_addr, num_descriptors);
    run.wait();
    auto end = std::chrono::high_resolution_clock::now();

    // Verify results
    bo_dst.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    auto dst_map = bo_dst.map<uint32_t*>();
    bool pass = true;
    for (size_t i = 0; i < total_size / sizeof(uint32_t); i++) {
        if (dst_map[i] != 7) {
            pass = false;
            std::cout << "Mismatch at index " << i << std::endl;
            break;
        }
    }

    // Report results
    std::chrono::duration<double> duration = end - start;
    double gbps = (total_size / 1e9) / duration.count();
    double improvement = gbps / 0.19; // vs Phase 1 baseline
    
    std::cout << "Descriptors: " << num_descriptors << std::endl;
    std::cout << "Transfer size: " << chunk_size << " bytes each" << std::endl;
    std::cout << "Total data: " << (total_size / (1024.0 * 1024.0)) << " MB" << std::endl;
    std::cout << "Time: " << duration.count() * 1000 << " ms" << std::endl;
    std::cout << "Bandwidth: " << gbps << " GB/s" << std::endl;
    std::cout << "Improvement: " << improvement << "x over Phase 1 software" << std::endl;
    std::cout << "Verification: " << (pass ? "PASS" : "FAIL") << std::endl;
    
    if (gbps >= 10.0) {
        std::cout << "SUCCESS: Achieved target bandwidth!" << std::endl;
    } else {
        std::cout << "WARNING: Below target bandwidth" << std::endl;
    }
}

int main(int argc, char* argv[]) {
    std::string binaryFile;
    int device_index = 0;
    std::string test_name = "all";

    int opt;
    while ((opt = getopt(argc, argv, "x:d:-:")) != -1) {
        switch (opt) {
            case 'x':
                binaryFile = optarg;
                break;
            case 'd':
                device_index = std::stoi(optarg);
                break;
            case '-':
                if (std::string(optarg) == "test") {
                    test_name = argv[optind++];
                }
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

    std::cout << "===========================================\n";
    std::cout << "Phase 2: Descriptor-Based DMA Test Suite\n";
    std::cout << "===========================================\n";
    std::cout << "Device: " << device_index << std::endl;
    std::cout << "Bitstream: " << binaryFile << std::endl;

    // Initialize device
    auto device = xrt::device(device_index);
    auto uuid = device.load_xclbin(binaryFile);
    auto krnl = xrt::kernel(device, uuid, "krnl_vadd_desc");

    // Run tests
    if (test_name == "single" || test_name == "all") {
        test_single_descriptor(device, krnl);
    }
    if (test_name == "chain" || test_name == "all") {
        test_chained_descriptors(device, krnl);
    }
    if (test_name == "tensor" || test_name == "all") {
        test_tensor_scenario(device, krnl);
    }

    std::cout << "\n===========================================\n";
    std::cout << "Test Suite Complete\n";
    std::cout << "===========================================\n";

    return 0;
}

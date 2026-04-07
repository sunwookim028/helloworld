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
 * Descriptor-Based DMA Data Mover Kernel
 * 
 * Phase 2: Eliminates CPU from data movement loop via hardware descriptor chaining.
 * 
 * Key Features:
 * - Autonomously fetches descriptors from HBM
 * - Executes chained transfers without CPU intervention
 * - Supports scatter/gather operations
 * - Maintains 512-bit vectorization for peak bandwidth
 * 
 * Performance Target:
 * - Single descriptor: ≥26.5 GB/s (95% of Phase 1)
 * - Tensor scenario (1024 descriptors): ≥10 GB/s (50x improvement over software)
 */

#include "ap_int.h"
#include "dma_descriptor.h"

// Helper function to convert byte address to 512-bit word index
static inline uint64_t byte_to_word512(uint64_t byte_addr) {
    return byte_addr >> 6; // Divide by 64 (512 bits = 64 bytes)
}

// Helper function to convert byte length to 512-bit word count
static inline uint32_t bytes_to_words512(uint32_t byte_length) {
    return (byte_length + 63) >> 6; // Round up and divide by 64
}

extern "C" {
void krnl_vadd_desc(
    const ap_uint<512> *desc_mem,    // Descriptor buffer in HBM
    const ap_uint<512> *data_mem0,   // Data buffer 0 (source/dest)
    const ap_uint<512> *data_mem1,   // Data buffer 1 (source/dest)
    ap_uint<512> *data_mem2,         // Data buffer 2 (dest)
    uint64_t first_desc_addr,        // Address of first descriptor (byte address)
    uint32_t max_descriptors         // Safety limit on descriptor chain length
) {
#pragma HLS INTERFACE m_axi port=desc_mem offset=slave bundle=gmem_desc
#pragma HLS INTERFACE m_axi port=data_mem0 offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi port=data_mem1 offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi port=data_mem2 offset=slave bundle=gmem2
#pragma HLS INTERFACE s_axilite port=desc_mem bundle=control
#pragma HLS INTERFACE s_axilite port=data_mem0 bundle=control
#pragma HLS INTERFACE s_axilite port=data_mem1 bundle=control
#pragma HLS INTERFACE s_axilite port=data_mem2 bundle=control
#pragma HLS INTERFACE s_axilite port=first_desc_addr bundle=control
#pragma HLS INTERFACE s_axilite port=max_descriptors bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    // =========================================================================
    // DESCRIPTOR-BASED DMA ENGINE
    // =========================================================================
    // Architecture:
    // 1. Fetch descriptor from HBM (gmem_desc)
    // 2. Parse src/dst addresses, length, control flags
    // 3. Execute data transfer using 512-bit vectorization
    // 4. Check chain enable bit
    // 5. If chained, fetch next descriptor and repeat
    // 6. Continue until chain terminates or max_descriptors reached
    // =========================================================================

    uint64_t current_desc_addr = first_desc_addr;
    uint32_t desc_count = 0;

    // Main descriptor processing loop
    descriptor_loop:
    while (desc_count < max_descriptors) {
        #pragma HLS LOOP_TRIPCOUNT min=1 max=1024 avg=64

        // =====================================================================
        // STEP 1: Fetch Descriptor from HBM
        // =====================================================================
        // Descriptor is 128 bits (16 bytes), stored in HBM
        // We read it as part of a 512-bit word
        
        uint64_t desc_word_idx = byte_to_word512(current_desc_addr);
        ap_uint<512> desc_word = desc_mem[desc_word_idx];
        
        // Extract descriptor fields based on offset within 512-bit word
        // For simplicity, assume descriptors are 512-bit aligned
        // (In production, would handle arbitrary alignment)
        uint64_t src_addr = desc_word.range(63, 0).to_uint64();
        uint64_t dst_addr = desc_word.range(127, 64).to_uint64();
        uint32_t length = desc_word.range(159, 128).to_uint();
        uint32_t control = desc_word.range(191, 160).to_uint();

        // =====================================================================
        // STEP 2: Execute Data Transfer
        // =====================================================================
        // Convert byte addresses to 512-bit word indices
        uint64_t src_word_idx = byte_to_word512(src_addr);
        uint64_t dst_word_idx = byte_to_word512(dst_addr);
        uint32_t num_words = bytes_to_words512(length);

        // Data transfer loop - maintains Phase 1 performance
        data_transfer_loop:
        for (uint32_t i = 0; i < num_words; i++) {
            #pragma HLS PIPELINE II=1
            #pragma HLS LOOP_TRIPCOUNT min=16 max=65536 avg=1024
            
            // Read from source (data_mem0 for now, could be extended)
            ap_uint<512> data = data_mem0[src_word_idx + i];
            
            // Write to destination (data_mem2 for now)
            data_mem2[dst_word_idx + i] = data;
        }

        // =====================================================================
        // STEP 3: Check for Descriptor Chaining
        // =====================================================================
        bool chain_enable = (control & DESC_CTRL_CHAIN_EN) != 0;
        
        if (!chain_enable) {
            // End of descriptor chain
            break;
        }

        // Get next descriptor address from control field
        current_desc_addr = control & DESC_CTRL_NEXT_MASK;
        desc_count++;
    }
}
}

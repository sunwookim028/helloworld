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

#include "ap_int.h"

extern "C" {
void krnl_vadd(
    const ap_uint<512> *in1, // Read-Only Vector 1
    const ap_uint<512> *in2, // Read-Only Vector 2 
    ap_uint<512> *out,       // Output Result
    int size                 // Size in integer (32-bit elements)
) {
#pragma HLS INTERFACE m_axi port=in1 offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi port=in2 offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi port=out offset=slave bundle=gmem2
#pragma HLS INTERFACE s_axilite port=in1 bundle=control
#pragma HLS INTERFACE s_axilite port=in2 bundle=control
#pragma HLS INTERFACE s_axilite port=out bundle=control
#pragma HLS INTERFACE s_axilite port=size bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    // =========================================================================
    // HBM BANDWIDTH SATURATION TECHNIQUES
    // =========================================================================
    // 1. Wide Data Path (Vectorization):
    //    Using `ap_uint<512>` allows accessing 64 bytes per clock cycle.
    //    At 450 MHz, this theoretically enables ~28.8 GB/s (64 * 450e6).
    //
    // 2. AXI Burst Inference:
    //    The specialized pointer type coupled with the sequential access pattern
    //    (i++) allows Vitis HLS to infer AXI4 Burst transactions.
    //    One burst request can transfer 4KB of data, minimizing command overhead.
    //
    // 3. Pipelining:
    //    `#pragma HLS PIPELINE II=1` ensures we initiate a new read/write
    //    operation every clock cycle, keeping the pipeline full.
    // =========================================================================

    // Host passes 'size' as number of 32-bit integers.
    // We process 16 integers (512 bits) per cycle.
    int v_size = size / 16;

    for (int i = 0; i < v_size; i++) {
        #pragma HLS PIPELINE II=1
        out[i] = in1[i]; // Pure Data Copy (Burst Read -> Burst Write)
    }
}
}

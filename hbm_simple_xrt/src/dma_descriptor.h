/**
 * DMA Descriptor Structure for Hardware Descriptor-Based Data Mover
 * 
 * This header defines the descriptor format used by the descriptor-based
 * DMA engine. Descriptors are stored in HBM and fetched by the kernel
 * to autonomously execute data transfers without CPU intervention.
 * 
 * Design follows industry standards (Xilinx AXI DMA, Intel IOAT):
 * - Descriptors stored in external memory (HBM)
 * - Linked-list chaining for scatter/gather operations
 * - Minimal overhead: ~10-20ns descriptor fetch vs ~100μs software orchestration
 */

#ifndef DMA_DESCRIPTOR_H
#define DMA_DESCRIPTOR_H

#include <stdint.h>

// Descriptor size: 128 bits (16 bytes) for efficient HBM access
// Aligned to 512-bit (64-byte) boundaries for optimal HBM bandwidth
struct dma_descriptor {
    uint64_t src_addr;      // Source address in HBM (byte address)
    uint64_t dst_addr;      // Destination address in HBM (byte address)
    uint32_t length;        // Transfer length in bytes
    uint32_t control;       // Control flags (see below)
} __attribute__((aligned(16)));

// Control field bit layout (32 bits)
// Bits [31:2]: Next descriptor address (30-bit word-aligned pointer, 4-byte granularity)
// Bit [1]:     Chain enable (1 = fetch next descriptor, 0 = stop)
// Bit [0]:     Interrupt enable (1 = generate interrupt, 0 = no interrupt)

#define DESC_CTRL_INTR_EN       (1 << 0)    // Interrupt enable bit
#define DESC_CTRL_CHAIN_EN      (1 << 1)    // Chain enable bit
#define DESC_CTRL_NEXT_MASK     0xFFFFFFFC  // Next descriptor address mask

// Helper macros for control field manipulation
#define DESC_MAKE_CONTROL(next_addr, chain, intr) \
    (((next_addr) & DESC_CTRL_NEXT_MASK) | \
     ((chain) ? DESC_CTRL_CHAIN_EN : 0) | \
     ((intr) ? DESC_CTRL_INTR_EN : 0))

#define DESC_GET_NEXT_ADDR(ctrl)    ((ctrl) & DESC_CTRL_NEXT_MASK)
#define DESC_IS_CHAIN_EN(ctrl)      ((ctrl) & DESC_CTRL_CHAIN_EN)
#define DESC_IS_INTR_EN(ctrl)       ((ctrl) & DESC_CTRL_INTR_EN)

// Descriptor alignment requirement (16 bytes)
#define DESC_ALIGNMENT          16

// Maximum descriptors in a single chain (safety limit)
#define MAX_DESC_CHAIN_LENGTH   4096

#endif // DMA_DESCRIPTOR_H

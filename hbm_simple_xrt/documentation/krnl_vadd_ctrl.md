# krnl_vadd_ctrl.v — AXI4-Lite Control Slave

**Path:** `src/krnl_vadd_ctrl.v`
**Origin:** Adapted from `minitpu/tpu/src/system/tpu_slave_axi_lite.v`

## Purpose

AXI4-Lite slave that implements the Vitis `ap_ctrl_hs` register interface. The host CPU uses this to configure kernel arguments (memory addresses, size) and to start/poll the kernel. The register layout matches what `kernel.xml` declares, so XRT can auto-discover argument offsets.

## Register Map

| Offset | Name         | Access     | Description                                      |
|--------|-------------|------------|--------------------------------------------------|
| `0x00` | `ap_ctrl`   | RW / Special | `[0]` ap_start (RW, self-clear on done), `[1]` ap_done (RO, COR), `[2]` ap_idle (RO) |
| `0x04` | `gier`      | RW         | Global interrupt enable (unused)                  |
| `0x08` | `ip_ier`    | RW         | Interrupt enable register (unused)                |
| `0x0C` | `ip_isr`    | RW         | Interrupt status register (unused)                |
| `0x10` | `in1[31:0]` | RW         | Base address of `in1` (low 32 bits)               |
| `0x14` | `in1[63:32]`| RW         | Base address of `in1` (high 32 bits)              |
| `0x18` | `in2[31:0]` | RW         | Base address of `in2` (low, unused by logic)      |
| `0x1C` | `in2[63:32]`| RW         | Base address of `in2` (high, unused by logic)     |
| `0x20` | `out_r[31:0]`| RW        | Base address of `out` (low 32 bits)               |
| `0x24` | `out_r[63:32]`| RW       | Base address of `out` (high 32 bits)              |
| `0x28` | `size`      | RW         | Number of 32-bit elements to process              |

### ap_ctrl_hs Protocol

1. Host writes `ap_start = 1` to offset `0x00`
2. Hardware self-clears `ap_start` when `ap_done` is asserted
3. `ap_done` is sticky — set by hardware, cleared when host reads `0x00` (Clear-On-Read)
4. `ap_idle` reflects the live idle state of the datapath

## Internal Architecture

### Write State Machine (lines 133–176)

Three states: `Idle → Waddr → Wdata`. Handles AXI4-Lite write address and write data channels, supporting both simultaneous and split AW/W arrivals (same pattern as minitpu's `tpu_slave_axi_lite.v`).

### Register Write Logic (lines 181–250)

On each write, the address is decoded to a 4-bit register index (`addr[5:2]`) and the data is written with byte-strobe masking.

### ap_done Sticky Bit (lines 255–263)

Separate `always` block:
- Set when `ap_done` input pulses from the datapath
- Cleared when the host reads offset `0x00` (COR — Clear On Read)

### Read State Machine (lines 268–296)

Three states: `Idle → Raddr → Rdata`. Standard AXI4-Lite read flow.

### Read Data Mux (lines 301–315)

The read response muxes between register values. For offset `0x00`, it returns the **live** composite value: `{29'b0, ap_idle, ap_done_sticky, reg_ap_ctrl[0]}`.

## Output Ports

| Port       | Width | Description                          |
|------------|-------|--------------------------------------|
| `ap_start` | 1     | Directly from `reg_ap_ctrl[0]`       |
| `in1_ptr`  | 64    | `{reg_in1_hi, reg_in1_lo}`           |
| `in2_ptr`  | 64    | `{reg_in2_hi, reg_in2_lo}` (unused)  |
| `out_ptr`  | 64    | `{reg_out_hi, reg_out_lo}`           |
| `size`     | 32    | `reg_size`                           |

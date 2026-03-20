# kernel.xml — Vitis RTL Kernel Descriptor
**Path:** `kernel.xml` (project root)

## Purpose
An XML file that tells the Vitis toolchain how to interact with the RTL kernel. It declares:
- The kernel name and control protocol (`ap_ctrl_hs`)
- AXI port names, widths, and types
- Kernel argument names, types, register offsets, and port bindings

Without this file, XRT wouldn't know how to map host API calls (`xrt::kernel`, `set_arg()`) to the RTL's AXI-Lite register addresses and AXI master ports.

## Structure
### Kernel Declaration
```xml
<kernel name="krnl_vadd" hwControlProtocol="ap_ctrl_hs" ...>
```

The name must match the top-level Verilog module name. The `ap_ctrl_hs` protocol tells XRT to use the standard start/done/idle handshake at offset `0x00`.

### Ports
| Port Name        | Mode   | Width   | Description                                |
|------------------|--------|---------|--------------------------------------------|
| `s_axi_control`  | slave  | 32-bit  | AXI4-Lite control, range `0x40`            |
| `m_axi_gmem0`    | master | 512-bit | Read port for `in1`                        |
| `m_axi_gmem1`    | master | 512-bit | `in2` (present for compat, never accessed) |
| `m_axi_gmem2`    | master | 512-bit | Write port for `out_r`                     |

### Arguments
| Arg Name | ID | Port          | Offset | Size | Type   | Description              |
|----------|----|---------------|--------|------|--------|--------------------------|
| `in1`    | 0  | `m_axi_gmem0` | `0x10` | 8    | `int*` | Source buffer address     |
| `in2`    | 1  | `m_axi_gmem1` | `0x18` | 8    | `int*` | Unused (XRT compat)      |
| `out_r`  | 2  | `m_axi_gmem2` | `0x20` | 8    | `int*` | Destination buffer address|
| `size`   | 3  | `s_axi_control`| `0x28`| 4    | `int`  | Element count             |

The `offset` values must exactly match the register addresses in `krnl_vadd_ctrl.v`. The `id` values match the original HLS argument order so that the existing host code and `krnl_vadd.cfg` connectivity file work unchanged.

## Relationship to Other Files
- **`krnl_vadd_ctrl.v`** — implements the register map declared here
- **`krnl_vadd.cfg`** — uses the argument names and port names declared here for HBM bank connectivity (`sp=krnl_vadd_1.in1:HBM[0]`)
- **`package_kernel.tcl`** — passes this file to `package_xo` to create the `.xo` object
- **Host code** — uses `xrt::kernel` which reads kernel metadata from the `.xclbin` (originally derived from this XML)

# package_kernel.tcl — Vivado IP Packaging and XO Creation

**Path:** `package_kernel.tcl` (project root)

## Purpose

A Vivado batch-mode TCL script that takes the raw RTL source files and produces a Vitis `.xo` kernel object — the packaged format that the Vitis linker (`v++`) uses to create the final `.xclbin` bitstream. It has two stages: package RTL as a Vivado IP, then wrap that IP into an `.xo`.

## Usage

Called from the Makefile (not run directly):

```bash
vivado -mode batch -source package_kernel.tcl \
       -tclargs krnl_vadd krnl_vadd.xo kernel.xml src/
```

Arguments:
1. `kernel_name` — top-level module name (e.g., `krnl_vadd`)
2. `xo_path` — output `.xo` file path
3. `kernel_xml` — path to `kernel.xml`
4. `rtl_src_dir` — directory containing `.sv` and `.v` files

## What It Does (Step by Step)

### Step 1: Create Temporary Vivado Project (line 28)
Creates a project targeting the Alveo U280 part (`xcu280-fsvh2892-2L-e`).

### Step 2: Add RTL Sources (lines 33–43)
Globs all `.sv` and `.v` files from the source directory and adds them. Sets the top-level module.

### Step 3: Package as Vivado IP (lines 50–56)
Uses `ipx::package_project` to create a standard Vivado IP component in `./packaged_kernel_<name>/`.

### Step 4: Associate Clocks (lines 61–80)
Opens the IP for editing and associates all bus interfaces (AXI4-Lite, AXI4 masters) with `ap_clk`. This is required — without clock association, the Vitis linker rejects the kernel.

### Step 5: Create .xo (lines 92–101)
Uses the `package_xo` command (provided by Vitis TCL extensions) to combine the Vivado IP and `kernel.xml` into the final `.xo` file.

### Cleanup (lines 106)
Deletes the temporary Vivado project directory.

## Relationship to Other Files

- **Inputs:** All `.sv`/`.v` files in `src/`, plus `kernel.xml`
- **Output:** `krnl_vadd.xo` — consumed by `v++ --link` (in the Makefile's `build` target)
- The `.xo` is then linked with the platform shell to produce `krnl_vadd.xclbin`

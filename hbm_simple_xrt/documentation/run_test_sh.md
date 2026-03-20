# run_test.sh — WSL Test Runner Script

**Path:** `verification/run_test.sh`

## Purpose

A minimal shell script that provides a clean environment for running the verification Makefile under WSL. It exists to solve a specific problem: Windows PATH entries containing parentheses (e.g., `Program Files (x86)`) leak into WSL's PATH and cause bash syntax errors when the Makefile shells out.

## Contents

```bash
#!/bin/bash
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
cd /mnt/c/Users/benso/coding/hbm_context/helloworld/hbm_simple_xrt/verification
make "$@" 2>&1
```

## What It Does

1. **Overrides PATH** with a clean set of Unix-only directories, excluding any Windows paths
2. **Changes to the verification directory** using the WSL mount path (`/mnt/c/...`)
3. **Runs `make`** with whatever arguments were passed, merging stderr into stdout

## Usage

From a WSL terminal:
```bash
./run_test.sh test_systolic_array
./run_test.sh test_mxu_4x4
./run_test.sh clean
./run_test.sh all
```

Or from Windows cmd/PowerShell:
```
wsl -- bash ./run_test.sh test_mxu
```

## Design Notes

- **Why not just `make` directly?** On systems where WSL inherits the Windows PATH, entries like `/mnt/c/Program Files (x86)/...` contain unescaped parentheses that break bash. The clean PATH export avoids this entirely.
- **`2>&1` redirect:** Ensures both stdout and stderr appear in the same stream, which is useful when piping output through `grep` or `tail` for CI-style result filtering.

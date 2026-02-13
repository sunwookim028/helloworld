#!/usr/bin/env python3
"""
HBM Loopback Test Script for V80 FPGA

This script tests the PCIe-to-HBM loopback functionality by:
1. Writing a test pattern to the loopback control register
2. Waiting for the operation to complete
3. Reading back the status register
4. Verifying the data matches

Requirements:
- V80 FPGA programmed with loopback design
- PCIe device enumerated (check with lspci)
- Access to PCIe BAR (requires root or appropriate permissions)

Usage:
    sudo python3 test_hbm_loopback.py
"""

import sys
import time
import struct

# Register offsets (relative to loopback module base)
REG_CTRL_DATA = 0x00
REG_STATUS    = 0x04
REG_STATE     = 0x08
REG_ERROR     = 0x0C

# Loopback module base address in PCIe BAR
LOOPBACK_BASE = 0x020101050000

# Test patterns
TEST_PATTERNS = [
    0xDEADBEEF,
    0xCAFEBABE,
    0x12345678,
    0xA5A5A5A5,
    0x00000000,
    0xFFFFFFFF,
]

class PCIeDevice:
    """Simple PCIe device access via /dev/mem or similar"""
    
    def __init__(self, bar_address):
        """
        Initialize PCIe device access
        
        Args:
            bar_address: Physical address of PCIe BAR
        """
        self.bar_address = bar_address
        self.mem_fd = None
        
    def open(self):
        """Open device for access"""
        try:
            import mmap
            import os
            
            # Open /dev/mem for physical memory access
            self.mem_fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
            
            # Map the loopback register space (4KB)
            self.mem_map = mmap.mmap(
                self.mem_fd,
                4096,
                mmap.MAP_SHARED,
                mmap.PROT_READ | mmap.PROT_WRITE,
                offset=LOOPBACK_BASE
            )
            
            print(f"✓ Opened PCIe device at 0x{LOOPBACK_BASE:012X}")
            return True
            
        except Exception as e:
            print(f"✗ Failed to open PCIe device: {e}")
            print("  Make sure you're running as root: sudo python3 test_hbm_loopback.py")
            return False
    
    def close(self):
        """Close device"""
        if hasattr(self, 'mem_map'):
            self.mem_map.close()
        if self.mem_fd is not None:
            import os
            os.close(self.mem_fd)
    
    def read32(self, offset):
        """Read 32-bit value from register"""
        self.mem_map.seek(offset)
        data = self.mem_map.read(4)
        return struct.unpack('<I', data)[0]
    
    def write32(self, offset, value):
        """Write 32-bit value to register"""
        self.mem_map.seek(offset)
        self.mem_map.write(struct.pack('<I', value))

def check_pcie_device():
    """Check if V80 FPGA is enumerated on PCIe bus"""
    try:
        import subprocess
        result = subprocess.run(
            ['lspci', '-d', '10ee:'],
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0 and result.stdout:
            print("✓ Found Xilinx PCIe device:")
            print(f"  {result.stdout.strip()}")
            return True
        else:
            print("✗ No Xilinx PCIe device found")
            print("  Run 'lspci | grep Xilinx' to check manually")
            return False
            
    except Exception as e:
        print(f"⚠ Could not check PCIe devices: {e}")
        return True  # Continue anyway

def test_loopback(device, test_value):
    """
    Test HBM loopback with a specific value
    
    Args:
        device: PCIeDevice instance
        test_value: 32-bit test pattern
        
    Returns:
        True if test passed, False otherwise
    """
    print(f"\nTesting with value: 0x{test_value:08X}")
    
    # Check initial state
    state = device.read32(REG_STATE)
    print(f"  Initial state: {state}")
    
    # Write test value to control register (triggers loopback)
    device.write32(REG_CTRL_DATA, test_value)
    print(f"  Wrote 0x{test_value:08X} to control register")
    
    # Wait for operation to complete
    # State should go: IDLE(0) -> WRITE_ADDR(1) -> ... -> DONE(6) -> IDLE(0)
    timeout = 100  # 100ms timeout
    start_time = time.time()
    
    while True:
        state = device.read32(REG_STATE)
        
        if state == 0:  # Back to IDLE
            break
            
        if (time.time() - start_time) * 1000 > timeout:
            print(f"  ✗ Timeout waiting for completion (stuck in state {state})")
            return False
        
        time.sleep(0.001)  # 1ms
    
    elapsed_ms = (time.time() - start_time) * 1000
    print(f"  Operation completed in {elapsed_ms:.2f}ms")
    
    # Read back status
    status = device.read32(REG_STATUS)
    print(f"  Read back: 0x{status:08X}")
    
    # Check for errors
    error = device.read32(REG_ERROR)
    if error != 0:
        print(f"  ✗ Error flags set: 0x{error:08X}")
        if error & 0x01:
            print("    - HBM write error")
        if error & 0x02:
            print("    - HBM read error")
        return False
    
    # Verify data
    if status == test_value:
        print(f"  ✓ Data matches!")
        return True
    else:
        print(f"  ✗ Data mismatch: expected 0x{test_value:08X}, got 0x{status:08X}")
        return False

def main():
    """Main test function"""
    print("=" * 60)
    print("V80 FPGA HBM Loopback Test")
    print("=" * 60)
    
    # Check for PCIe device
    if not check_pcie_device():
        print("\n⚠ Warning: PCIe device check failed, continuing anyway...")
    
    # Open device
    device = PCIeDevice(LOOPBACK_BASE)
    if not device.open():
        return 1
    
    try:
        # Run tests with different patterns
        passed = 0
        failed = 0
        
        for pattern in TEST_PATTERNS:
            if test_loopback(device, pattern):
                passed += 1
            else:
                failed += 1
        
        # Summary
        print("\n" + "=" * 60)
        print(f"Test Summary: {passed} passed, {failed} failed")
        print("=" * 60)
        
        if failed == 0:
            print("✓ All tests PASSED!")
            return 0
        else:
            print("✗ Some tests FAILED")
            return 1
            
    finally:
        device.close()

if __name__ == '__main__':
    sys.exit(main())

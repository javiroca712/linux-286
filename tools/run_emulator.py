#!/usr/bin/env python3
"""
run_emulator.py — Headless Emulator Runner with Serial Assertion Verification.

Runs QEMU or Bochs in headless mode with an automated timeout, captures COM1
serial telemetry from stdout or serial.log, and asserts structured output.

Usage:
    python tools/run_emulator.py --qemu
    python tools/run_emulator.py --bochs
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

REQUIRED_ASSERTIONS = [
    "[PM286] LMSW PE=1 active. Ring 0 execution established.",
    "[IDT] 80286 CPU exception gates (INT 00h-1Fh) installed",
    "[CMOS] Autodetect: Hardware Configuration",
    "[PIC] Dual 8259A PICs remapped to vectors 0x20-0x2F",
    "[PIT] 8253 PIT Channel 0 configured to 100 Hz",
    "[COPYWIN] GDT Scratch Copy Windows (0x0028, 0x0030) initialized",
    "[LDT] Per-task LDTs (0x0040-0x0078) initialized and LLDT loaded",
    "[SEGMM] 24-bit Physical Segment Allocator initialized (Pool A & B)",
    "[VM286] Virtual Memory Core (CoW #GP, Demand #NP, #SS Stack) initialized",
    "[TEST 1] PASSED: Hardware #GP exception caught and verified.",
    "[TEST 2] PASSED: Cross-segment physical memory copy verified (Pool A <-> B).",
    "[TEST 3] PASSED: Segment allocation, free coalescing & compaction verified.",
    "[TEST 4] PASSED: Per-task LDT switching and descriptor tables verified.",
    "[TEST 5] PASSED: CoW write fault intercepted, unshared & resumed.",
    "[TEST 6] PASSED: Demand loading #NP intercepted, allocated & loaded.",
    "[TEST 7] PASSED: Expand-down stack limit dynamically expanded.",
    "[TEST] ALL PHASE 1 & PHASE 2 VERIFICATIONS PASSED!",
    "TEST PASS",
]


def run_qemu(timeout_sec: float) -> tuple[int, str]:
    floppy = Path("build/floppy.img")
    if not floppy.exists():
        print(f"Error: {floppy} not found. Run make first.", file=sys.stderr)
        return 1, ""

    # Command to run inside WSL or directly if QEMU is present
    cmd = [
        "qemu-system-i386",
        "-cpu",
        "486",
        "-m",
        "1408k",
        "-fda",
        "build/floppy.img",
        "-nographic",
        "-serial",
        "mon:stdio",
        "-no-reboot",
    ]

    # Check if qemu-system-i386 is available directly on host or via WSL
    use_wsl = False
    try:
        subprocess.run(["qemu-system-i386", "--version"], capture_output=True)
    except FileNotFoundError:
        use_wsl = True

    if use_wsl:
        wsl_cmd = (
            f"cd /mnt/c/Users/javir/dev/linux-286 && timeout {int(timeout_sec)}s "
            f"qemu-system-i386 -cpu 486 -m 1408k -fda build/floppy.img -nographic -serial mon:stdio -no-reboot || true"
        )
        proc = subprocess.run(
            ["wsl", "-e", "bash", "-lc", wsl_cmd],
            capture_output=True,
            text=True,
        )
        output = proc.stdout + proc.stderr
        return proc.returncode, output
    else:
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                errors="replace",
            )
            output = (proc.stdout or "") + (proc.stderr or "")
            return proc.returncode, output
        except subprocess.TimeoutExpired as e:
            stdout = (
                e.stdout.decode("utf-8", errors="replace")
                if isinstance(e.stdout, bytes)
                else (e.stdout or "")
            )
            stderr = (
                e.stderr.decode("utf-8", errors="replace")
                if isinstance(e.stderr, bytes)
                else (e.stderr or "")
            )
            output = stdout + stderr
            return 0, output


def run_bochs(timeout_sec: float) -> tuple[int, str]:
    wsl_cmd = (
        f"cd /mnt/c/Users/javir/dev/linux-286 && "
        f"timeout {int(timeout_sec)}s bochs -q -f tools/bochsrc_286.bxrc || true; "
        f"cat build/serial.log 2>/dev/null || true"
    )
    proc = subprocess.run(
        ["wsl", "-e", "bash", "-lc", wsl_cmd],
        capture_output=True,
        text=True,
    )
    output = proc.stdout + proc.stderr
    return proc.returncode, output


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Lin286 Headless Emulator Verification Runner"
    )
    parser.add_argument(
        "--qemu",
        action="store_true",
        help="Run in QEMU (default).",
    )
    parser.add_argument(
        "--bochs", action="store_true", help="Run in Bochs instead of QEMU."
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=4.0,
        help="Timeout in seconds (default: 4.0)",
    )
    args = parser.parse_args()

    print(
        f"--- Starting Lin286 Headless Verification ({'Bochs' if args.bochs else 'QEMU'}) ---"
    )
    start_time = time.time()

    if args.bochs:
        code, output = run_bochs(args.timeout)
    else:
        code, output = run_qemu(args.timeout)

    elapsed = time.time() - start_time
    if isinstance(output, bytes):
        output = output.decode("utf-8", errors="replace")
    print(f"--- Execution finished in {elapsed:.2f}s ---")
    print(output)

    # Check assertions
    missing = []
    for assertion in REQUIRED_ASSERTIONS:
        if assertion not in output:
            missing.append(assertion)

    if missing:
        print("\n[VERIFICATION FAILED] Missing required telemetry strings:")
        for m in missing:
            print(f"  [-] {m}")
        return 1

    print("\n[VERIFICATION PASSED] All required assertions matched successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

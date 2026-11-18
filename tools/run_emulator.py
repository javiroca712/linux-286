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
    "[SCHED] Preemptive round-robin scheduler & task table initialized",
    "[SYSCALL] INT 0x80 Ring 3 trap gate (DPL=3) installed",
    "[TEST 1] PASSED: Hardware #GP exception caught and verified.",
    "[TEST 2] PASSED: Cross-segment physical memory copy verified (Pool A <-> B).",
    "[TEST 3] PASSED: Segment allocation, free coalescing & compaction verified.",
    "[TEST 4] PASSED: Per-task LDT switching and descriptor tables verified.",
    "[TEST 5] PASSED: CoW write fault intercepted, unshared & resumed.",
    "[TEST 6] PASSED: Demand loading #NP intercepted, allocated & loaded.",
    "[TEST 7] PASSED: Expand-down stack limit dynamically expanded.",
    "[TEST 8] PASSED: INT 0x80 syscall dispatcher & process queries verified.",
    "[TEST 9] PASSED: sys_brk dynamic heap expansion verified.",
    "[TEST 10] PASSED: sys_fork with CoW LDT cloning verified.",
    "[TEST 11] PASSED: sys_execve Split-I&D a.out loader verified.",
    "[TEST 12] PASSED: Preemptive round-robin multitasking verified.",
    "[TEST 13] PASSED: POSIX signals (sys_signal, sys_kill) verified.",
    "[TEST 14] PASSED: Process termination (sys_exit) and child reaping (sys_waitpid) verified.",
    "[TEST] ALL PHASE 1, PHASE 2 & PHASE 3 VERIFICATIONS PASSED!",
    "[BLKDEV] Block device subsystem initialized",
    "[BIO] Buffer cache initialized (8 x 1024-byte buffers, 8 KB)",
    "[MINIX] Minix v1 rootfs mounted on / (magic 0x137F, 1024-byte blocks)",
    "[FAT] DOS FAT12/16 filesystem mounted on /dos",
    "[DEVFS] Special device filesystem (/dev) initialized",
    "[PROCFS] Synthetic /proc filesystem initialized",
    "[VFS] Virtual File System core initialized (rootfs, /dos, /dev, /proc)",
    "[TEST 15] PASSED: Block driver & PIO IDE / RAM disk verified.",
    "[TEST 16] PASSED: Buffer cache (hit, LRU, bwrite dirty flushing) verified.",
    "[TEST 17] PASSED: Minix v1 superblock & root directory (namei) verified.",
    "[TEST 18] PASSED: Minix file creation, write & read via buffer cache verified.",
    "[TEST 19] PASSED: DOS FAT12/16 mounting & file reading verified.",
    "[TEST 20] PASSED: /dev character devices (null, zero, ttyS0) verified.",
    "[TEST 21] PASSED: /proc synthetic telemetry (meminfo, cpuinfo) verified.",
    "[TEST 22] PASSED: VFS file descriptors & INT 0x80 file syscalls verified.",
    "[TEST] ALL PHASE 1, 2, 3 & 4 VERIFICATIONS PASSED!",
    "[VT102] 4 Virtual Consoles (tty1..4) & ANSI terminal parser initialized",
    "[TTY] POSIX termios line discipline & 5 terminal devices initialized",
    "[KBD] 8042 Keyboard driver & IRQ 1 handler initialized",
    "[PIPE] FIFO in-memory pipe subsystem initialized",
    "[TEST 23] PASSED: Pipe creation, FIFO read/write & EOF verified.",
    "[TEST 24] PASSED: dup() & dup2() file descriptor duplication verified.",
    "[TEST 25] PASSED: termios line discipline (ERASE, KILL, ICRNL, ioctls) verified.",
    "[TEST 26] PASSED: VT102 / ANSI escape sequence parser verified.",
    "[TEST 27] PASSED: 4 Virtual Consoles screen buffers & Alt+F1-F4 switching verified.",
    "[TEST 28] PASSED: 8042 Keyboard IRQ 1 translation & line buffering verified.",
    "[TEST 29] PASSED: sys_select() multiplexed ready polling verified.",
    "[TEST 30] PASSED: Shell command pipelines (cmd1 | cmd2) verified.",
    "[TEST] ALL PHASE 1, 2, 3, 4 & 5 VERIFICATIONS PASSED!",
    "[FB286] Native Protected-Mode Framebuffer (/dev/fb0) driver initialized",
    "[SHM286] Zero-Copy LDT Shared Memory (shmget/shmat) initialized",
    "[MOUSE] RS-232 Serial Mouse driver (/dev/mouse) initialized",
    "[SOUND] PC Speaker & Class-D PWM Audio (/dev/pcspkr & /dev/dsp) initialized",
    "[NANOX] Microwindows / Nano-X Display Server core initialized",
    "[TEST 31] PASSED: Framebuffer /dev/fb0 FBIOGET_INFO & FBIOSET_MODE verified.",
    "[TEST 32] PASSED: Direct 64 KB Video Aperture LDT mapping (0x001F) verified.",
    "[TEST 33] PASSED: Display Server FLAGS.IOPL=3 elevation verified.",
    "[TEST 34] PASSED: Zero-Copy LDT Shared Memory (shmget/shmat) verified.",
    "[TEST 35] PASSED: RS-232 Serial Mouse driver (/dev/mouse) verified.",
    "[TEST 36] PASSED: PC Speaker (/dev/pcspkr) KIOCSOUND & timed beep verified.",
    "[TEST 37] PASSED: Class-D PWM Digital Audio (/dev/dsp) & XLATB Fast-ISR verified.",
    "[TEST 38] PASSED: Nano-X Window Server & GUI Desktop Compositor on tty5 verified.",
    "[TEST] ALL PHASE 1, 2, 3, 4, 5 & 6 VERIFICATIONS PASSED!",
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
    use_wsl = False
    try:
        subprocess.run(["bochs", "--help"], capture_output=True)
    except FileNotFoundError:
        use_wsl = True

    if use_wsl:
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
    else:
        cmd = (
            f"timeout {int(timeout_sec)}s bochs -q -f tools/bochsrc_286.bxrc || true; "
            f"cat build/serial.log 2>/dev/null || true"
        )
        proc = subprocess.run(
            ["bash", "-lc", cmd],
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

# Lin286 Phased Engineering Roadmap

This roadmap structures development into deterministic, self-verifying milestones designed for agentic execution.

---

## Phase 0: Toolchain, Static Gatekeeper & Emulator Harness
**Goal:** Establish a sub-second build-and-verify loop that rejects non-80286 instructions at build time and captures serial telemetry at runtime.
* [x] Repository structure, `SPEC.md`, `AGENTS.md`, `.agents/skills/build-test-286`, and `check_286_opcodes.py` gatekeeper.
* [x] Build system (`Makefile` / PowerShell / WSL wrapper) targeting `NASM` (`CPU 286`) and `ia16-elf-gcc` / `OpenWatcom`.
* [x] Headless emulator runner (`Bochs` CPU-level 2 / `QEMU` / `86Box`) streaming `COM1` (`0x3F8`) to stdout with automated timeout and exit-code assertions.

## Phase 1: Bootloader, A20, CMOS Autodetect & 80286 Protected Mode Switch
**Goal:** Boot from floppy/MBR, enable A20, initialize GDT/IDT, enter 16-bit Protected Mode via `LMSW`, read CMOS RAM/RTC, and print diagnostic output over `COM1` and VGA.
* [x] Stage 1 (`boot/bootsect.asm`): Load Stage 2 + Kernel image from disk.
* [x] Stage 2 (`boot/setup.asm`):
  * Detect conventional and extended (`INT 15h AH=88h`) memory size.
  * Enable A20 gate (8042 keyboard controller + Fast A20 fallback).
  * Load temporary GDT & IDT and execute `LMSW` (`PE=1`) + far jump `jmp 0x0008:pm_entry`.
* [x] Ring 0 Early Kernel (`kernel/arch/i286/`):
  * Initialize 8250 UART (`COM1`), dual-display text console (`0xB8000` / `0xB0000`), and MC146818 CMOS RTC/RAM autodetect (`0x70`/`0x71`).
  * Remap 8259A PIC (`0x20`–`0x2F`) and start 8253 PIT at 100 Hz.
  * Install CPU exception handlers (`INT 0`–`INT 13`: `#UD`, `#NM` 80287 lazy FPU, `#DF`, `#TS`, `#NP`, `#SS`, `#GP`) and interactive `kdb286` serial/console crash monitor.
* [x] **Verification Gate:** Trigger deliberate `#GP` and `#NP` faults in Ring 0/Ring 3 and verify structured crash dumps over `COM1`.

## Phase 2: 24-Bit Segment Memory Manager & Virtual Memory Core
**Goal:** Manage all 860 KB of user RAM (Conventional + Extended) with per-process LDTs, Copy-on-Write, and `#NP` demand swapping.
* [x] Physical segment allocator (`kernel/mm/segalloc.asm`, `include/mm/segalloc.h`) spanning Pool A (`0x029000`–`0x09FFFF`) and Pool B (`0x100000`–`0x15FFFF`) with bidirectional free coalescing and live segment compaction.
* [x] GDT Scratch Copy Windows (`0x0028`, `0x0030`, `kernel/arch/i286/copy_win.asm`) for fast cross-segment physical memory copies anywhere in the 16 MB address space via `rep movsw`.
* [x] LDT manager (`kernel/arch/i286/ldt.asm`) + shared 286 TSS (`0x0038`) for per-task descriptor isolation and Ring 3 $\rightarrow$ Ring 0 stack switching.
* [x] Virtual Memory handlers (`kernel/mm/vm286.asm`, `include/mm/vm286.h`):
  * `#GP` Copy-on-Write (`CoW`) unsharing and software `VM_DIRTY` bit tracking.
  * `#NP` (`INT 11`) demand segment loader and Clock-LRU eviction scanner using the hardware `Accessed` bit.
  * `#SS` (`INT 12`) dynamic stack expansion.
* [x] **Verification Gate:** Verified 7-stage automated self-test suite (Memory Allocation, Free Coalescing, Compaction, Cross-Pool GDT Copy, LLDT Task Switching, CoW `#GP` Unsharing, Demand-Loading `#NP`, and `#SS` Stack Growth).

## Phase 3: Multitasking, Process Lifecycle & `INT 0x80` Syscalls
**Goal:** Preemptive multitasking of Ring 3 processes with ELKS-compatible `a.out` binary loading.
* [x] Task table (`struct task`), kernel stack context switch, and 100 Hz preemptive round-robin scheduler (`LLDT` + `TSS.ss0/sp0` update).
* [x] `INT 0x80` Ring 3 trap gate and syscall dispatcher.
* [x] `sys_fork()` (with CoW LDT cloning), `sys_execve()` (16-bit Split-I&D `a.out` loader), `sys_exit()`, `sys_waitpid()`, `sys_brk()`, and POSIX signal delivery (`sigaction`, `kill`).
* [x] **Verification Gate:** 14-stage automated self-test suite (Task table initialization, Ring 3 user entry & INT 0x80 syscalls, dynamic heap expansion via sys_brk, sys_fork with CoW LDT, sys_execve 16-bit a.out loader, 100 Hz PIT preemptive round-robin scheduling, POSIX signal queueing & delivery, and child exit/reap lifecycle).

## Phase 4: Block Drivers, VFS & Filesystems
**Goal:** Persistent storage on IDE/CF and Floppy with Minix rootfs and DOS FAT12/16 interoperability.
* [x] Native Protected-Mode PIO IDE/ATA & XT-IDE driver (`kernel/drivers/ide.asm`, `include/drivers/ide.h`) + RAM disk driver (`kernel/drivers/ramdisk.asm`, `include/drivers/blkdev.h`) in Extended Memory.
* [x] Buffer cache (`kernel/fs/bio.asm`, `include/fs/bio.h`: 8 x 1024-byte LRU buffers with dirty writeback) and Linux-like VFS (`kernel/fs/vfs.asm`, `include/fs/vfs.h`: inode, file, super_block, file descriptor table).
* [x] **Minix v1 Filesystem** (`kernel/fs/minix.asm`, `include/fs/minix.h`: read/write) for `/` + **FAT12/FAT16** (`kernel/fs/fat.asm`, `include/fs/fat.h`) for `/dos`.
* [x] `/dev` (`kernel/fs/devfs.asm`: `tty1`–`tty4`, `ttyS0`, `hda`, `fd0`, `null`, `zero`) and `/proc` (`kernel/fs/procfs.asm`: `meminfo`, `cpuinfo`, `ldt`, `tasks`).
* [x] POSIX File System Syscalls (`kernel/sys/sys_file.asm`): `sys_open` (5), `sys_close` (6), `sys_read` (3), `sys_write` (4), `sys_lseek` (19), `sys_stat` (18), `sys_fstat` (28).
* [x] **Verification Gate:** 22-stage automated self-test suite (Tests 1–14 regression + Test 15 Block driver & PIO IDE / RAM disk, Test 16 Buffer cache hit/LRU/dirty flushing, Test 17 Minix v1 superblock & root directory namei, Test 18 Minix file creation/write/read via buffer cache, Test 19 DOS FAT12/16 mounting & file reading, Test 20 /dev character devices, Test 21 /proc synthetic diagnostics telemetry, and Test 22 VFS file descriptors & INT 0x80 file syscalls).

## Phase 5: Terminal (`termios`), Virtual Consoles & Userland
**Goal:** Boot into an interactive multi-console POSIX shell running unmodified ELKS `a.out` utilities and native 286 tools.
* [x] POSIX `termios` line discipline (`kernel/drivers/tty.asm`, `include/uapi/termios.h`), pipes (`kernel/fs/pipe.asm`, `include/fs/pipe.h`, `sys_pipe`), `dup` (41), `dup2` (63), `ioctl` (54), and `select` (82).
* [x] VT102 / ANSI console driver with 4 Virtual Consoles (`Alt+F1`–`Alt+F4`, `kernel/drivers/vt102.asm`) + serial `ttyS0` + 8042 keyboard IRQ 1 handler (`kernel/drivers/keyboard.asm`).
* [x] Stand-alone shell (`sash`, `kernel/fs/sash.asm`) built-ins (`echo`, `cat`, `uname`, `clear`, `help`, `ps`, `free`), I/O redirection, and inter-process pipeline execution (`cmd1 | cmd2`).
* [x] **Verification Gate:** 30-stage automated self-test suite (Tests 1–22 regression + Test 23 Pipe creation/FIFO read/write/EOF, Test 24 dup/dup2 descriptors, Test 25 termios line discipline ERASE/KILL/ICRNL/ioctls, Test 26 VT102 ANSI parser, Test 27 4 Virtual Consoles screen buffers & Alt+F1-F4 switching, Test 28 8042 Keyboard IRQ 1 translation, Test 29 sys_select multiplexed ready polling, and Test 30 Shell command pipeline execution).

## Phase 6: Protected-Mode GUI & Class-D PWM Audio (`/dev/fb0`, `/dev/dsp` & Nano-X)
**Goal:** Run a mouse-driven windowed GUI on Virtual Console 5 (`Alt+F5`) at 640×480 (VGA) / 640×350 (EGA) / 720×348 (Hercules) with zero syscall overhead per pixel, plus 8 kHz / 11 kHz Class-D PWM digital audio on the stock PC speaker.
* [ ] Native Protected-Mode VGA/EGA/CGA/Hercules register driver (`kernel/drivers/fb286.c`) implementing `/dev/fb0` (`FBIOSET_MODE`, `FBIOMAP_LDT`, `FBIOSET_IOPL3`).
* [ ] Map 64 KB Video Aperture (`0xA0000` / `0xB0000`) into the Display Server's LDT (`LDT_UFB_SEL = 0x001F`) with `FLAGS.IOPL = 3` for direct bitplane register writes.
* [ ] Zero-copy LDT-aliased Shared Memory (`shmget286`/`shmat286`) in Extended RAM (`0x100000+`) for fast client-to-server window blitting.
* [ ] RS-232 Serial Mouse driver (`/dev/mouse` Microsoft 3-byte & Mouse Systems protocol).
* [ ] PC Speaker Square-Wave (`/dev/pcspkr`) & Class-D PWM Digital PCM driver (`/dev/dsp`) using PIT Channel 2 Mode 0 + `XLATB` Ring 0 Fast-ISR (`kernel/drivers/sound286.c`).
* [ ] Port/integrate **Microwindows / Nano-X** (`nanox` server, `nanowm` window manager, `nxterm` terminal, `nxclock`, `nxcalc`) and **Doom8088** onto `tty5` (`Alt+F5`).

## Phase 7: Loadable Kernel Modules (`.ko286`), PLIP & Enthusiast Packaging
* [ ] Segmented Loadable Kernel Module loader (`insmod`/`rmmod` allocating dynamic GDT Code + Data selectors) and Parallel Port `LPT1` PLIP / Covox DAC support.
* [ ] Single-floppy (1.44 MB / 1.2 MB) and CF/IDE hard disk image builder.
* [ ] 86Box hardware validation profile (IBM 5170 AT, 12 MHz 286, 1 MB RAM, ISA IDE/VGA + Serial Mouse).
* [ ] Self-hosting on-target assembler/compiler package.

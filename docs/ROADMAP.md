# Lin286 Phased Engineering Roadmap

This roadmap structures development into deterministic, self-verifying milestones designed for agentic execution.

---

## Phase 0: Toolchain, Static Gatekeeper & Emulator Harness
**Goal:** Establish a sub-second build-and-verify loop that rejects non-80286 instructions at build time and captures serial telemetry at runtime.
* [x] Repository structure, `SPEC.md`, and `check_286_opcodes.py` gatekeeper.
* [ ] Build system (`Makefile` / PowerShell / Docker wrapper) targeting `NASM` (`CPU 286`) and `ia16-elf-gcc` / `OpenWatcom`.
* [ ] Headless emulator runner (`Bochs` CPU-level 2 / `QEMU` / `86Box`) streaming `COM1` (`0x3F8`) to stdout with automated timeout and exit-code assertions.

## Phase 1: Bootloader, A20 & 80286 Protected Mode Switch
**Goal:** Boot from floppy/MBR, enable A20, initialize GDT/IDT, enter 16-bit Protected Mode via `LMSW`, and print diagnostic output over `COM1` and VGA.
* [ ] Stage 1 (`boot/bootsect.asm`): Load Stage 2 + Kernel image from disk.
* [ ] Stage 2 (`boot/setup.asm`):
  * Detect conventional and extended (`INT 15h AH=88h`) memory size.
  * Enable A20 gate (8042 keyboard controller + Fast A20 fallback).
  * Load temporary GDT & IDT and execute `LMSW` (`PE=1`) + far jump `jmp 0x0008:pm_entry`.
* [ ] Ring 0 Early Kernel (`kernel/arch/i286/`):
  * Initialize 8250 UART (`COM1`) and dual-display text console (`0xB8000` / `0xB0000`).
  * Remap 8259A PIC (`0x20`–`0x2F`) and start 8253 PIT at 100 Hz.
  * Install CPU exception handlers (`INT 0`–`INT 13`: `#UD`, `#DF`, `#TS`, `#NP`, `#SS`, `#GP`) with detailed register & descriptor dumps.
* **Verification Gate:** Trigger deliberate `#GP` and `#NP` faults in Ring 0/Ring 3 and verify structured crash dumps over `COM1`.

## Phase 2: 24-Bit Segment Memory Manager & Virtual Memory Core
**Goal:** Manage all 860 KB of user RAM (Conventional + Extended) with per-process LDTs, Copy-on-Write, and `#NP` demand swapping.
* [ ] Physical segment allocator (`kernel/mm/segalloc.c`) spanning Pool A (`0x029000`–`0x09FFFF`) and Pool B (`0x100000`–`0x15FFFF`) with segment compaction.
* [ ] GDT Scratch Copy Windows (`0x0028`, `0x0030`) for fast cross-segment physical memory copies anywhere in the 16 MB address space.
* [ ] LDT manager (`kernel/arch/i286/ldt.c`) + shared 286 TSS (`0x0038`) for Ring 3 $\rightarrow$ Ring 0 stack switching.
* [ ] Virtual Memory handlers (`kernel/mm/vm286.c`):
  * `#GP` Copy-on-Write (`CoW`) unsharing and software `VM_DIRTY` bit tracking.
  * `#NP` (`INT 11`) demand segment loader and Clock-LRU eviction scanner using the hardware `Accessed` bit.
  * `#SS` (`INT 12`) dynamic stack expansion.

## Phase 3: Multitasking, Process Lifecycle & `INT 0x80` Syscalls
**Goal:** Preemptive multitasking of Ring 3 processes with ELKS-compatible `a.out` binary loading.
* [ ] Task table (`struct task`), kernel stack context switch, and 100 Hz preemptive round-robin scheduler (`LLDT` + `TSS.ss0/sp0` update).
* [ ] `INT 0x80` Ring 3 trap gate and syscall dispatcher.
* [ ] `sys_fork()` (with CoW LDT cloning), `sys_execve()` (16-bit Split-I&D `a.out` loader), `sys_exit()`, `sys_waitpid()`, `sys_brk()`, and POSIX signal delivery (`sigaction`, `kill`).

## Phase 4: Block Drivers, VFS & Filesystems
**Goal:** Persistent storage on IDE/CF and Floppy with Minix rootfs and DOS FAT12/16 interoperability.
* [ ] Native Protected-Mode PIO IDE/ATA & XT-IDE driver (`kernel/drivers/ide.c`) + RAM disk driver.
* [ ] Buffer cache (`kernel/fs/bio.c`) and Linux-like VFS (`inode`, `file`, `super_block`, `dentry`).
* [ ] **Minix v1 Filesystem** (read/write) for `/` + **FAT12/FAT16** for `/dos`.
* [ ] `/dev` (`tty1`–`tty4`, `ttyS0`, `hda`, `fd0`, `null`, `zero`) and `/proc` (`meminfo`, `cpuinfo`, `ldt`, `<pid>/status`).

## Phase 5: Terminal (`termios`), Virtual Consoles & Userland
**Goal:** Boot into an interactive multi-console POSIX shell running unmodified ELKS `a.out` utilities and native 286 tools.
* [ ] POSIX `termios` line discipline, pipes (`sys_pipe`), `dup2`, and `select`.
* [ ] VT102 / ANSI console driver with 4 Virtual Consoles (`Alt+F1`–`Alt+F4`) + serial `getty` on `/dev/ttyS0`.
* [ ] Integrate `elks-libc` + Bourne shell (`ash`/`sash`) + core utilities (`ls`, `cat`, `ps`, `free`, `mount`, `vi`, `grep`) on root disk image.

## Phase 6: Enthusiast Polish & Release Packaging
* [ ] Single-floppy (1.44 MB / 1.2 MB) and CF/IDE hard disk image builder.
* [ ] 86Box hardware validation profile (IBM 5170 AT, 12 MHz 286, 1 MB RAM, ISA IDE/VGA).
* [ ] Self-hosting on-target assembler/compiler package.

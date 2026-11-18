# Lin286 (`linux-286`)

A clean-room, monolithic, **POSIX.1-1988** and **Linux/ELKS-ABI compatible** operating system engineered specifically for **Intel 80286 Protected Mode** (`16-bit Protected Virtual Address Mode`) on machines with **1 MB of RAM**.

---

## Why `linux-286`?

Historically, open-source Unix/Linux projects either stayed in **8086 Real Mode** for original IBM PC compatibility (leaving the 80286's hardware MMU, privilege rings, and extended memory underutilized) or jumped straight to **80386 32-bit Paging**.

`linux-286` fills that gap: a modern-toolchain (`ia16-elf-gcc` / `OpenWatcom` + `NASM`) monolithic kernel that enters **80286 Protected Mode** at boot and never looks back.

### Core Architectural Highlights

* **True 80286 Hardware Protection (Ring 0 / Ring 3):**
  User processes run in unprivileged Ring 3 with private **Local Descriptor Tables (LDTs)**. A wild pointer in user space triggers a clean `SIGSEGV` (`#GP` / `#SS` trap) instead of corrupting the kernel or other processes.
* **Unified 1 MB+ Physical Memory Pool (`24-bit` Addressing):**
  Seamlessly merges standard **640 KB Conventional RAM** (`0x00000`–`0x9FFFF`) and **384 KB+ Extended RAM** (`0x100000`+) into a single physical segment allocator—supporting up to 16 MB on expanded AT systems.
* **Hardware-Trapped Segment Virtual Memory:**
  Uses the 80286 MMU's segment descriptors and restartable fault handlers to provide:
  * **Copy-on-Write (`CoW`) `fork()`** via read-only LDT sharing and **Interrupt 13 (`#GP`)** write traps.
  * **On-Demand Code Loading & Disk Swapping** via the descriptor `Present` bit (`P=0`), **Interrupt 11 (`#NP`)**, and hardware `Accessed` (`A`) bit Clock-LRU eviction.
  * **Dynamic Stack Growth** via expand-down stack segments and **Interrupt 12 (`#SS`)**.
* **Drop-In ELKS `a.out` Binary Compatibility (`INT 0x80`):**
  Executes standard 16-bit Split-I&D (`a.out`) userland binaries (`ash`, `vi`, `ls`, `grep`, `cat`, `sed`) compiled with `ia16-elf-gcc -melks` directly in Ring 3 Protected Mode.
* **Zero-Overhead Protected-Mode GUI (`Nano-X` on `/dev/fb0`):**
  Supports a mouse-driven windowed GUI at `640×480` (VGA), `640×350` (EGA), or `720×348` (Hercules) on `Alt+F5` by mapping the 64 KB video aperture (`0xA0000`/`0xB0000`) directly into the display server's LDT (`0x001F`), granting selective `FLAGS.IOPL = 3` for native bitplane register access, and aliasing Extended RAM segments across LDTs for zero-copy shared window buffers.
* **Retro-Hardware Interoperability:**
  Supports **Minix v1/v2** root filesystems alongside **FAT12/FAT16** for seamless file exchange with MS-DOS / FreeDOS on CompactFlash cards, XT-IDE adapters, and 1.44 MB / 1.2 MB floppies.

---

## Repository Structure

```text
linux-286/
├── boot/               # Stage 1 (MBR/Floppy) & Stage 2 (A20, GDT, 286 PM switch)
├── kernel/             # Ring 0 monolithic kernel
│   ├── arch/i286/      # GDT, LDT, IDT, TSS, #NP/#GP/#SS fault handlers, INT 0x80
│   ├── mm/             # 24-bit segment allocator, CoW fork, LDT shm, Clock-LRU swapper
│   ├── proc/           # Preemptive scheduler, fork, execve (a.out), waitpid, signals
│   ├── fs/             # VFS, buffer cache, Minix v1/v2, FAT12/16, /dev, /proc
│   └── drivers/        # PIC, PIT, UART, PIO IDE/XT-IDE, FDC, VT102, /dev/fb0, /dev/mouse
├── include/            # Kernel and POSIX/UAPI headers
│   ├── arch/i286.h     # 80286 hardware descriptor, selector & IOPL definitions
│   └── uapi/fb286.h    # Protected-Mode framebuffer, LDT shared memory & mouse UAPI
├── libc/               # Minimal POSIX.1-1988 C library & syscall stubs
├── user/               # Init, shell, Nano-X GUI integration & 286 diagnostic tools
├── tools/              # Build scripts & agentic verification guardrails
│   └── check_286_opcodes.py  # Static gatekeeper rejecting 386+ opcodes & 0x66/0x67 prefixes
└── docs/
    ├── SPEC.md         # Full architectural, VM, GUI & ABI specification
    └── ROADMAP.md      # Phased development milestones & test harness design
```

---

## Documentation

* [**Architectural Specification (`docs/SPEC.md`)**](docs/SPEC.md) — Memory map, 286 descriptor formats, virtual memory state machine, and `INT 0x80` ABI.
* [**Development Roadmap (`docs/ROADMAP.md`)**](docs/ROADMAP.md) — Phased agentic engineering milestones and verification harness.

## License

BSD 3-Clause License.

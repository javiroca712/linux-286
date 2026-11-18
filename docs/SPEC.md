# Lin286 Technical & Architectural Specification

## 1. Target Hardware Profile

* **CPU:** Intel 80286 (or CMOS/Harris/AMD 80C286) operating in **16-bit Protected Virtual Address Mode**.
* **RAM Baseline:** **1 MB Physical RAM** on an IBM PC/AT (5170) or compatible architecture:
  * **Region A (Conventional RAM):** `0x000000` – `0x09FFFF` (640 KB)
  * **Reserved (UMA / Video / BIOS):** `0x0A0000` – `0x0FFFFF` (384 KB address hole)
  * **Region B (Extended / XMS RAM):** `0x100000` – `0x15FFFF` (384 KB mapped above 1 MB via A20 gate; scales automatically up to `0xFFFFFF` / 16 MB if present).
* **Core Peripherals:**
  * **Interrupt Controller:** Dual cascaded 8259A PICs (`0x20`/`0x21` Master, `0xA0`/`0xA1` Slave), remapped to vectors `0x20`–`0x2F` to avoid colliding with 80286 CPU exceptions (`0x00`–`0x1F`).
  * **Timer & Class-D PWM Audio:** 8253/8254 PIT (`0x40`–`0x43`) configured at **100 Hz** (`10 ms` tick quantum) on `IRQ 0` (`INT 0x20`) during normal operation, dynamically accelerating to **8,000 Hz / 11,025 Hz** with a Ring 0 Fast-ISR prescaler when streaming Class-D PWM digital audio through PIT Channel 2 (`0x42`) and the internal PC Speaker (`0x61`).
  * **Serial I/O:** 8250 / 16450 / 16550A UART (`COM1` at `0x3F8`, `IRQ 4`; `COM2` at `0x2F8`, `IRQ 3`).
  * **Keyboard & A20:** 8042 PS/2-AT Keyboard Controller (`0x60`, `0x64`, `IRQ 1`).
  * **Video:** CGA (`0xB8000`), EGA/VGA Text (`0xB8000`), and MDA/Hercules (`0xB0000`) mapped via dedicated GDT video selectors, supporting 4 virtual consoles (`Alt+F1`–`Alt+F4`) and `VT102` escape sequences.
  * **Block Storage:**
    * 16-bit ISA ATA/IDE PIO (`0x1F0` Primary, `IRQ 14`) & 8-bit/16-bit XT-IDE CF adapters.
    * NEC µPD765 Floppy Disk Controller (`0x3F0`, `IRQ 6`, `DMA 2`) for 1.44 MB and 1.2 MB media.

---

## 2. 80286 Protected Mode Memory Architecture

### 2.1 Physical Memory Map (1 MB System)

| Physical Range | Size | Purpose |
| :--- | :--- | :--- |
| `0x000000` – `0x000FFF` | 4 KB | Real-Mode IVT/BDA preserved during early boot; reclaimed as GDT/IDT/TSS tables in PM |
| `0x001000` – `0x018FFF` | 96 KB | **Kernel Code (`CS`)** — Ring 0 Execute/Read segment |
| `0x019000` – `0x028FFF` | 64 KB | **Kernel Data/BSS/Heap/Stacks (`DS`/`SS`)** — Ring 0 Read/Write segment |
| `0x029000` – `0x09FFFF` | **476 KB** | **User Segment Pool A** (Conventional RAM frames) |
| `0x0A0000` – `0x0FFFFF` | 384 KB | Video RAM (`0xB0000`/`0xB8000`) & ROM BIOS |
| `0x100000` – `0x15FFFF` | **384 KB** | **User Segment Pool B** (Extended RAM frames above 1 MB) |

* **Total Allocatable User & Buffer Pool:** **860 KB** (out of 1,024 KB physical RAM).

### 2.2 Global Descriptor Table (GDT) Layout

| Selector | Index | Ring | Type | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0x0000` | 0 | — | Null | Mandatory Null Descriptor |
| `0x0008` | 1 | 0 | Code (E/R) | Kernel Text Segment (`Base=0x001000`, `Limit=0xFFFF`) |
| `0x0010` | 2 | 0 | Data (R/W) | Kernel Data & BSS Segment (`Base=0x019000`, `Limit=0xFFFF`) |
| `0x0018` | 3 | 0 | Data (R/W) | Color Video Memory (`Base=0x0B8000`, `Limit=0x7FFF`) |
| `0x0020` | 4 | 0 | Data (R/W) | Mono Video Memory (`Base=0x0B0000`, `Limit=0x7FFF`) |
| `0x0028` | 5 | 0 | Data (R/W) | Scratch Physical Copy Window A (dynamically aimed for Ring 0 cross-segment copy) |
| `0x0030` | 6 | 0 | Data (R/W) | Scratch Physical Copy Window B (dynamically aimed for Ring 0 cross-segment copy) |
| `0x0038` | 7 | 0 | TSS (286) | Shared Hardware Task State Segment (holds Ring 0 `SS0:SP0` for privilege transitions) |
| `0x0040+`| `8..8+N`| 0 | LDT | Per-Process Local Descriptor Table Descriptors (`LDT[pid]`) |

### 2.3 Per-Process Local Descriptor Table (LDT) Layout

Each process has a compact LDT enabling isolated Ring 3 execution and zero-relocation `fork()`:

| Selector (TI=1, RPL=3) | LDT Index | Type | Description |
| :--- | :--- | :--- | :--- |
| `0x0007` | 0 | Code (E/R, DPL=3) | Process Text Segment (`CS`, shared read-only across instances) |
| `0x000F` | 1 | Data (R/W, DPL=3) | Process Data + BSS + Heap + Stack (`DS`/`ES`/`SS` in standard Split-I&D mode) |
| `0x0017` | 2 | Stack (Expand-Down, DPL=3) | Optional dedicated Stack Segment (`SS`) in extended 286-native mode |
| `0x001F` | 3 | Data (R/W, DPL=3, MMIO) | Direct 64 KB Video Framebuffer (`0xA0000` EGA/VGA or `0xB0000` HGC; mapped via `/dev/fb0`) |
| `0x0027+`| `4..K` | Code/Data (DPL=3) | Zero-Copy Shared Memory (`VM_FLAG_SHM`) & Dynamic "Tiled" Virtual Memory Segments |

---

## 3. Hardware-Trapped Segment Virtual Memory

The 80286 descriptor is 8 bytes long, with Bytes 6–7 reserved as `0x0000` by hardware (ignored by the 286 when loaded into the 6-byte descriptor cache). `linux-286` stores OS virtual memory metadata in kernel tables indexed by `(pid, ldt_idx)` and utilizes the descriptor's `Base`/`Limit` fields as a **40-bit swap token** whenever `Present (P) == 0`:

1. **Copy-on-Write (`CoW`) `fork()` via `#GP` (INT 13):**
   * On `fork()`, parent and child LDT Data descriptors point to the same 24-bit physical base, with hardware access rights changed from `R/W` to `Read-Only` and `vm_flags |= VM_COW`.
   * When either process writes to `DS` or `SS`, the 80286 fires `#GP(selector)` (or `#SS(selector)`).
   * The Ring 0 handler allocates a new physical frame from the 860 KB pool, copies the segment via GDT Scratch Windows `0x0028`/`0x0030`, updates the faulting process's LDT descriptor to the new base with `R/W` enabled, decrements the CoW reference count, and executes `IRET`.
2. **Demand Loading & Swap-to-Disk via `#NP` (INT 11):**
   * Evicted segments have `P = 0` in their LDT descriptor and their swap block number stored in the 24-bit `Base` field.
   * When referenced by a Ring 3 instruction, **INT 11 (`#NP`)** traps to the kernel with the faulting selector pushed on the Ring 0 stack.
   * The kernel runs a **Clock-LRU scan** checking hardware `Accessed (A)` bits across resident segments, swaps out a victim if needed, reads the target segment from IDE/Swap, sets `P = 1`, and returns via `IRET` to restart the instruction.
3. **Software Dirty-Bit Tracking:**
   * Clean resident data segments are mapped `Read-Only` (`Writable = 0`). The first write traps to `#GP`, which sets `VM_DIRTY` in software, flips `Writable = 1` in the LDT descriptor, and restarts the instruction.

---

## 4. Binary Format & System Call ABI

### 4.1 Executable Format (`elks-a.out`)
Supports the standard 16-bit Split-I&D MINIX/ELKS `a.out` header (32 bytes):
* `magic`: `0x0301` (`A_MAGIC0`, `A_MAGIC1`)
* `flags`: `0x20` (Split I&D: separate 64 KB max `text` and 64 KB max `data+bss+heap+stack`)
* Extended flag `0x80` (`A_286PM`): Indicates awareness of 286 Protected Mode selectors and separate expand-down `SS`.

### 4.2 System Call Convention (`INT 0x80`)
* **Trap Gate:** IDT entry `0x80` configured as a 286 Trap Gate (`DPL = 3`, Target `CS = 0x0008`).
* **Registers:**
  * `AX`: System call number (ELKS/Linux-16 numbering: `1=exit`, `2=fork`, `3=read`, `4=write`, `5=open`, `6=close`, `7=wait4`, `11=execve`, `17=brk`, `48=signal`, `54=ioctl`, etc.)
  * `BX`, `CX`, `DX`, `SI`, `DI`: Arguments 1–5 (16-bit offsets within caller's `DS`).
  * **Return value:** `AX` (negative `-errno` values on error, converted by `libc` into `errno` and `-1`).

---

## 5. Protected-Mode Graphical Subsystem (GUI & Direct Framebuffer)

`linux-286` supports a full mouse-driven, windowed GUI stack (**Microwindows / Nano-X** running on Virtual Console 5, `Alt+F5`) at `640x480x16` (VGA), `640x350x16` (EGA), `640x200x2` (CGA), or `720x348x2` (Hercules) without ever leaving 80286 Protected Mode.

### 5.1 Native Protected-Mode Video Mode Switching (`/dev/fb0`)
Because the 80286 cannot call Real-Mode BIOS `INT 10h` from Protected Mode without a CPU reset, `kernel/drivers/fb286.c` contains static hardware register tables for VGA/EGA/CGA/Hercules CRT Controller (`0x3D4`/`0x3B4`), Sequencer (`0x3C4`), Graphics Controller (`0x3CE`), and Attribute Controller (`0x3C0`). Calling `ioctl(fd, FBIOSET_MODE, mode)` programs the graphics adapter cleanly in Ring 0.

### 5.2 Three Zero-Overhead 80286 Hardware Mechanisms for Fast GUI Rendering
To achieve native bus-speed graphics on an 8–12 MHz 80286 without per-pixel system call overhead:
1. **Direct 64 KB Hardware Framebuffer LDT Descriptor (`LDT_UFB_SEL = 0x001F`):**
   * Calling `ioctl(fd, FBIOMAP_LDT, &info)` populates LDT Index 3 (`Selector 0x001F`, `DPL=3`, `VM_FLAG_MMIO`) with `Physical Base = 0x0A0000` (or `0x0B0000` for Hercules) and `Limit = 0xFFFF` (64 KB).
   * The Ring 3 Display Server loads `ES = 0x001F` and blits scanlines directly into video RAM using `REP MOVSW`.
2. **Selective Ring 3 `FLAGS.IOPL = 3` for Display Server Bitplane Control:**
   * 16-color planar EGA/VGA modes require frequent writes to Sequencer (`0x3C4`) and Graphics Controller (`0x3CE`) I/O ports.
   * Calling `ioctl(fd, FBIOSET_IOPL3, 1)` sets bits 12–13 (`IOPL = 3`) in the Display Server's saved Ring 3 `FLAGS` image on the kernel stack.
   * The Display Server executes `OUT DX, AX` directly in Ring 3 at zero overhead, while regular user processes remain at `IOPL = 0` (hardware-protected from port I/O).
3. **Zero-Copy Shared Memory (`VM_FLAG_SHM`) via LDT Aliasing:**
   * GUI client applications allocate shared offscreen window buffers in Extended RAM (`0x100000+`) via `shmget286` / `shmat286`.
   * The kernel maps the **exact same 24-bit physical base address** into both the client's LDT and the Display Server's LDT (`0x0027+`). Clients draw into their local selector and send an 8-byte damage event to the Display Server, which blits directly from the shared segment to `0xA0000` VRAM.

### 5.3 Mouse & Virtual Console Integration (`/dev/mouse` & `Alt+F5`)
* **Mouse Driver (`kernel/drivers/mouse.c`):** Parses 1200-baud RS-232 Microsoft (3-byte) and Mouse Systems (5-byte) packets from `COM1`/`COM2` into normalized `struct mouse286_event` packets on `/dev/mouse`.
* **VT Switching:** `Alt+F1`–`Alt+F4` switch between 80×25 text consoles (`tty1`–`tty4`), while `Alt+F5` switches to the graphical Display Server (`tty5`), signaling the server to restore graphics mode and redraw damaged windows.

### 5.4 GUI Memory Budget on 1 MB Hardware
* **Kernel (Ring 0):** ~160 KB
* **Nano-X Display Server (`nanox`) + Planar VGA Driver:** ~76 KB
* **Window Manager (`nanowm`) + Graphical Terminal (`nxterm`) + Shell + Desktop Applets:** ~134 KB
* **Remaining Free RAM for User Applications & Shared Buffers:** **~650 KB**

---

## 6. PC Speaker & Class-D PWM Digital Audio Subsystem (`/dev/pcspkr` & `/dev/dsp`)

Every IBM PC/AT and 80286 clone includes an internal PC Speaker driven by 8254 PIT Channel 2 (`0x42`) and gated by Port `0x61` (Bits 0–1). `linux-286` exposes two audio interfaces in `kernel/drivers/sound286.c`:

### 6.1 Hardware Square-Wave & Chiptune Synth (`/dev/pcspkr`)
* Programs PIT Channel 2 into **Mode 3 (Square Wave Generator)** (`0xB6`).
* Supports `KIOCSOUND` and `PCSPKR_IOC_BEEP` (timed asynchronously by the 100 Hz kernel tick) at **0% CPU overhead**—ideal for system bells, 3-voice arpeggiated chiptune trackers, and classic PC speaker game sound effects.

### 6.2 Class-D PWM Digital PCM Audio (`/dev/dsp`)
To play 8-bit unsigned mono `.WAV` audio and digital game SFX (such as *DOOM*'s digital sound lumps) without a dedicated ISA sound card:
1. **PIT Channel 2 as Duty-Cycle Modulator:** Configured in **Mode 0 (One-Shot Interrupt on Terminal Count)**, LSB-only (`0x90`). Writing a count $N$ to port `0x42` drives the speaker pin LOW for $N$ ticks of the $1.193182\text{ MHz}$ clock and HIGH for the remainder of the carrier period, using the physical speaker cone's mechanical inductance as a Class-D low-pass filter.
2. **Two-Tier Ring 0 `IRQ 0` Fast-ISR (`~75 clock cycles`):**
   * When `/dev/dsp` is actively streaming at **8,000 Hz** (PIT Ch0 divider `149`) or **11,025 Hz** (divider `108`), `INT 0x20` points to a tight Ring 0 assembly stub (`irq0_pwm_fast`).
   * The stub pops the next 8-bit PCM sample from the 4 KB `dsp_ringbuf`, translates it to a pulse width (`1..148` at 8 kHz) in **5 clock cycles** using a 256-byte lookup table and the 80286 **`XLATB`** instruction, outputs it via `OUT 0x42, AL`, sends EOI (`OUT 0x20, AL`), and returns via `IRET` (**< 6% CPU load on a 12 MHz 286**).
   * A prescaler counter chains into the full C preemptive scheduler once every 80 ticks (at 8 kHz) or 110 ticks (at 11.025 kHz), keeping the OS scheduler clock locked at **100 Hz**.
   * When `dsp_ringbuf` drains, the driver automatically drops PIT Channel 0 back to 100 Hz (**0% idle overhead**).

---

## 7. High-Leverage Hardware & Kernel Extensions (`include/uapi/sys286.h`)

To maximize available RAM on 1 MB systems and take full advantage of standard IBM PC/AT motherboard peripherals:

1. **Segmented Loadable Kernel Modules (`.ko286` — `insmod` / `rmmod`):**
   * Optional drivers (`ne2k`, `fat16`, `plip`, `mouse`, `sound286`) can be compiled as relocatable `.ko286` modules rather than bloating the static Ring 0 kernel image.
   * On `insmod`, the kernel allocates a compact physical segment pair for the module's code and data, inserts two Ring 0 descriptors into the GDT, resolves kernel symbol imports, and invokes `mod_init()`. On `rmmod`, `mod_exit()` runs and the physical segments are returned to the 860 KB pool.
2. **PC/AT MC146818 CMOS Real-Time Clock & Hardware Autodetect (`0x70`/`0x71`):**
   * Directly reads CMOS registers `0x15`–`0x18` in Protected Mode to verify Base RAM (640 KB) and Extended RAM (384 KB+) without BIOS calls, inspects `0x10` for 1.2 MB / 1.44 MB floppy geometry, and reads BCD date/time registers (`0x00`–`0x09`) to seed the POSIX wall-clock epoch at boot.
3. **Intel 80287 Lazy FPU Context Switching & Emulation (`INT 7 #NM`):**
   * Uses `MSW.TS` (Task Switched) so integer context switches cost zero FPU overhead. When a task executes an `ESC` (`0xD8`–`0xDF`) instruction, `INT 7 (#NM)` fires and lazily saves/restores the 94-byte `struct fpu287_state` (`CLTS`, `FSAVE`, `FRSTOR`), or dispatches to software FPU emulation when `MSW.EM = 1`.
4. **Parallel Port (`LPT1` at `0x378`) PLIP Networking & Covox 8-Bit DAC:**
   * **PLIP:** High-speed (~50 KB/s) 4-bit nibble networking over a standard LapLink parallel cable.
   * **Covox Speech Thing:** Selectable via `ioctl(fd, SNDCTL_DSP_SETBACKEND, DSP_BACKEND_COVOX_LPT1)` so the `IRQ 0` Fast-ISR outputs 8-bit PCM samples directly to `0x378`.
5. **Built-In Ring 0 Kernel Debugger (`kdb286`):**
   * Invoked automatically on kernel panic or via `Ctrl+Alt+SysRq` / serial break on `COM1`. Supports inspecting GDT/LDT descriptors (`ldt <pid>`), dumping 24-bit physical addresses (`x`), listing tasks (`ps`), and stack backtraces (`bt`).

---

## 8. Agentic Development Guardrails (`AGENTS.md` & `.agents/skills/`)

To prevent LLM 386+ instruction bleed and Real-Mode segment bugs:
1. **Mandatory `CPU 286` Directive:** Every `.asm` file must begin with `CPU 286` and `BITS 16`.
2. **Static Opcode Gatekeeper (`tools/check_286_opcodes.py`):** Every build runs a static verification pass ensuring zero `0x66`/`0x67` operand/address-size override prefixes and zero 80386+ opcodes exist in output binaries.
3. **Structured Serial Exception Dumps:** All CPU exceptions (`INT 0x00`–`0x1F`) emit a machine-parseable JSON/text crash frame over `COM1` (`0x3F8`) showing `CS:IP`, `FLAGS`, `ERROR_CODE`, `LDT/GDT` descriptor bytes, and register state.

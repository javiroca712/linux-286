# Lin286 Technical & Architectural Specification

## 1. Target Hardware Profile

* **CPU:** Intel 80286 (or CMOS/Harris/AMD 80C286) operating in **16-bit Protected Virtual Address Mode**.
* **RAM Baseline:** **1 MB Physical RAM** on an IBM PC/AT (5170) or compatible architecture:
  * **Region A (Conventional RAM):** `0x000000` – `0x09FFFF` (640 KB)
  * **Reserved (UMA / Video / BIOS):** `0x0A0000` – `0x0FFFFF` (384 KB address hole)
  * **Region B (Extended / XMS RAM):** `0x100000` – `0x15FFFF` (384 KB mapped above 1 MB via A20 gate; scales automatically up to `0xFFFFFF` / 16 MB if present).
* **Core Peripherals:**
  * **Interrupt Controller:** Dual cascaded 8259A PICs (`0x20`/`0x21` Master, `0xA0`/`0xA1` Slave), remapped to vectors `0x20`–`0x2F` to avoid colliding with 80286 CPU exceptions (`0x00`–`0x1F`).
  * **Timer:** 8253/8254 PIT (`0x40`–`0x43`) configured at **100 Hz** (`10 ms` tick quantum) on `IRQ 0` (`INT 0x20`).
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
| `0x001F+`| `3..K` | Code/Data (DPL=3) | Dynamic "Tiled" Virtual Memory Segments (4 KB–64 KB blocks) |

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

## 5. Agentic Development Guardrails

To prevent LLM 386+ instruction bleed and Real-Mode segment bugs:
1. **Mandatory `CPU 286` Directive:** Every `.asm` file must begin with `CPU 286` and `BITS 16`.
2. **Static Opcode Gatekeeper (`tools/check_286_opcodes.py`):** Every build runs a static verification pass ensuring zero `0x66`/`0x67` operand/address-size override prefixes and zero 80386+ opcodes exist in output binaries.
3. **Structured Serial Exception Dumps:** All CPU exceptions (`INT 0x00`–`0x1F`) emit a machine-parseable JSON/text crash frame over `COM1` (`0x3F8`) showing `CS:IP`, `FLAGS`, `ERROR_CODE`, `LDT/GDT` descriptor bytes, and register state.

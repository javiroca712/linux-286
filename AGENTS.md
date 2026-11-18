# AGENTS.md — Lin286 (`linux-286`) Agentic Engineering Rules

You are working on **Lin286 (`linux-286`)**, a monolithic POSIX.1-1988 & ELKS-ABI compatible operating system targeting **Intel 80286 16-bit Protected Virtual Address Mode** on machines with **1 MB RAM**.

Always follow these strict hardware and toolchain rules in every file you create or edit.

---

## 1. Iron Rules of Intel 80286 Protected Mode (NEVER Violate)

1. **NO 80386+ Registers or Instructions:**
   * **Forbidden registers:** `eax`, `ebx`, `ecx`, `edx`, `esi`, `edi`, `ebp`, `esp`, `eip`, `eflags`, `cr0`–`cr4`, `dr0`–`dr7`, `fs`, `gs`.
   * **Forbidden instructions:** `movzx`, `movsx`, `shld`, `shrd`, `bsf`, `bsr`, `bt*`, `iretd`, `pushad`, `popad`, `pushfd`, `popfd`, `cwde`, `cdq`, `lfs`, `lgs`, `lss`, `setcc`.
   * **Valid 80286 privileged instructions:** Use `lmsw` / `smsw` (instead of `mov cr0`), `lgdt`, `lidt`, `lldt`, `ltr`, `clts`, `arpl`, `verr`, `verw`, `lsl`, `lar`, `pusha`, `popa`, `enter`, `leave`, `insb/w`, `outsb/w`.
2. **Mandatory NASM Header:**
   * Every `.asm` file **MUST** start with:
     ```nasm
     CPU 286
     BITS 16
     ```
3. **NEVER Use `gcc -m16`:**
   * Standard `x86_64/i686-elf-gcc -m16` emits 32-bit instructions prefixed with `0x66`/`0x67`, which trigger **Invalid Opcode (`#UD`, INT 6)** on a real 80286.
   * Always use **`ia16-elf-gcc -march=i286`** (or OpenWatcom `wcc -2`) for C code.
4. **Protected-Mode Selectors Are NOT Real-Mode Segments:**
   * In 80286 Protected Mode (after `LMSW PE=1`), segment registers (`CS`, `DS`, `ES`, `SS`) hold **Selectors** (`(Index << 3) | TI | RPL`), **never** physical paragraphs (`phys_addr >> 4`).
   * Never increment or add offsets to a segment register in Protected Mode. To access arbitrary 24-bit physical memory in Ring 0, set the 24-bit base of `GDT_COPY_A_SEL` (`0x0028`) or `GDT_COPY_B_SEL` (`0x0030`) in the GDT and load `ES`.
5. **No Real-Mode BIOS Calls After Entering Protected Mode:**
   * The 80286 cannot clear `MSW.PE` without resetting the CPU. Never call `INT 10h`, `INT 13h`, `INT 15h`, or `INT 16h` after entering Protected Mode. Use native Ring 0 drivers (`uart`, `fb286`, `ide`, `cmos_rtc`, `kbd`).
6. **Always Run the Static Gatekeeper Before Booting:**
   * After editing any `.asm` or C file, run:
     ```powershell
     python tools/check_286_opcodes.py --asm boot/ kernel/
     ```

---

## 2. Key Architectural References (Read Before Modifying Subsystems)

* **Full Specification:** [`docs/SPEC.md`](docs/SPEC.md)
* **Phased Milestones:** [`docs/ROADMAP.md`](docs/ROADMAP.md)
* **80286 Descriptors, GDT/LDT Selectors, TSS & VM Flags:** [`include/arch/i286.h`](include/arch/i286.h)
* **Protected-Mode GUI, Framebuffer (`/dev/fb0`) & LDT Shared Memory:** [`include/uapi/fb286.h`](include/uapi/fb286.h)
* **PC Speaker & Class-D PWM Audio (`/dev/pcspkr`, `/dev/dsp`) & Covox:** [`include/uapi/sound286.h`](include/uapi/sound286.h)
* **CMOS RTC, 80287 FPU, Loadable Modules (`.ko286`), PLIP & `kdb286`:** [`include/uapi/sys286.h`](include/uapi/sys286.h)

---

## 3. Quota-Efficient Development Workflow

* Keep changes modular and scoped to one subsystem or roadmap checkbox at a time.
* Use the `build-test-286` skill (`.agents/skills/build-test-286/SKILL.md`) for deterministic headless builds and serial log verification.
* When delegating independent driver or userland tasks to subagents, prefer `Model: "flash"`.

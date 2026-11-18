---
name: build-test-286
description: Build Lin286 (linux-286), run the static 80286 opcode gatekeeper, and execute headless emulator boot/serial verification tests via WSL or Docker. Use whenever compiling assembly/C code or testing kernel boot images.
---

# Build & Headless Test Workflow for `linux-286`

Follow this exact procedure whenever compiling or testing `linux-286` so builds are deterministic and never hang waiting on a GUI window.

## Step 1: Run the Static 80286 Opcode Gatekeeper (Host Python)

Before assembling or compiling, validate that all assembly sources contain `CPU 286` and zero 80386+ instructions or registers:

```powershell
python C:\Users\javir\dev\linux-286\tools\check_286_opcodes.py --asm C:\Users\javir\dev\linux-286\boot C:\Users\javir\dev\linux-286\kernel
```

If you have produced a disassembly listing (`build/kernel.dis`), also pass `--disasm build/kernel.dis`.

## Step 2: Build Inside WSL (or Docker)

The Windows host has `wsl` and `docker` installed. The repository `C:\Users\javir\dev\linux-286` maps to `/mnt/c/Users/javir/dev/linux-286` inside WSL.

### Check / Install Toolchain in WSL (One-Time Setup)
```powershell
wsl -e bash -lc "which nasm qemu-system-i386 bochs ia16-elf-gcc || true"
```
If `nasm` or `qemu-system-i386` / `bochs` are missing in WSL:
```powershell
wsl -u root -e bash -lc "apt-get update && apt-get install -y nasm qemu-system-x86 bochs bochs-x build-essential python3"
```
For `ia16-elf-gcc` (on Ubuntu/Debian WSL):
```powershell
wsl -u root -e bash -lc "add-apt-repository -y ppa:tkchia/build-ia16 && apt-get update && apt-get install -y gcc-ia16-elf libi86-ia16-elf"
```

## Step 3: Run Headless Emulator with `COM1` Serial Capture & Hard Timeout

**NEVER launch an emulator without a timeout and headless serial redirection**, or the command will block indefinitely.

### Option A: Fast Headless Boot Check via QEMU (`-cpu 286`, 1 MB RAM, Serial to Stdout)
```powershell
wsl -e bash -lc "cd /mnt/c/Users/javir/dev/linux-286 && timeout 3s qemu-system-i386 -cpu 286 -m 1M -fda build/floppy.img -nographic -serial mon:stdio -no-reboot || true"
```
* Note: Always combine QEMU checks with `check_286_opcodes.py` and Bochs CPU-level 2 verification, as QEMU is permissive with 386 opcodes if not caught by `check_286_opcodes.py`.

### Option B: Strict 80286 Verification via Headless Bochs
```powershell
wsl -e bash -lc "cd /mnt/c/Users/javir/dev/linux-286 && timeout 5s bochs -q -f tools/bochsrc_286.bxrc || true; cat build/serial.log"
```

## Step 4: Inspect Structured Fault Dumps
If the kernel panics or triggers an 80286 exception (`#UD` INT 6, `#NP` INT 11, `#SS` INT 12, `#GP` INT 13), read the `[FAULT]` frame from `COM1` stdout (`CS:IP`, `ERROR_CODE`, `LDT/GDT` descriptor dump) to pinpoint the exact selector and instruction offset.

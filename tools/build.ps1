# Lin286 PowerShell Build & Test Script

param(
    [switch]$Test,
    [switch]$Bochs,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

if ($Clean) {
    if (Test-Path build) { Remove-Item -Recurse -Force build }
    Write-Host "Build artifacts removed."
    exit 0
}

if (-not (Test-Path build)) { New-Item -ItemType Directory -Path build | Out-Null }

$Nasm = if (Test-Path tools\bin\nasm-2.16.03\nasm.exe) { "tools\bin\nasm-2.16.03\nasm.exe" } else { "nasm" }
$Ndisasm = if (Test-Path tools\bin\nasm-2.16.03\ndisasm.exe) { "tools\bin\nasm-2.16.03\ndisasm.exe" } else { "ndisasm" }

Write-Host "=== 1. Running 80286 Static Gatekeeper on Assembly Sources ==="
python tools\check_286_opcodes.py --asm boot kernel

Write-Host "`n=== 2. Assembling Boot Sector, Setup & Kernel ==="
& $Nasm -f bin -o build\bootsect.bin boot\bootsect.asm
& $Nasm -f bin -o build\setup.bin boot\setup.asm
& $Nasm -f bin -I. -o build\kernel.bin kernel\arch\i286\head.asm

Write-Host "`n=== 3. Creating 1.44 MB Floppy Image ==="
python tools\mkfloppy.py build\bootsect.bin build\setup.bin build\kernel.bin build\floppy.img

Write-Host "`n=== 4. Generating & Verifying Disassembly ==="
& $Ndisasm -b 16 build\kernel.bin > build\kernel.dis
python tools\check_286_opcodes.py --disasm build\kernel.dis

Write-Host "`n=== Build Complete: build\floppy.img ==="

if ($Test) {
    Write-Host "`n=== 5. Running Headless Verification ==="
    if ($Bochs) {
        python tools\run_emulator.py --bochs
    } else {
        python tools\run_emulator.py --qemu
    }
}

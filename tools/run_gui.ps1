# Lin286 Interactive GUI & Virtual Console Emulator Launcher (Windows / WSLg)
#
# Launches Lin286 in a graphical VGA window so you can interact directly with:
#  - The Nano-X GUI Desktop on tty5 (Alt+F5):
#      * Type commands inside nxterm: help, uname, free, ps, ldt, beep, clear
#      * Use Arrow Keys (Up/Down/Left/Right) to move the red/white desktop pointer
#      * Press Tab to cycle active window focus (nxterm -> nxclock -> nxcalc)
#  - 4 Virtual Text Consoles (Alt+F1 .. Alt+F4) and back to GUI (Alt+F5)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

# Ensure build/floppy.img is up to date
& .\tools\build.ps1

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Launching Lin286 Interactive Graphical Emulator Window..." -ForegroundColor Cyan
Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  * Inside nxterm (GUI): Type 'help', 'uname', 'free', 'ps', 'ldt', 'beep', 'clear'"
Write-Host "  * Arrow Keys:          Move the red/white desktop pointer across windows"
Write-Host "  * Tab Key:             Cycle active window focus (nxterm / nxclock / nxcalc)"
Write-Host "  * Alt+F1 .. Alt+F4:    Switch to Virtual Text Consoles tty1..tty4"
Write-Host "  * Alt+F5:              Return to the Nano-X GUI Desktop (tty5)"
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Prefer native Windows QEMU if installed
$WinQemu = Get-Command "qemu-system-i386.exe" -ErrorAction SilentlyContinue
if (-not $WinQemu -and (Test-Path "C:\Program Files\qemu\qemu-system-i386.exe")) {
    $WinQemu = Get-Item "C:\Program Files\qemu\qemu-system-i386.exe"
}

if ($WinQemu) {
    $QemuPath = if ($WinQemu.Source) { $WinQemu.Source } else { $WinQemu.FullName }
    Write-Host "Using native Windows QEMU: $QemuPath" -ForegroundColor Green
    & $QemuPath -cpu 486 -m 1408k -drive file=build\floppy.img,format=raw,if=floppy -serial stdio
} else {
    Write-Host "Using WSLg Graphical QEMU Window (DISPLAY=:0)..." -ForegroundColor Green
    Write-Host "(Tip: To install native Windows QEMU anytime, run: winget install SoftwareFreedomConservancy.QEMU)" -ForegroundColor DarkGray
    wsl -e sh -c 'cd /mnt/c/Users/javir/dev/linux-286 && qemu-system-i386 -cpu 486 -m 1408k -drive file=build/floppy.img,format=raw,if=floppy -display gtk -serial stdio'
}

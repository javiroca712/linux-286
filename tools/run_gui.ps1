# Lin286 Interactive GUI & Virtual Console Emulator Launcher (WSL-Only)
#
# Runs the emulator strictly inside WSL (via tools/run_gui_wsl.sh) so Windows
# endpoint protection (CrowdStrike) is never triggered by Windows QEMU binaries.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..

# Ensure build/floppy.img and build/floppy12.img are up to date
& .\tools\build.ps1

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Launching Lin286 Interactive Graphical Emulator Window (WSLg)..." -ForegroundColor Cyan
Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  * Inside nxterm (GUI): Type 'help', 'uname', 'free', 'ps', 'ldt', 'beep', 'clear'"
Write-Host "  * Arrow Keys:          Move the red/white desktop pointer across windows"
Write-Host "  * Tab Key:             Cycle active window focus (nxterm / nxclock / nxcalc)"
Write-Host "  * Alt+F1 .. Alt+F4:    Switch to Virtual Text Consoles tty1..tty4"
Write-Host "  * Alt+F5:              Return to the Nano-X GUI Desktop (tty5)"
Write-Host "==================================================================" -ForegroundColor Cyan

wsl -e bash /mnt/c/Users/javir/dev/linux-286/tools/run_gui_wsl.sh

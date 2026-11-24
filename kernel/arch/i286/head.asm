CPU 286
BITS 16

; ============================================================================
; Lin286 Kernel Entry Point & Hardware Initialization Core
;
; Physical Memory Mapping:
; - Kernel Code: Physical 0x001000 (CS = GDT_KCODE_SEL = 0x0008)
; - Kernel Data: Physical 0x019000 (DS = SS = GDT_KDATA_SEL = 0x0010)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global gdt_table
global tss_struct

; ----------------------------------------------------------------------------
; Base Section Declarations
; ----------------------------------------------------------------------------
section .text vstart=0
text_start:

; 16-Byte Kernel Binary Header (read by Stage 2 Setup before PM switch)
kernel_header:
    jmp short _start
    nop
    nop
hdr_text_size:  dw (text_end - text_start)  ; Offset 0x0004
hdr_data_size:  dw (data_end - data_start)  ; Offset 0x0006
hdr_bss_size:   dw (bss_end - bss_start)    ; Offset 0x0008
hdr_magic:      dw 0x2860                   ; Offset 0x000A
    times 16 - ($ - $$) db 0                ; Exact 16-byte header

section .data vstart=0
data_start:

; ----------------------------------------------------------------------------
; 80286 Hardware Task State Segment (44 Bytes at offset 0 of Kernel Data)
; ----------------------------------------------------------------------------
align 8
tss_struct:
    dw 0                    ; Back link
    dw 0xFFF0               ; SP0 (Ring 0 stack pointer)
    dw GDT_KDATA_SEL        ; SS0 (Ring 0 stack selector)
    times 38 db 0

; ----------------------------------------------------------------------------
; Runtime Global Descriptor Table (GDT) - 32 Descriptors (256 Bytes)
; ----------------------------------------------------------------------------
align 8
gdt_table:
    ; Index 0 (0x0000): Mandatory Null Descriptor
    dw 0x0000, 0x0000
    db 0x00, 0x00
    dw 0x0000

    ; Index 1 (0x0008): Kernel Code (CS), Base=0x001000, Limit=0xFFFF, Ring 0 E/R
    dw 0xFFFF, 0x1000
    db 0x00, 0x9A
    dw 0x0000

    ; Index 2 (0x0010): Kernel Data (DS/SS), Base=0x019000, Limit=0xFFFF, Ring 0 R/W
    dw 0xFFFF, 0x9000
    db 0x01, 0x92
    dw 0x0000

    ; Index 3 (0x0018): Color Video Text (0xB8000), Limit=0x7FFF, Ring 0 R/W
    dw 0x7FFF, 0x8000
    db 0x0B, 0x92
    dw 0x0000

    ; Index 4 (0x0020): Mono Video Text (0xB0000), Limit=0x7FFF, Ring 0 R/W
    dw 0x7FFF, 0x0000
    db 0x0B, 0x92
    dw 0x0000

    ; Index 5 (0x0028): Scratch Copy Window A, Base=0x000000, Limit=0xFFFF, Ring 0 R/W
    dw 0xFFFF, 0x0000
    db 0x00, 0x92
    dw 0x0000

    ; Index 6 (0x0030): Scratch Copy Window B, Base=0x000000, Limit=0xFFFF, Ring 0 R/W
    dw 0xFFFF, 0x0000
    db 0x00, 0x92
    dw 0x0000

    ; Index 7 (0x0038): Shared 286 Hardware TSS, Base=0x019000, Limit=43, Access=0x81
    dw 43,     0x9000
    db 0x01, 0x81
    dw 0x0000

    ; Index 8..15 (0x0040..0x0078): Per-process LDT descriptors (configured by ldt_init)
    times 8 * 8 db 0

    ; Index 16..31 (0x0080..0x00F8): Reserved / expansion
    times 16 * 8 db 0
gdt_table_end:

align 4
gdtr_runtime_desc:
    dw (gdt_table_end - gdt_table - 1)
gdtr_runtime_base_low:
    dw 0x0000
gdtr_runtime_base_high:
    db 0x00
    db 0x00

str_banner1:    db 13, 10
                db "========================================================", 13, 10
                db " Lin286 Kernel v0.6.0-phase6 (Intel 80286 Protected Mode)", 13, 10
                db "========================================================", 13, 10, 0
str_banner2:    db "[PM286] LMSW PE=1 active. Ring 0 execution established.", 13, 10
                db "[PM286] CS=0x0008 (Base=0x001000) DS=SS=0x0010 (Base=0x019000)", 13, 10, 0
str_vga_banner: db "Lin286 Kernel v0.6.0-phase6 (Intel 80286 Protected Mode, 1MB RAM)", 13, 10, 0
str_prog_cmos:  db "[BOOT] CMOS hardware detected.", 13, 10, 0
str_prog_vfs:   db "[BOOT] VFS & block subsystems initialized.", 13, 10, 0
str_prog_tests: db "[BOOT] Phase 1-6 self-tests passed.", 13, 10, 0
str_ready:      db "[READY] Lin286 Phase 6 kernel initialized. Halting at idle.", 13, 10, 0

section .bss
bss_start:

section .text

; ----------------------------------------------------------------------------
; Kernel Entry Point (Physical 0x001010, reached via jmp 0x0008:0x0000)
; ----------------------------------------------------------------------------
_start:
    ; 1. Reload protected mode segment registers with GDT_KDATA_SEL (0x0010)
    mov ax, GDT_KDATA_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFF0          ; Stack pointer at top of 64KB kernel data segment
    cld

    ; 2. Switch to Runtime GDT in Kernel Data segment (Base = 0x019000 + gdt_table)
    mov ax, gdt_table
    add ax, 0x9000
    mov [gdtr_runtime_base_low], ax
    mov al, 0x01
    adc al, 0
    mov [gdtr_runtime_base_high], al
    lgdt [gdtr_runtime_desc]

    ; 3. Initialize 80286 Hardware TSS
    mov ax, GDT_TSS_SEL     ; 0x0038
    ltr ax                  ; 80286 Load Task Register

    ; 4. Initialize early polling UART (COM1 at 0x3F8, 115200 8N1)
    call uart_init

    ; Emit early serial telemetry
    mov si, str_banner1
    call uart_puts
    mov si, str_banner2
    call uart_puts

    ; 5. Initialize Dual-Display Text Console
    call console_init
    mov si, str_vga_banner
    call console_puts

    ; 6. Initialize IDT (CPU Exception Gates 00h-1Fh & IRQ0)
    call idt_init

    ; 7. CMOS RTC & Hardware Autodetect (Ports 0x70/0x71)
    call cmos_init_and_detect
    mov si, str_prog_cmos
    call console_puts

    ; 8. Remap 8259A PIC (0x20-0x2F) and configure 8253 PIT at 100 Hz
    call pic_init
    call pit_init

    ; 9. Initialize Phase 2 Subsystems:
    ; - GDT Scratch Copy Windows (0x0028, 0x0030)
    ; - Per-process LDT Manager (0x0040-0x0078)
    ; - 24-bit Physical Segment Memory Allocator (Pool A & Pool B)
    ; - Hardware-Trapped Virtual Memory Core (CoW #GP, Demand #NP, #SS)
    call copy_win_init
    call ldt_init
    call seg_init
    call vm_init

    ; 10. Initialize Phase 3 Subsystems:
    ; - Preemptive Round-Robin Scheduler & Task Table
    ; - INT 0x80 System Call Interface
    call sched_init
    call syscall_init

    ; 11. Initialize Phase 4 Subsystems:
    ; - Unified Block Drivers (RAM disk, IDE ATA PIO)
    ; - Buffer Cache (8 x 1024-byte buffers)
    ; - Rootfs (Minix v1 on /), DOS (/dos), /dev, /proc
    call vfs_init
    mov si, str_prog_vfs
    call console_puts

    ; 12. Initialize Phase 5 Subsystems:
    ; - VT102 / ANSI Terminal Parser & 4 Virtual Consoles (tty1..4)
    ; - POSIX termios Line Discipline (5 terminals: ttyS0, tty1..4)
    ; - 8042 Keyboard Driver (IRQ 1 vector 0x21)
    ; - Circular FIFO Pipe Subsystem
    call vt102_init
    call tty_init
    call keyboard_init
    call pipe_init

    ; 13. Initialize Phase 6 Subsystems:
    ; - Native Protected-Mode Framebuffer (/dev/fb0, 0x0A0000 VRAM)
    ; - Zero-Copy LDT Shared Memory (shmget286/shmat286)
    ; - RS-232 Serial Mouse Driver (/dev/mouse)
    ; - PC Speaker (/dev/pcspkr) & Class-D PWM Audio (/dev/dsp)
    ; - Nano-X Display Server Core on tty5 (Alt+F5)
    call fb286_init
    call shm_init
    call mouse_init
    call sound286_init
    call nanox_init

    ; 14. Execute Verification Gate Self-Tests (Phases 1, 2, 3, 4, 5, and 6)
    call run_verification_gate
    call run_phase3_verification_gate
    call run_phase4_verification_gate
    call run_phase5_verification_gate
    call run_phase6_verification_gate
    mov si, str_prog_tests
    call console_puts

    ; Enable maskable interrupts for 100 Hz scheduler tick
    sti

    mov si, str_ready
    call uart_puts
    mov si, str_ready
    call console_puts

    ; Launch Nano-X GUI Desktop on tty5 (Alt+F5)
    call nanox_start_gui

.idle_loop:
    hlt
    jmp .idle_loop

; ----------------------------------------------------------------------------
; Included Kernel Modules
; ----------------------------------------------------------------------------
%include "kernel/arch/i286/uart.asm"
%include "kernel/arch/i286/console.asm"
%include "kernel/arch/i286/cmos.asm"
%include "kernel/arch/i286/pic.asm"
%include "kernel/arch/i286/traps.asm"
%include "kernel/arch/i286/copy_win.asm"
%include "kernel/arch/i286/ldt.asm"
%include "kernel/mm/segalloc.asm"
%include "kernel/mm/vm286.asm"
%include "kernel/sched/task.asm"
%include "kernel/sched/sched.asm"
%include "kernel/arch/i286/syscall.asm"
%include "kernel/sys/sys_proc.asm"
%include "kernel/drivers/ramdisk.asm"
%include "kernel/drivers/ide.asm"
%include "kernel/drivers/blkdev.asm"
%include "kernel/fs/bio.asm"
%include "kernel/fs/minix.asm"
%include "kernel/fs/fat.asm"
%include "kernel/fs/devfs.asm"
%include "kernel/fs/procfs.asm"
%include "kernel/fs/vfs.asm"
%include "kernel/sys/sys_file.asm"
%include "kernel/drivers/vt102.asm"
%include "kernel/drivers/tty.asm"
%include "kernel/drivers/keyboard.asm"
%include "kernel/fs/pipe.asm"
%include "kernel/fs/sash.asm"
%include "kernel/arch/i286/selftest.asm"
%include "kernel/arch/i286/selftest_phase3.asm"
%include "kernel/arch/i286/selftest_phase4.asm"
%include "kernel/arch/i286/selftest_phase5.asm"
%include "kernel/drivers/fb286.asm"
%include "kernel/mm/shm286.asm"
%include "kernel/drivers/mouse.asm"
%include "kernel/drivers/sound286.asm"
%include "kernel/fs/nanox.asm"
%include "kernel/arch/i286/selftest_phase6.asm"

; ----------------------------------------------------------------------------
; Section Boundary Anchors
; ----------------------------------------------------------------------------
section .text
align 16
text_end:

section .data
align 16
data_end:

section .bss
alignb 16
bss_end:

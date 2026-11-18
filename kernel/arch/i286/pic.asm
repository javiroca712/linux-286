CPU 286
BITS 16

; ============================================================================
; Lin286 8259A PIC & 8253 PIT Hardware Driver
;
; Remaps Dual 8259A PIC to vectors 0x20-0x2F (avoiding CPU exceptions 00h-1Fh).
; Configures 8253 PIT Channel 0 at 100 Hz (10 ms scheduler tick).
; ============================================================================

%include "kernel/include/i286_asm.inc"

global pic_init
global pit_init
global irq0_timer_handler
global jiffies

extern uart_puts

section .text

pic_init:
    push ax

    ; ICW1: Start initialization sequence in cascade mode
    mov al, 0x11
    out PIC1_CMD, al
    jmp $+2
    out PIC2_CMD, al
    jmp $+2

    ; ICW2: Master vector offset = 0x20, Slave vector offset = 0x28
    mov al, 0x20
    out PIC1_DATA, al
    jmp $+2
    mov al, 0x28
    out PIC2_DATA, al
    jmp $+2

    ; ICW3: Master has slave on IRQ2 (0x04), Slave has cascade identity (0x02)
    mov al, 0x04
    out PIC1_DATA, al
    jmp $+2
    mov al, 0x02
    out PIC2_DATA, al
    jmp $+2

    ; ICW4: 8086/88 mode
    mov al, 0x01
    out PIC1_DATA, al
    jmp $+2
    out PIC2_DATA, al
    jmp $+2

    ; OCW1: Unmask IRQ0 (Timer) and IRQ2 (Slave Cascade), mask others for now
    mov al, 0xF8            ; 11111000b: IRQ0 (timer), IRQ1 (kbd), IRQ2 (cascade)
    out PIC1_DATA, al
    mov al, 0xFF            ; Mask all slave IRQs for early boot
    out PIC2_DATA, al

    mov si, str_pic_ok
    call uart_puts

    pop ax
    ret

pit_init:
    push ax

    ; Port 0x43: Channel 0, Lobyte/Hibyte, Mode 3 (Square Wave), 16-bit binary
    mov al, 0x36
    out PIT_MODE, al
    jmp $+2

    ; Divider for 100 Hz: 1193182 / 100 = 11932 = 0x2E9C
    mov al, 0x9C            ; Low byte
    out PIT_CH0, al
    jmp $+2
    mov al, 0x2E            ; High byte
    out PIT_CH0, al

    mov si, str_pit_ok
    call uart_puts

    pop ax
    ret

; IRQ 0 Timer Interrupt Handler (Vector 0x20)
irq0_timer_handler:
    push ax

    ; Increment 32-bit tick counter (jiffies)
    inc word [jiffies]
    jnz .no_carry
    inc word [jiffies + 2]
.no_carry:

    ; Send EOI (0x20) to Master PIC
    mov al, 0x20
    out PIC1_CMD, al

    pop ax

    ; Call scheduler timer tick hook
    call sched_tick

    iret

section .data
jiffies:        dw 0, 0
str_pic_ok:     db "[PIC] Dual 8259A PICs remapped to vectors 0x20-0x2F", 13, 10, 0
str_pit_ok:     db "[PIT] 8253 PIT Channel 0 configured to 100 Hz", 13, 10, 0

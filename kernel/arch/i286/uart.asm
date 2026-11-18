CPU 286
BITS 16

; ============================================================================
; Lin286 Early UART Driver (COM1 at 0x3F8)
;
; Direct Ring 0 polling driver for 115200 8N1 serial telemetry.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global uart_init
global uart_putc
global uart_puts
global uart_print_hex16
global uart_print_hex8
global uart_print_dec

section .text

uart_init:
    push dx
    push ax

    ; Disable all UART interrupts
    mov dx, COM1_PORT + 1   ; 0x3F9
    xor al, al
    out dx, al

    ; Enable DLAB (set baud rate divisor)
    mov dx, COM1_PORT + 3   ; 0x3FB (LCR)
    mov al, 0x80
    out dx, al

    ; Set divisor = 1 (115200 baud)
    mov dx, COM1_PORT + 0   ; 0x3F8 (DLL)
    mov al, 0x01
    out dx, al
    mov dx, COM1_PORT + 1   ; 0x3F9 (DLM)
    xor al, al
    out dx, al

    ; Set 8 bits, 1 stop bit, no parity (DLAB=0)
    mov dx, COM1_PORT + 3   ; 0x3FB (LCR)
    mov al, 0x03
    out dx, al

    ; Enable FIFO, clear TX/RX, 14-byte threshold
    mov dx, COM1_PORT + 2   ; 0x3FA (FCR)
    mov al, 0xC7
    out dx, al

    ; Enable DTR, RTS, OUT2
    mov dx, COM1_PORT + 4   ; 0x3FC (MCR)
    mov al, 0x0B
    out dx, al

    pop ax
    pop dx
    ret

; Output character in AL to COM1
uart_putc:
    push dx
    push ax
    mov ah, al

    ; Wait for Line Status Register bit 5 (THRE - Transmitter Holding Reg Empty)
    mov dx, COM1_PORT + 5   ; 0x3FD (LSR)
.wait_tx:
    in al, dx
    test al, 0x20
    jz .wait_tx

    mov al, ah
    mov dx, COM1_PORT       ; 0x3F8 (THR)
    out dx, al

    pop ax
    pop dx
    ret

; Output null-terminated string at DS:SI to COM1
uart_puts:
    push si
    push ax
.loop:
    lodsb
    test al, al
    jz .done
    call uart_putc
    jmp .loop
.done:
    pop ax
    pop si
    ret

; Output 16-bit value in AX as 4 uppercase hex digits
uart_print_hex16:
    push bx
    push cx
    push ax

    mov bx, ax              ; Save AX
    mov cx, 4               ; 4 nibbles
.loop:
    rol bx, 4
    mov al, bl
    and al, 0x0F
    cmp al, 0x0A
    sbb al, 0x69
    das
    call uart_putc
    loop .loop

    pop ax
    pop cx
    pop bx
    ret

; Output 8-bit value in AL as 2 uppercase hex digits
uart_print_hex8:
    push bx
    push ax
    mov bl, al

    ; High nibble
    shr al, 4
    cmp al, 0x0A
    sbb al, 0x69
    das
    call uart_putc

    ; Low nibble
    mov al, bl
    and al, 0x0F
    cmp al, 0x0A
    sbb al, 0x69
    das
    call uart_putc

    pop ax
    pop bx
    ret

; Output 16-bit unsigned value in AX as decimal characters
uart_print_dec:
    push bx
    push cx
    push dx
    push si

    mov bx, 10
    xor cx, cx              ; Count digits

.div_loop:
    xor dx, dx
    div bx                  ; AX = quotient, DX = remainder
    push dx                 ; Save remainder digit
    inc cx
    test ax, ax
    jnz .div_loop

.print_loop:
    pop ax
    add al, '0'
    call uart_putc
    loop .print_loop

    pop si
    pop dx
    pop cx
    pop bx
    ret

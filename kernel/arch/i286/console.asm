CPU 286
BITS 16

; ============================================================================
; Lin286 Dual-Display Text Console Driver
;
; Direct Ring 0 video memory driver for 80x25 Color Text (0xB8000)
; and MDA/Hercules Monochrome Text (0xB0000) via GDT selectors.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global console_init
global console_clear
global console_putc
global console_puts
global console_print_hex16
global console_print_dec

section .text

console_init:
    push es
    push ax
    push di

    mov ax, GDT_VRAM_C_SEL
    mov [console_vram_sel], ax
    mov word [cursor_pos], 0

    call console_clear

    pop di
    pop ax
    pop es
    ret

console_clear:
    push es
    push cx
    push ax
    push di

    mov es, [console_vram_sel]
    xor di, di
    mov ax, 0x0720          ; Light gray on black, space character
    mov cx, 80 * 25
    cld
    rep stosw

    mov word [cursor_pos], 0
    call update_hardware_cursor

    pop di
    pop ax
    pop cx
    pop es
    ret

; Output character in AL to text console
console_putc:
    push es
    push bx
    push dx
    push di
    push ax

    mov es, [console_vram_sel]

    cmp al, 10              ; Line Feed ('\n')
    je .handle_lf
    cmp al, 13              ; Carriage Return ('\r')
    je .handle_cr
    cmp al, 8               ; Backspace
    je .handle_bs

    ; Normal character
    mov di, [cursor_pos]
    shl di, 1               ; 2 bytes per screen character
    mov ah, 0x07            ; Light gray on black
    stosw
    inc word [cursor_pos]
    jmp .check_scroll

.handle_cr:
    mov ax, [cursor_pos]
    xor dx, dx
    mov bx, 80
    div bx                  ; AX = row, DX = col
    sub [cursor_pos], dx    ; cursor_pos = row * 80
    jmp .done

.handle_lf:
    add word [cursor_pos], 80
    jmp .check_scroll

.handle_bs:
    cmp word [cursor_pos], 0
    je .done
    dec word [cursor_pos]
    mov di, [cursor_pos]
    shl di, 1
    mov word [es:di], 0x0720
    jmp .done

.check_scroll:
    cmp word [cursor_pos], 80 * 25
    jb .update_cur

    ; Scroll up 1 line
    push ds
    mov ds, [console_vram_sel]
    mov di, 0
    mov si, 80 * 2          ; Source = line 1
    mov cx, 80 * 24         ; 24 lines to copy
    cld
    rep movsw

    ; Clear line 24
    mov di, 80 * 24 * 2
    mov ax, 0x0720
    mov cx, 80
    rep stosw
    pop ds

    sub word [cursor_pos], 80

.update_cur:
    call update_hardware_cursor

.done:
    pop ax
    pop di
    pop dx
    pop bx
    pop es
    ret

console_puts:
    push si
    push ax
.loop:
    lodsb
    test al, al
    jz .done
    call console_putc
    jmp .loop
.done:
    pop ax
    pop si
    ret

update_hardware_cursor:
    push ax
    push dx
    push bx

    mov bx, [cursor_pos]

    ; CRT Controller Index Port 0x3D4, Data Port 0x3D5
    mov dx, 0x3D4
    mov al, 0x0F            ; Cursor location low register
    out dx, al
    inc dx                  ; 0x3D5
    mov al, bl
    out dx, al

    dec dx                  ; 0x3D4
    mov al, 0x0E            ; Cursor location high register
    out dx, al
    inc dx                  ; 0x3D5
    mov al, bh
    out dx, al

    pop bx
    pop dx
    pop ax
    ret

console_print_hex16:
    push bx
    push cx
    push ax

    mov bx, ax
    mov cx, 4
.loop:
    rol bx, 4
    mov al, bl
    and al, 0x0F
    cmp al, 0x0A
    sbb al, 0x69
    das
    call console_putc
    loop .loop

    pop ax
    pop cx
    pop bx
    ret

console_print_dec:
    push bx
    push cx
    push dx
    push si

    mov bx, 10
    xor cx, cx

.div_loop:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .div_loop

.print_loop:
    pop ax
    add al, '0'
    call console_putc
    loop .print_loop

    pop si
    pop dx
    pop cx
    pop bx
    ret

section .data
console_vram_sel:   dw GDT_VRAM_C_SEL
cursor_pos:         dw 0

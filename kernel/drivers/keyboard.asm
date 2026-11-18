CPU 286
BITS 16

; ============================================================================
; Lin286 8042 Keyboard Controller Driver & IRQ 1 Handler
;
; Decodes Scan Code Set 1, tracks modifier state (Shift, Ctrl, Alt, CapsLock),
; handles Alt+F1..Alt+F4 virtual console switching hotkeys, translates keys to
; ASCII characters and routes them to the active console's TTY line discipline.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global keyboard_init
global irq1_keyboard_handler
global keyboard_process_scancode
global keyboard_simulate_scancode
global kbd_shift_state
global kbd_ctrl_state
global kbd_alt_state

section .text

; ----------------------------------------------------------------------------
; keyboard_init: Initialize keyboard driver state
; ----------------------------------------------------------------------------
keyboard_init:
    push ax
    mov byte [kbd_shift_state], 0
    mov byte [kbd_ctrl_state], 0
    mov byte [kbd_alt_state], 0
    mov byte [kbd_caps_state], 0

    mov si, str_kbd_ok
    call uart_puts
    pop ax
    ret

; ----------------------------------------------------------------------------
; irq1_keyboard_handler: Hardware Interrupt Handler for IRQ 1 (Vector 0x21)
; ----------------------------------------------------------------------------
irq1_keyboard_handler:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es

    ; Load Kernel Data Segment
    mov ax, GDT_KDATA_SEL
    mov ds, ax
    mov es, ax

    ; Read scan code from 8042 data port 0x60
    in al, 0x60

    ; Process the scancode
    call keyboard_process_scancode

    ; Send EOI (0x20) to Master 8259A PIC (port 0x20)
    mov al, 0x20
    out PIC1_CMD, al

    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    iret

; ----------------------------------------------------------------------------
; keyboard_simulate_scancode: Helper for tests to inject scancode directly
; Input: AL = scan code
; ----------------------------------------------------------------------------
keyboard_simulate_scancode:
    pusha
    push ds
    push es
    mov dx, GDT_KDATA_SEL
    mov ds, dx
    mov es, dx
    call keyboard_process_scancode
    pop es
    pop ds
    popa
    ret

; ----------------------------------------------------------------------------
; keyboard_process_scancode: Core Scan Code Set 1 State Machine
; Input: AL = scan code
; ----------------------------------------------------------------------------
keyboard_process_scancode:
    push ax
    mov [saved_scancode], al

    ; 1. Check Shift make/break
    cmp al, 0x2A                        ; Left Shift make
    je .shift_make
    cmp al, 0x36                        ; Right Shift make
    je .shift_make
    cmp al, 0xAA                        ; Left Shift break
    je .shift_break
    cmp al, 0xB6                        ; Right Shift break
    je .shift_break

    ; 2. Check Ctrl make/break
    cmp al, 0x1D                        ; Ctrl make
    je .ctrl_make
    cmp al, 0x9D                        ; Ctrl break
    je .ctrl_break

    ; 3. Check Alt make/break
    cmp al, 0x38                        ; Alt make
    je .alt_make
    cmp al, 0xB8                        ; Alt break
    je .alt_break

    ; 4. Check CapsLock make
    cmp al, 0x3A                        ; CapsLock make
    je .caps_toggle

    ; 5. Check if break code (bit 7 set)
    test al, 0x80
    jnz .proc_done                      ; Ignore other key releases

    ; --- MAKE CODE PROCESSING ---

    ; 6. Check Alt+F1..Alt+F4 Console Switching Hotkeys
    cmp byte [kbd_alt_state], 0
    jz .check_regular_key

    ; Alt is held down!
    cmp al, 0x3B                        ; F1 -> Switch to tty1 (VC 0)
    je .hotkey_f1
    cmp al, 0x3C                        ; F2 -> Switch to tty2 (VC 1)
    je .hotkey_f2
    cmp al, 0x3D                        ; F3 -> Switch to tty3 (VC 2)
    je .hotkey_f3
    cmp al, 0x3E                        ; F4 -> Switch to tty4 (VC 3)
    je .hotkey_f4
    cmp al, 0x3F                        ; F5 -> Switch to tty5 (VC 4, GUI)
    je .hotkey_f5

.check_regular_key:
    ; 7. Translate make code to ASCII
    mov al, [saved_scancode]
    cmp al, KBD_TABLE_SIZE
    jae .proc_done                      ; Out of table range

    xor ah, ah
    mov si, kbd_normal_map
    cmp byte [kbd_shift_state], 0
    jz .use_normal
    mov si, kbd_shift_map

.use_normal:
    add si, ax
    mov al, [si]
    test al, al
    jz .proc_done                      ; Non-printable or unassigned

    ; Apply CapsLock if letter
    cmp byte [kbd_caps_state], 0
    jz .check_ctrl_mod
    cmp al, 'a'
    jb .check_ctrl_mod
    cmp al, 'z'
    ja .check_ctrl_mod
    sub al, 32                          ; Convert to uppercase

.check_ctrl_mod:
    ; Apply Ctrl: ^A..^Z (1..26)
    cmp byte [kbd_ctrl_state], 0
    jz .dispatch_to_tty
    cmp al, 'a'
    jb .check_ctrl_upper
    cmp al, 'z'
    ja .check_ctrl_upper
    and al, 0x1F                        ; Map to 1..26
    jmp .dispatch_to_tty

.check_ctrl_upper:
    cmp al, 'A'
    jb .dispatch_to_tty
    cmp al, 'Z'
    ja .dispatch_to_tty
    and al, 0x1F

.dispatch_to_tty:
    ; Route character into active console's TTY line discipline
    ; Active console is 0..3 -> TTY index is 1..4
    mov bl, [active_console]
    inc bl                              ; TTY 1..4
    xor bh, bh
    call tty_input_char
    jmp .proc_done

.hotkey_f1:
    mov al, 0
    call vt102_switch_console
    jmp .proc_done

.hotkey_f2:
    mov al, 1
    call vt102_switch_console
    jmp .proc_done

.hotkey_f3:
    mov al, 2
    call vt102_switch_console
    jmp .proc_done

.hotkey_f4:
    mov al, 3
    call vt102_switch_console
    jmp .proc_done

.hotkey_f5:
    mov al, 4
    call vt102_switch_console
    jmp .proc_done

.shift_make:
    mov byte [kbd_shift_state], 1
    jmp .proc_done

.shift_break:
    mov byte [kbd_shift_state], 0
    jmp .proc_done

.ctrl_make:
    mov byte [kbd_ctrl_state], 1
    jmp .proc_done

.ctrl_break:
    mov byte [kbd_ctrl_state], 0
    jmp .proc_done

.alt_make:
    mov byte [kbd_alt_state], 1
    jmp .proc_done

.alt_break:
    mov byte [kbd_alt_state], 0
    jmp .proc_done

.caps_toggle:
    xor byte [kbd_caps_state], 1
    jmp .proc_done

.proc_done:
    pop ax
    ret

section .data
str_kbd_ok:     db "[KBD] 8042 Keyboard driver & IRQ 1 handler initialized", 13, 10, 0
saved_scancode: db 0

KBD_TABLE_SIZE  equ 58

; Scan Code Set 1 -> ASCII Translation Table (Normal)
align 2
kbd_normal_map:
    db 0,   27,  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8   ; 00..0E
    db 9,   'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', 13, 0   ; 0F..1D
    db 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', 39,  '`', 0,   '\', 'z' ; 1E..2C
    db 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0,   '*', 0,   ' ', 0        ; 2D..3A

; Scan Code Set 1 -> ASCII Translation Table (Shifted)
align 2
kbd_shift_map:
    db 0,   27,  '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8   ; 00..0E
    db 9,   'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 13, 0   ; 0F..1D
    db 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', 34,  '~', 0,   '|', 'Z' ; 1E..2C
    db 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0,   '*', 0,   ' ', 0        ; 2D..3A

section .bss
align 2
kbd_shift_state: resb 1
kbd_ctrl_state:  resb 1
kbd_alt_state:   resb 1
kbd_caps_state:  resb 1

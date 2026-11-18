CPU 286
BITS 16

; ============================================================================
; Lin286 GDT Scratch Copy Windows (Selectors 0x0028 and 0x0030)
;
; Implements zero-overhead Ring 0 fast cross-segment physical memory copy
; and fill operations across the entire 16 MB 80286 address space.
;
; Dynamically reprograms GDT Index 5 (GDT_COPY_A_SEL = 0x0028) as Source
; and GDT Index 6 (GDT_COPY_B_SEL = 0x0030) as Destination.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global copy_win_init
global phys_copy
global phys_set

section .text

; ----------------------------------------------------------------------------
; copy_win_init: Initialize GDT Copy Window descriptors
; ----------------------------------------------------------------------------
copy_win_init:
    pusha

    ; Initialize Copy Window A (0x0028)
    mov word [gdt_table + 0x28 + 0], 0xFFFF     ; Limit = 64KB
    mov word [gdt_table + 0x28 + 2], 0x0000     ; Base 15..0
    mov byte [gdt_table + 0x28 + 4], 0x00       ; Base 23..16
    mov byte [gdt_table + 0x28 + 5], 0x92       ; Present, Ring 0, Data R/W
    mov word [gdt_table + 0x28 + 6], 0x0000

    ; Initialize Copy Window B (0x0030)
    mov word [gdt_table + 0x30 + 0], 0xFFFF     ; Limit = 64KB
    mov word [gdt_table + 0x30 + 2], 0x0000     ; Base 15..0
    mov byte [gdt_table + 0x30 + 4], 0x00       ; Base 23..16
    mov byte [gdt_table + 0x30 + 5], 0x92       ; Present, Ring 0, Data R/W
    mov word [gdt_table + 0x30 + 6], 0x0000

    mov si, str_copy_win_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; phys_copy: Fast physical memory copy
;
; Inputs:
;   DL:SI = 24-bit Source Physical Address (DL=bits 23..16, SI=bits 15..0)
;   DH:DI = 24-bit Destination Physical Address (DH=bits 23..16, DI=bits 15..0)
;   CX    = Byte count to copy (1 to 65535)
;
; Preserves: All general registers and segment registers
; ----------------------------------------------------------------------------
phys_copy:
    pusha
    push ds
    push es

    test cx, cx
    jz .done

    ; Aim Window A at source physical address
    mov [gdt_table + 0x28 + 2], si      ; Base 15..0
    mov [gdt_table + 0x28 + 4], dl      ; Base 23..16

    ; Aim Window B at destination physical address
    mov [gdt_table + 0x30 + 2], di      ; Base 15..0
    mov [gdt_table + 0x30 + 4], dh      ; Base 23..16

    ; Reload DS and ES with the copy window selectors.
    ; This forces the 80286 to reload its internal descriptor caches.
    mov ax, GDT_COPY_A_SEL
    mov ds, ax
    mov ax, GDT_COPY_B_SEL
    mov es, ax

    ; Copy using word-aligned REP MOVSW for max bus throughput
    xor si, si                          ; Offset within Window A = 0
    xor di, di                          ; Offset within Window B = 0
    cld

    mov bx, cx                          ; Save total byte count
    shr cx, 1                           ; Convert to 16-bit words
    jz .check_odd
    rep movsw                           ; Native 80286 16-bit bus transfer

.check_odd:
    test bx, 1                          ; Odd remaining byte?
    jz .done
    movsb

.done:
    pop es
    pop ds
    popa
    ret

; ----------------------------------------------------------------------------
; phys_set: Fast physical memory fill
;
; Inputs:
;   DH:DI = 24-bit Destination Physical Address (DH=bits 23..16, DI=bits 15..0)
;   AL    = Fill byte value
;   CX    = Byte count to fill (1 to 65535)
;
; Preserves: All general registers and segment registers
; ----------------------------------------------------------------------------
phys_set:
    pusha
    push es

    test cx, cx
    jz .done

    ; Aim Window B at destination physical address
    mov [gdt_table + 0x30 + 2], di
    mov [gdt_table + 0x30 + 4], dh

    ; Reload ES with GDT_COPY_B_SEL
    mov dx, GDT_COPY_B_SEL
    mov es, dx

    xor di, di
    cld

    ; Duplicate AL into AH for word-sized fill
    mov ah, al
    mov bx, cx
    shr cx, 1
    jz .check_odd
    rep stosw

.check_odd:
    test bx, 1
    jz .done
    stosb

.done:
    pop es
    popa
    ret

section .data
str_copy_win_ok: db "[COPYWIN] GDT Scratch Copy Windows (0x0028, 0x0030) initialized", 13, 10, 0

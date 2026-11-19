CPU 286
BITS 16

; ============================================================================
; Lin286 VT102 / ANSI Terminal Parser & 4 Virtual Consoles Driver
;
; Manages 4 Virtual Consoles (tty1..4), each with an independent 80x25 (4000 byte)
; backing screen buffer, cursor position, and ANSI escape state machine.
; Blits backing buffers to/from physical video RAM (0xB8000) on Alt+F1..Alt+F4.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global vt102_init
global vt102_switch_console
global vt102_write_char
global vt102_write
global vt102_puts
global vt102_get_active
global vt102_get_cursor
global vt102_get_attr
global vt102_read_cell
global active_console

; VC Descriptor Offsets (8 bytes per console)
VC_CURSOR       equ 0   ; dw
VC_ATTR         equ 2   ; db
VC_STATE        equ 3   ; db
VC_PARAM1       equ 4   ; dw
VC_PARAM2       equ 6   ; dw
VC_DESC_SIZE    equ 8

section .text

; ----------------------------------------------------------------------------
; vt102_init: Initialize all 4 virtual console buffers & state
; ----------------------------------------------------------------------------
vt102_init:
    pusha
    push es

    mov ax, ds
    mov es, ax

    mov cx, NR_CONSOLES
    xor bx, bx                          ; BX = console index (0..3)

.init_vc_loop:
    ; 1. Clear backing buffer with 0x0720 (space, light gray on black)
    push cx
    push bx
    call get_vc_buf_ptr                 ; DI = &vc_buffers[bx * 4000]
    mov ax, 0x0720
    mov cx, 80 * 25
    cld
    rep stosw
    pop bx
    pop cx

    ; 2. Initialize cursor, attr, state
    push cx
    push bx
    call get_vc_desc_ptr                ; DI = &vc_descs[bx * 8]
    mov word [di + VC_CURSOR], 0
    mov byte [di + VC_ATTR], 0x07
    mov byte [di + VC_STATE], 0
    mov word [di + VC_PARAM1], 0
    mov word [di + VC_PARAM2], 0
    pop bx
    pop cx

    inc bx
    loop .init_vc_loop

    mov byte [active_console], 0

    mov si, str_vt102_ok
    call uart_puts

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; get_vc_desc_ptr: Helper to get pointer to VC descriptor (8 bytes)
; Input:  BX = console index (0..3)
; Output: DI = pointer to struct vc_desc in DS
; ----------------------------------------------------------------------------
get_vc_desc_ptr:
    mov di, bx
    shl di, 3                          ; DI = BX * 8
    add di, vc_descs
    ret

; ----------------------------------------------------------------------------
; get_vc_buf_ptr: Get pointer to VC backing buffer in DS
; Input:  BX = console index (0..3)
; Output: DI = pointer to 4000-byte buffer in DS
; ----------------------------------------------------------------------------
get_vc_buf_ptr:
    mov di, bx
    push ax
    push dx
    mov ax, 4000
    mul di                              ; DX:AX = DI * 4000
    add ax, vc_buffers
    mov di, ax
    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; vt102_switch_console: Switch active virtual console
; Input:  AL = new console index (0..3)
; Returns: AX = 1 if switched, 0 if already active / invalid
; ----------------------------------------------------------------------------
vt102_switch_console:
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds

    cmp al, NR_CONSOLES
    jae .bad_switch

    xor ah, ah
    mov bl, [active_console]
    xor bh, bh
    cmp ax, bx
    je .no_change                       ; Already active

    mov [target_vc], ax

    ; 1. Save current physical VRAM (0xB8000) to current active console's backing buffer
    mov bl, [active_console]
    xor bh, bh
    call get_vc_buf_ptr                 ; DI = active VC buffer
    push ds
    pop es                              ; ES:DI = backing buffer

    mov ax, GDT_VRAM_C_SEL
    mov ds, ax
    xor si, si                          ; DS:SI = VRAM

    mov cx, 2000                        ; 2000 words = 4000 bytes
    cld
    rep movsw

    ; Restore DS = GDT_KDATA_SEL
    mov ax, GDT_KDATA_SEL
    mov ds, ax

    ; 2. Copy target console's backing buffer to physical VRAM (0xB8000 & 0xB0000)
    mov bx, [target_vc]
    call get_vc_buf_ptr
    mov si, di                          ; DS:SI = target backing buffer

    mov ax, GDT_VRAM_C_SEL
    mov es, ax
    xor di, di                          ; ES:DI = 0xB8000 Color VRAM
    mov cx, 2000
    cld
    rep movsw

    ; Also mirror to 0xB0000 Monochrome/Hercules VRAM (Winbond W86855AF)
    mov bx, [target_vc]
    call get_vc_buf_ptr
    mov si, di
    mov ax, GDT_VRAM_M_SEL
    mov es, ax
    xor di, di                          ; ES:DI = 0xB0000 Mono VRAM
    mov cx, 2000
    cld
    rep movsw

    ; 3. Update active_console
    mov ax, [target_vc]
    mov [active_console], al

    ; 4. Update hardware text cursor to match target console
    mov bx, ax
    call get_vc_desc_ptr
    mov ax, [di + VC_CURSOR]
    call vt102_update_hw_cursor

    pop ds
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    mov ax, 1
    ret

.no_change:
    pop ds
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    mov ax, 1
    ret

.bad_switch:
    pop ds
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    xor ax, ax
    ret

; ----------------------------------------------------------------------------
; vt102_update_hw_cursor: Program CRT Controller with cursor position
; Input: AX = cursor cell offset (0..1999)
; ----------------------------------------------------------------------------
vt102_update_hw_cursor:
    push dx
    push ax
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc dx
    pop ax
    push ax
    out dx, al                          ; Cursor Low Register
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    pop ax
    mov al, ah
    out dx, al                          ; Cursor High Register
    pop dx
    ret

; ----------------------------------------------------------------------------
; vt102_scroll_up: Scroll VC backing buffer up by 1 line
; Input: BX = Console index (0..3)
; ----------------------------------------------------------------------------
vt102_scroll_up:
    pusha
    push es

    mov ax, ds
    mov es, ax

    call get_vc_desc_ptr
    mov bp, di                          ; BP = vc_desc

    call get_vc_buf_ptr                 ; DI = base of buffer

    ; Move 24 rows up: copy from [DI + 160] to [DI] (80 * 24 words = 1920 words)
    push di
    lea si, [di + 160]                  ; Source: row 1
    mov cx, 80 * 24                     ; 1920 words
    cld
    rep movsw

    ; Blank last row (row 24): 80 words at [DI]
    mov al, ' '
    mov ah, [bp + VC_ATTR]
    mov cx, 80
    rep stosw
    pop di

    ; If this console is active, also scroll physical VRAM
    cmp bl, [active_console]
    jne .scroll_done

    mov ax, GDT_VRAM_C_SEL
    mov es, ax
    mov ds, ax
    xor di, di
    mov si, 160
    mov cx, 80 * 24
    cld
    rep movsw

    mov al, ' '
    mov ah, 0x07
    mov cx, 80
    rep stosw

    mov ax, GDT_KDATA_SEL
    mov ds, ax

.scroll_done:
    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; vt102_write_char: Output character through ANSI parser to console BX
; Inputs:
;   BX = console index (0..3)
;   AL = character to output
; ----------------------------------------------------------------------------
vt102_write_char:
    pusha
    push es

    mov [saved_vc_idx], bx
    mov [saved_char_al], al

    call get_vc_desc_ptr
    mov bp, di                          ; BP = pointer to struct vc_desc

    ; Read current parser state for console BX
    mov dl, [bp + VC_STATE]

    cmp dl, 0
    je .state_normal
    cmp dl, 1
    je .state_esc
    cmp dl, 2
    je .state_csi
    cmp dl, 3
    je .state_param2

    ; Invalid state -> reset to 0
    mov byte [bp + VC_STATE], 0
    jmp .state_normal

; ----------------------------------------------------------------------------
; State 0: Normal Character Processing
; ----------------------------------------------------------------------------
.state_normal:
    mov al, [saved_char_al]

    cmp al, 27                          ; ESC (0x1B)
    je .enter_esc

    cmp al, 10                          ; LF ('\n')
    je .handle_lf

    cmp al, 13                          ; CR ('\r')
    je .handle_cr

    cmp al, 8                           ; Backspace ('\b')
    je .handle_bs

    ; Normal printable character
    mov bx, [saved_vc_idx]
    call get_vc_buf_ptr                 ; DI = base of backing buffer
    mov si, [bp + VC_CURSOR]            ; SI = cursor pos (cells)
    cmp si, 2000
    jb .pos_valid
    mov si, 1999
.pos_valid:
    shl si, 1                           ; SI = byte offset
    add di, si                          ; DI = exact address in backing buffer

    mov al, [saved_char_al]
    mov ah, [bp + VC_ATTR]
    mov [di], ax                        ; Write to backing buffer

    ; If console is active, write to physical VRAM too
    mov bl, [saved_vc_idx]
    cmp bl, [active_console]
    jne .adv_cursor

    mov ax, GDT_VRAM_C_SEL
    mov es, ax
    mov di, [bp + VC_CURSOR]
    shl di, 1
    mov al, [saved_char_al]
    mov ah, [bp + VC_ATTR]
    mov [es:di], ax

.adv_cursor:
    inc word [bp + VC_CURSOR]
    cmp word [bp + VC_CURSOR], 2000
    jb .char_finish

    ; Hit bottom: scroll up and clamp to row 24
    mov bx, [saved_vc_idx]
    call vt102_scroll_up
    mov word [bp + VC_CURSOR], 80 * 24
    jmp .char_finish

.handle_cr:
    mov ax, [bp + VC_CURSOR]
    xor dx, dx
    mov cx, 80
    div cx                              ; AX = row, DX = col
    sub [bp + VC_CURSOR], dx            ; cursor = row * 80
    jmp .char_finish

.handle_lf:
    add word [bp + VC_CURSOR], 80
    cmp word [bp + VC_CURSOR], 2000
    jb .char_finish
    mov bx, [saved_vc_idx]
    call vt102_scroll_up
    sub word [bp + VC_CURSOR], 80
    jmp .char_finish

.handle_bs:
    cmp word [bp + VC_CURSOR], 0
    je .char_finish
    dec word [bp + VC_CURSOR]
    jmp .char_finish

.enter_esc:
    mov byte [bp + VC_STATE], 1         ; Enter ESC state
    jmp .char_finish

; ----------------------------------------------------------------------------
; State 1: Saw ESC (0x1B)
; ----------------------------------------------------------------------------
.state_esc:
    mov al, [saved_char_al]

    cmp al, '['                         ; CSI (Control Sequence Introducer)
    je .enter_csi

    ; Unrecognized ESC sequence -> return to normal
    mov byte [bp + VC_STATE], 0
    jmp .char_finish

.enter_csi:
    mov byte [bp + VC_STATE], 2
    mov word [bp + VC_PARAM1], 0
    mov word [bp + VC_PARAM2], 0
    jmp .char_finish

; ----------------------------------------------------------------------------
; State 2 & 3: CSI Argument Processing
; ----------------------------------------------------------------------------
.state_csi:
    mov al, [saved_char_al]

    cmp al, '0'
    jb .check_csi_cmd
    cmp al, '9'
    ja .check_csi_cmd

    sub al, '0'
    xor ah, ah
    push ax
    mov ax, [bp + VC_PARAM1]
    mov cx, 10
    mul cx
    pop cx
    add ax, cx
    mov [bp + VC_PARAM1], ax
    jmp .char_finish

.check_csi_cmd:
    cmp al, ';'
    je .enter_param2

    jmp .dispatch_csi_cmd

.enter_param2:
    mov byte [bp + VC_STATE], 3         ; Reading param2
    jmp .char_finish

.state_param2:
    mov al, [saved_char_al]

    cmp al, '0'
    jb .dispatch_csi_cmd
    cmp al, '9'
    ja .dispatch_csi_cmd

    sub al, '0'
    xor ah, ah
    push ax
    mov ax, [bp + VC_PARAM2]
    mov cx, 10
    mul cx
    pop cx
    add ax, cx
    mov [bp + VC_PARAM2], ax
    jmp .char_finish

; ----------------------------------------------------------------------------
; CSI Command Dispatch
; ----------------------------------------------------------------------------
.dispatch_csi_cmd:
    mov al, [saved_char_al]
    mov byte [bp + VC_STATE], 0         ; Reset state to normal

    cmp al, 'H'                         ; Cursor Position
    je .csi_cup
    cmp al, 'f'                         ; Horizontal and Vertical Position (HVP)
    je .csi_cup
    cmp al, 'A'                         ; Cursor Up
    je .csi_cuu
    cmp al, 'B'                         ; Cursor Down
    je .csi_cud
    cmp al, 'C'                         ; Cursor Forward
    je .csi_cuf
    cmp al, 'D'                         ; Cursor Backward
    je .csi_cub
    cmp al, 'J'                         ; Erase in Display
    je .csi_ed
    cmp al, 'K'                         ; Erase in Line
    je .csi_el
    cmp al, 'm'                         ; Select Graphic Rendition (SGR)
    je .csi_sgr
    jmp .char_finish

; Cursor Position: \033[row;colH (1-indexed)
.csi_cup:
    mov ax, [bp + VC_PARAM1]
    test ax, ax
    jz .cup_row1
    dec ax                              ; 1-indexed -> 0-indexed row
.cup_row1:
    cmp ax, 25
    jb .row_ok
    mov ax, 24
.row_ok:
    mov cx, 80
    mul cx                              ; AX = row * 80
    mov dx, ax

    mov ax, [bp + VC_PARAM2]
    test ax, ax
    jz .cup_col1
    dec ax                              ; 1-indexed -> 0-indexed col
.cup_col1:
    cmp ax, 80
    jb .col_ok
    mov ax, 79
.col_ok:
    add dx, ax                          ; DX = row * 80 + col
    mov [bp + VC_CURSOR], dx
    jmp .char_finish

; Cursor Up: \033[nA
.csi_cuu:
    mov ax, [bp + VC_PARAM1]
    test ax, ax
    jnz .cuu_val
    mov ax, 1
.cuu_val:
    mov cx, 80
    mul cx
    mov dx, [bp + VC_CURSOR]
    cmp dx, ax
    jae .cuu_ok
    xor dx, dx
    mov [bp + VC_CURSOR], dx
    jmp .char_finish
.cuu_ok:
    sub dx, ax
    mov [bp + VC_CURSOR], dx
    jmp .char_finish

; Cursor Down: \033[nB
.csi_cud:
    mov ax, [bp + VC_PARAM1]
    test ax, ax
    jnz .cud_val
    mov ax, 1
.cud_val:
    mov cx, 80
    mul cx
    add ax, [bp + VC_CURSOR]
    cmp ax, 2000
    jb .cud_ok
    mov ax, 1999
.cud_ok:
    mov [bp + VC_CURSOR], ax
    jmp .char_finish

; Cursor Forward: \033[nC
.csi_cuf:
    mov ax, [bp + VC_PARAM1]
    test ax, ax
    jnz .cuf_val
    mov ax, 1
.cuf_val:
    add ax, [bp + VC_CURSOR]
    cmp ax, 2000
    jb .cuf_ok
    mov ax, 1999
.cuf_ok:
    mov [bp + VC_CURSOR], ax
    jmp .char_finish

; Cursor Backward: \033[nD
.csi_cub:
    mov ax, [bp + VC_PARAM1]
    test ax, ax
    jnz .cub_val
    mov ax, 1
.cub_val:
    mov dx, [bp + VC_CURSOR]
    cmp dx, ax
    jae .cub_ok
    xor dx, dx
    mov [bp + VC_CURSOR], dx
    jmp .char_finish
.cub_ok:
    sub dx, ax
    mov [bp + VC_CURSOR], dx
    jmp .char_finish

; Erase in Display: \033[2J (Clear entire screen)
.csi_ed:
    cmp word [bp + VC_PARAM1], 2
    jne .char_finish

    ; Clear backing buffer
    mov bx, [saved_vc_idx]
    call get_vc_buf_ptr
    mov ax, ds
    mov es, ax
    mov al, ' '
    mov ah, [bp + VC_ATTR]
    mov cx, 80 * 25
    cld
    rep stosw

    mov word [bp + VC_CURSOR], 0

    ; If active, clear physical VRAM
    mov bl, [saved_vc_idx]
    cmp bl, [active_console]
    jne .char_finish

    mov ax, GDT_VRAM_C_SEL
    mov es, ax
    xor di, di
    mov al, ' '
    mov ah, [bp + VC_ATTR]
    mov cx, 80 * 25
    cld
    rep stosw
    jmp .char_finish

; Erase in Line: \033[K (Clear from cursor to end of line)
.csi_el:
    mov ax, [bp + VC_CURSOR]
    xor dx, dx
    mov cx, 80
    div cx                              ; AX = row, DX = col
    mov cx, 80
    sub cx, dx                          ; CX = columns remaining on this row
    jz .char_finish

    ; Write spaces to backing buffer
    mov bx, [saved_vc_idx]
    call get_vc_buf_ptr                 ; DI = base of backing buffer
    mov si, [bp + VC_CURSOR]
    shl si, 1
    add di, si                          ; DI = start of spaces in backing buffer
    push di
    mov ax, ds
    mov es, ax
    mov al, ' '
    mov ah, [bp + VC_ATTR]
    cld
    rep stosw
    pop di

    ; If active, update VRAM
    mov bl, [saved_vc_idx]
    cmp bl, [active_console]
    jne .char_finish

    mov cx, 80
    sub cx, dx
    mov di, [bp + VC_CURSOR]
    shl di, 1
    mov ax, GDT_VRAM_C_SEL
    mov es, ax
    mov al, ' '
    mov ah, [bp + VC_ATTR]
    cld
    rep stosw
    jmp .char_finish

; Select Graphic Rendition: \033[nm
.csi_sgr:
    mov ax, [bp + VC_PARAM1]

    ; 0: Reset all attributes
    test ax, ax
    jnz .sgr_bold
    mov byte [bp + VC_ATTR], 0x07
    jmp .char_finish

.sgr_bold:
    cmp ax, 1
    jne .sgr_fg
    or byte [bp + VC_ATTR], 0x08        ; High intensity bit
    jmp .char_finish

.sgr_fg:
    cmp ax, 30
    jb .sgr_bg
    cmp ax, 37
    ja .sgr_bg

    sub ax, 30
    mov si, ansi_to_vga_table
    add si, ax
    mov dl, [si]                        ; DL = VGA fg color (0..7)

    mov al, [bp + VC_ATTR]
    and al, 0xF8                        ; Clear low 3 bits
    or al, dl
    mov [bp + VC_ATTR], al
    jmp .char_finish

.sgr_bg:
    cmp ax, 40
    jb .char_finish
    cmp ax, 47
    ja .char_finish

    sub ax, 40
    mov si, ansi_to_vga_table
    add si, ax
    mov dl, [si]
    shl dl, 4

    mov al, [bp + VC_ATTR]
    and al, 0x8F                        ; Clear bits 4..6
    or al, dl
    mov [bp + VC_ATTR], al

.char_finish:
    mov bl, [saved_vc_idx]
    cmp bl, [active_console]
    jne .finish_all

    mov ax, [bp + VC_CURSOR]
    call vt102_update_hw_cursor

.finish_all:
    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; vt102_write: Write buffer of length CX to console BX
; Inputs:
;   BX = console index (0..3)
;   SI = source buffer in Kernel Data (DS)
;   CX = byte count
; ----------------------------------------------------------------------------
vt102_write:
    push si
    push cx
    push ax
    test cx, cx
    jz .write_done
.write_loop:
    lodsb
    call vt102_write_char
    loop .write_loop
.write_done:
    pop ax
    pop cx
    pop si
    ret

; ----------------------------------------------------------------------------
; vt102_puts: Output null-terminated string to console BX
; ----------------------------------------------------------------------------
vt102_puts:
    push si
    push ax
.puts_loop:
    lodsb
    test al, al
    jz .puts_done
    call vt102_write_char
    jmp .puts_loop
.puts_done:
    pop ax
    pop si
    ret

; ----------------------------------------------------------------------------
; Status Query Functions
; ----------------------------------------------------------------------------
vt102_get_active:
    mov al, [active_console]
    xor ah, ah
    ret

vt102_get_cursor:
    ; BX = console index
    push di
    call get_vc_desc_ptr
    mov ax, [di + VC_CURSOR]
    pop di
    ret

vt102_get_attr:
    ; BX = console index
    push di
    call get_vc_desc_ptr
    mov al, [di + VC_ATTR]
    xor ah, ah
    pop di
    ret

vt102_read_cell:
    ; BX = console index, AX = cell offset (0..1999)
    push bx
    push di
    push ax
    call get_vc_buf_ptr                 ; DI = base
    pop ax
    shl ax, 1
    add di, ax
    mov ax, [di]                        ; AX = character + attribute
    pop di
    pop bx
    ret

section .data
str_vt102_ok:   db "[VT102] 4 Virtual Consoles (tty1..4) & ANSI terminal parser initialized", 13, 10, 0

; ANSI color to VGA text color mapping (Black, Red, Green, Brown, Blue, Magenta, Cyan, White)
ansi_to_vga_table:
    db 0x00, 0x04, 0x02, 0x06, 0x01, 0x05, 0x03, 0x07

saved_vc_idx:   dw 0
saved_char_al:  db 0
target_vc:      dw 0

section .bss
alignb 4
active_console: resb 1
alignb 2
vc_descs:       resb (NR_CONSOLES * VC_DESC_SIZE) ; 4 * 8 = 32 bytes

alignb 16
vc_buffers:     resb (NR_CONSOLES * VC_BUF_SIZE) ; 4 * 4000 = 16,000 bytes

section .text

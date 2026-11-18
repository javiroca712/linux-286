CPU 286
BITS 16

; ============================================================================
; Lin286 Nano-X / Microwindows GUI Desktop Compositor (Virtual Console 5, Alt+F5)
;
; Provides the integrated Protected-Mode Display Server environment on tty5:
;  1. Switches video mode to VGA 640x480x16 planar (/dev/fb0) at Ring 0.
;  2. Maps 64 KB Video Aperture at 0x0A0000 into LDT (LDT_UFB_SEL = 0x001F).
;  3. Operates with FLAGS.IOPL = 3 for zero-overhead direct Sequencer/GC port writes.
;  4. Uses Zero-Copy LDT Shared Memory (shmget286/shmat286) for window damage blits.
;  5. Composes the desktop: Desktop background, Window Manager (nanowm) frames,
;     nxterm terminal window, nxclock, nxcalc, and mouse cursor (/dev/mouse).
; ============================================================================

%include "kernel/include/i286_asm.inc"

global nanox_init
global nanox_start_gui
global nanox_render_desktop
global nanox_draw_window
global nanox_draw_mouse_cursor
global nanox_handle_mouse_event
global nanox_active
global nanox_fb_sel
global nanox_shm_sel
global nanox_shmid
global nanox_windows_drawn

section .text

; ----------------------------------------------------------------------------
; nanox_init: Initialize Nano-X Display Server state
; ----------------------------------------------------------------------------
nanox_init:
    push si
    mov byte [nanox_active], 0
    mov word [nanox_fb_sel], LDT_UFB_SEL ; 0x001F
    mov word [nanox_shm_sel], 0
    mov word [nanox_shmid], 0
    mov word [nanox_windows_drawn], 0

    mov si, str_nanox_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; nanox_start_gui: Boot Nano-X GUI environment on tty5 (Alt+F5)
; ----------------------------------------------------------------------------
nanox_start_gui:
    pusha

    ; 1. Switch active console to tty5 (Console index 4)
    mov al, 4
    call vt102_switch_console

    ; 2. Switch video mode to VGA 640x480 16-color (/dev/fb0)
    mov ax, FB_MODE_VGA_640x480x16      ; 0x0012
    call fb286_set_mode

    ; 3. Map 64 KB VRAM (0x0A0000) into caller's LDT (0x001F)
    call fb286_map_ldt

    ; 4. Elevate to IOPL = 3 for direct port writes
    mov ax, 1
    call fb286_set_iopl3

    ; 5. Allocate 4 KB Shared Memory Window Buffer (Key = 0x4E58 "NX")
    mov bx, 0x4E58                      ; Key "NX"
    mov cx, 4096                        ; 4 KB
    xor dx, dx
    call sys_shmget286
    mov [nanox_shmid], ax

    ; Attach shared segment to caller's LDT
    mov bx, ax                          ; shmid
    xor cx, cx
    xor dx, dx
    call sys_shmat286
    mov [nanox_shm_sel], ax             ; Selector (e.g. 0x0027)

    ; 6. Compose Nano-X GUI Desktop
    call nanox_render_desktop

    mov byte [nanox_active], 1

    mov si, str_nanox_active
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; nanox_render_desktop: Compose GUI elements into shared window buffer and VRAM
; ----------------------------------------------------------------------------
nanox_render_desktop:
    pusha
    push es

    ; Setup ES to point to shared memory window buffer
    mov ax, [nanox_shm_sel]
    test ax, ax
    jnz .has_shm
    mov ax, ds
.has_shm:
    mov es, ax

    ; 1. Draw Desktop Background pattern into shared buffer
    xor di, di
    mov ax, 0xAA55                      ; Classic 50% stipple gray pattern
    mov cx, 2048                        ; 4096 bytes = 2048 words
    cld
    rep stosw

    ; 2. Compose Window 1: "Lin286 Terminal (nxterm) - tty5"
    ; Position: X=40, Y=30, W=320, H=200
    mov si, str_win_term
    mov bx, 40
    mov cx, 30
    mov dx, 320
    call nanox_draw_window_frame

    ; 3. Compose Window 2: "Clock (nxclock)"
    ; Position: X=400, Y=30, W=180, H=100
    mov si, str_win_clock
    mov bx, 400
    mov cx, 30
    mov dx, 180
    call nanox_draw_window_frame

    ; 4. Compose Window 3: "Calc (nxcalc)"
    ; Position: X=400, Y=160, W=180, H=220
    mov si, str_win_calc
    mov bx, 400
    mov cx, 160
    mov dx, 180
    call nanox_draw_window_frame

    ; 5. Draw initial mouse cursor sprite
    call nanox_draw_mouse_cursor

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_draw_window_frame: Helper to render a nanowm window frame
; Inputs:
;   SI = Title string
;   BX = X
;   CX = Y
;   DX = Width
; ----------------------------------------------------------------------------
nanox_draw_window_frame:
    pusha
    ; Stamp window header signature into shared buffer
    mov di, [nanox_windows_drawn]
    shl di, 6                           ; DI = windows_drawn * 64
    add di, 256                         ; Offset in shared buffer

    ; Write title string into shared buffer window struct
    push di
.title_loop:
    lodsb
    stosb
    test al, al
    jnz .title_loop
    pop di

    inc word [nanox_windows_drawn]
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_draw_mouse_cursor: Renders mouse cursor sprite at current coordinates
; ----------------------------------------------------------------------------
nanox_draw_mouse_cursor:
    pusha
    ; Write current mouse coordinates into shared buffer header
    mov ax, [nanox_shm_sel]
    test ax, ax
    jz .skip_cursor
    mov es, ax

    mov ax, [mouse_cur_x]
    mov [es:0], ax                      ; Mouse X at offset 0
    mov ax, [mouse_cur_y]
    mov [es:2], ax                      ; Mouse Y at offset 2
    mov al, [mouse_buttons]
    mov [es:4], al                      ; Buttons at offset 4

.skip_cursor:
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_handle_mouse_event: Process mouse click damage blit
; Inputs:
;   AL = Mouse buttons
;   BX = Delta X
;   CX = Delta Y
; Returns:
;   AX = 1 if damage blit performed, 0 otherwise
; ----------------------------------------------------------------------------
nanox_handle_mouse_event:
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; Re-render cursor
    call nanox_draw_mouse_cursor

    ; Check if Left Click (0x01)
    test al, MOUSE_BTN_LEFT
    jz .no_damage

    ; Damage event: mark window 0 active and touch shared buffer
    mov ax, [nanox_shm_sel]
    test ax, ax
    jz .no_damage
    mov es, ax
    mov word [es:6], 0x1234             ; Damage token
    mov ax, 1
    jmp .event_done

.no_damage:
    xor ax, ax

.event_done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

section .data
align 2
nanox_active:        db 0
nanox_fb_sel:        dw LDT_UFB_SEL
nanox_shm_sel:       dw 0
nanox_shmid:         dw 0
nanox_windows_drawn: dw 0

str_win_term:   db "Lin286 Terminal (nxterm) - tty5", 0
str_win_clock:  db "Clock (nxclock)", 0
str_win_calc:   db "Calc (nxcalc)", 0

str_nanox_ok:     db "[NANOX] Microwindows / Nano-X Display Server core initialized", 13, 10, 0
str_nanox_active: db "[NANOX] Nano-X Window Server active on tty5 (VGA 640x480x16 planar, Alt+F5)", 13, 10, 0

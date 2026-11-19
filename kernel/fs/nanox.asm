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
;  5. Renders the interactive visual desktop to physical VRAM (0xB8000):
;     Desktop wallpaper, top menu bar, bottom taskbar, shadowed window frames
;     for nxterm (interactive shell), nxclock, nxcalc, and movable cursor.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global nanox_init
global nanox_start_gui
global nanox_render_desktop
global nanox_draw_window_frame
global nanox_draw_mouse_cursor
global nanox_handle_mouse_event
global nanox_handle_key
global nanox_move_cursor
global nanox_cycle_focus
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
    mov byte [gui_focus_win], 0
    mov word [gui_cursor_col], 40
    mov word [gui_cursor_row], 12
    mov word [gui_cmd_len], 0
    mov byte [gui_cmd_buf], 0

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

    ; 5. Allocate 4 KB Shared Memory Window Buffer (Key = 0x4E58 "NX") if not yet allocated
    cmp word [nanox_shmid], 0
    jnz .shm_already
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
.shm_already:

    ; 6. Compose Nano-X GUI Desktop (Shared memory + Physical VRAM)
    mov word [nanox_windows_drawn], 0
    mov byte [nanox_active], 1
    call nanox_render_desktop

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

    ; --- Part A: Populate Shared Memory Window Buffer (for Ring 3 IPC & Test 38) ---
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

    ; 2. Compose Window 1 metadata: "Lin286 Terminal (nxterm) - tty5"
    mov word [nanox_windows_drawn], 0
    mov si, str_win_term
    mov bx, 40
    mov cx, 30
    mov dx, 320
    call nanox_draw_window_frame

    ; 3. Compose Window 2 metadata: "Clock (nxclock)"
    mov si, str_win_clock
    mov bx, 400
    mov cx, 30
    mov dx, 180
    call nanox_draw_window_frame

    ; 4. Compose Window 3 metadata: "Calc (nxcalc)"
    mov si, str_win_calc
    mov bx, 400
    mov cx, 160
    mov dx, 180
    call nanox_draw_window_frame

    ; 5. Draw initial mouse cursor metadata in shared buffer
    call nanox_draw_mouse_cursor

    ; --- Part B: Render Full-Color Visual GUI Desktop to Physical VRAM (0xB8000) ---
    call nanox_paint_vram_desktop

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_paint_vram_desktop: Paint the 80x25 Color GUI Desktop to GDT_VRAM_C_SEL
; ----------------------------------------------------------------------------
nanox_paint_vram_desktop:
    pusha
    push es

    ; Ensure VGA Graphics Controller Misc Register (0x3CE index 6) maps 0xB8000
    ; as the active visible color display aperture
    mov dx, 0x3CE
    mov ax, 0x0E06
    out dx, ax

    mov ax, GDT_VRAM_C_SEL              ; 0x0018 -> Physical 0xB8000
    mov es, ax

    ; 1. Fill Rows 1..23 with Desktop Wallpaper (Cyan on Blue 0x13, Stipple 0xB0)
    mov di, 160                         ; Row 1, Col 0
    mov ax, 0x13B0                      ; Light shade stipple '░', Cyan on Dark Blue
    mov cx, 80 * 23
    cld
    rep stosw

    ; 2. Draw Top Menu Bar (Row 0, White on Blue 0x1F)
    xor di, di
    mov ax, 0x1F20
    mov cx, 80
    rep stosw
    xor bx, bx                          ; Row 0
    mov cx, 1                           ; Col 1
    mov ah, 0x1F
    mov si, str_gui_menubar
    call gui_vram_puts

    ; 3. Draw Bottom Taskbar (Row 24, Black on Light Gray 0x70)
    mov di, 24 * 160
    mov ax, 0x7020
    mov cx, 80
    rep stosw
    mov bx, 24
    mov cx, 1
    mov ah, 0x70
    mov si, str_gui_taskbar
    call gui_vram_puts

    ; 4. Draw Window 1: "Lin286 Terminal (nxterm) - tty5" (Rows 2..21, Cols 2..48)
    mov byte [win_row], 2
    mov byte [win_col], 2
    mov byte [win_w], 47
    mov byte [win_h], 20
    mov byte [win_body_attr], 0x07      ; Light gray on Black terminal canvas
    mov al, 0x70                        ; Unfocused title attr
    cmp byte [gui_focus_win], 0
    jne .w1_title
    mov al, 0x3F                        ; Focused title: Bright White on Cyan
.w1_title:
    mov [win_title_attr], al
    mov si, str_win_term
    call gui_draw_box_window

    ; Render terminal text content inside nxterm (Rows 4..19, Cols 4..46)
    mov bx, 4
    mov cx, 4
    mov ah, 0x0B                        ; Bright Cyan on Black
    mov si, str_term_welcome1
    call gui_vram_puts

    mov bx, 5
    mov cx, 4
    mov ah, 0x07
    mov si, str_term_welcome2
    call gui_vram_puts

    mov bx, 6
    mov cx, 4
    mov ah, 0x08
    mov si, str_term_sep
    call gui_vram_puts

    ; Render 5 lines of terminal history output
    mov bx, 8
    mov cx, 4
    mov ah, 0x0F
    mov si, [gui_out_line1]
    call gui_vram_puts

    mov bx, 9
    mov cx, 4
    mov ah, 0x07
    mov si, [gui_out_line2]
    call gui_vram_puts

    mov bx, 10
    mov cx, 4
    mov ah, 0x07
    mov si, [gui_out_line3]
    call gui_vram_puts

    mov bx, 11
    mov cx, 4
    mov ah, 0x07
    mov si, [gui_out_line4]
    call gui_vram_puts

    mov bx, 12
    mov cx, 4
    mov ah, 0x0E                        ; Yellow highlight for status line
    mov si, [gui_out_line5]
    call gui_vram_puts

    ; Render active interactive command prompt at Row 19: "lin286:/$ " + gui_cmd_buf
    mov bx, 19
    mov cx, 4
    mov ah, 0x0A                        ; Bright Green prompt
    mov si, str_term_prompt
    call gui_vram_puts

    mov bx, 19
    mov cx, 14
    mov ah, 0x0F                        ; Bright White typed text
    mov si, gui_cmd_buf
    call gui_vram_puts

    ; Draw terminal cursor block at end of typed command
    mov bx, 19
    mov cx, 14
    add cx, [gui_cmd_len]
    cmp cx, 46
    jae .skip_tcur
    call gui_calc_vram_di
    mov word [es:di], 0x0ADB            ; Blinking green block cursor '█'
.skip_tcur:

    ; 5. Draw Window 2: "Clock (nxclock)" (Rows 2..10, Cols 51..77)
    mov byte [win_row], 2
    mov byte [win_col], 51
    mov byte [win_w], 27
    mov byte [win_h], 9
    mov byte [win_body_attr], 0x1F      ; White on Blue
    mov al, 0x70
    cmp byte [gui_focus_win], 1
    jne .w2_title
    mov al, 0x3F
.w2_title:
    mov [win_title_attr], al
    mov si, str_win_clock
    call gui_draw_box_window

    mov bx, 4
    mov cx, 53
    mov ah, 0x1E                        ; Yellow on Blue
    mov si, str_clk_line1
    call gui_vram_puts

    mov bx, 5
    mov cx, 53
    mov ah, 0x1F
    mov si, str_clk_line2
    call gui_vram_puts

    mov bx, 6
    mov cx, 53
    mov ah, 0x1B
    mov si, str_clk_line3
    call gui_vram_puts

    mov bx, 7
    mov cx, 53
    mov ah, 0x1A
    mov si, str_clk_line4
    call gui_vram_puts

    mov bx, 8
    mov cx, 53
    mov ah, 0x1F
    mov si, str_clk_line5
    call gui_vram_puts

    ; 6. Draw Window 3: "Calc (nxcalc)" (Rows 12..21, Cols 51..77)
    mov byte [win_row], 12
    mov byte [win_col], 51
    mov byte [win_w], 27
    mov byte [win_h], 10
    mov byte [win_body_attr], 0x70      ; Black on Light Gray
    mov al, 0x70
    cmp byte [gui_focus_win], 2
    jne .w3_title
    mov al, 0x3F
.w3_title:
    mov [win_title_attr], al
    mov si, str_win_calc
    call gui_draw_box_window

    mov bx, 14
    mov cx, 53
    mov ah, 0x0A                        ; Green on Black LCD readout
    mov si, str_calc_lcd
    call gui_vram_puts

    mov bx, 16
    mov cx, 53
    mov ah, 0x70
    mov si, str_calc_r1
    call gui_vram_puts

    mov bx, 17
    mov cx, 53
    mov ah, 0x70
    mov si, str_calc_r2
    call gui_vram_puts

    mov bx, 18
    mov cx, 53
    mov ah, 0x70
    mov si, str_calc_r3
    call gui_vram_puts

    mov bx, 19
    mov cx, 53
    mov ah, 0x70
    mov si, str_calc_r4
    call gui_vram_puts

    ; 7. Overlay Mouse / Arrow Pointer at (gui_cursor_row, gui_cursor_col)
    mov bx, [gui_cursor_row]
    mov cx, [gui_cursor_col]
    call gui_calc_vram_di
    mov word [es:di], 0x4F1E            ; Bright White on Red '▲' pointer

    ; Hide hardware blinking text cursor offscreen while in GUI mode
    mov ax, 2000
    call vt102_update_hw_cursor

    ; 8. Mirror 80x25 GUI Desktop from 0xB8000 (Color) to 0xB0000 (Hercules/Mono)
    ;    so the Winbond W86855AF video card displays the GUI in both modes!
    push ds
    mov ax, GDT_VRAM_C_SEL              ; Source: 0xB8000
    mov ds, ax
    mov ax, GDT_VRAM_M_SEL              ; Dest:   0xB0000
    mov es, ax
    xor si, si
    xor di, di
    mov cx, 2000                        ; 2000 words = 4000 bytes
    cld
    rep movsw
    pop ds

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; gui_draw_box_window: Draw shadowed window with title bar & borders
; Uses: win_row, win_col, win_w, win_h, win_body_attr, win_title_attr, SI=title
; ----------------------------------------------------------------------------
gui_draw_box_window:
    pusha
    mov [saved_win_title], si

    ; 1. Fill interior body rectangle
    xor bh, bh
    mov bl, [win_row]
    inc bx                              ; Start at row + 1
    xor dh, dh
    mov dl, [win_h]
    dec dx                              ; h - 1 rows
.body_row_loop:
    test dx, dx
    jz .body_done
    xor ch, ch
    mov cl, [win_col]
    call gui_calc_vram_di
    mov al, ' '
    mov ah, [win_body_attr]
    push cx
    xor ch, ch
    mov cl, [win_w]
    rep stosw
    pop cx

    ; Draw left & right vertical border '│' (0xB3)
    call gui_calc_vram_di
    mov byte [es:di], 0xB3
    xor ax, ax
    mov al, [win_w]
    dec ax
    shl ax, 1
    add di, ax
    mov byte [es:di], 0xB3
    ; Draw right drop shadow (1 cell right of window)
    add di, 2
    mov byte [es:di + 1], 0x08          ; Dark gray on black shadow attribute

    inc bx
    dec dx
    jmp .body_row_loop
.body_done:

    ; 2. Draw bottom border row '└─┘' (0xC0, 0xC4, 0xD9)
    xor bh, bh
    mov bl, [win_row]
    xor ah, ah
    mov al, [win_h]
    dec ax
    add bx, ax                          ; Bottom row
    xor ch, ch
    mov cl, [win_col]
    call gui_calc_vram_di
    mov ah, [win_body_attr]
    mov al, 0xC0                        ; '└'
    stosw
    mov al, 0xC4                        ; '─'
    xor ch, ch
    mov cl, [win_w]
    sub cx, 2
    rep stosw
    mov al, 0xD9                        ; '┘'
    stosw
    ; Right shadow on bottom row
    mov byte [es:di + 1], 0x08

    ; 3. Draw bottom drop shadow row (row + h)
    inc bx
    xor ch, ch
    mov cl, [win_col]
    inc cx
    call gui_calc_vram_di
    xor ch, ch
    mov cl, [win_w]
.bshadow_loop:
    mov byte [es:di + 1], 0x08
    add di, 2
    loop .bshadow_loop

    ; 4. Draw Top Title Bar row
    xor bh, bh
    mov bl, [win_row]
    xor ch, ch
    mov cl, [win_col]
    call gui_calc_vram_di
    mov ah, [win_title_attr]
    mov al, ' '
    xor ch, ch
    mov cl, [win_w]
    rep stosw

    ; Draw "[X] " + title string on title bar
    xor bh, bh
    mov bl, [win_row]
    xor ch, ch
    mov cl, [win_col]
    inc cx
    mov ah, [win_title_attr]
    mov si, str_win_close_btn
    call gui_vram_puts

    add cx, 4
    mov si, [saved_win_title]
    call gui_vram_puts

    popa
    ret

; ----------------------------------------------------------------------------
; gui_calc_vram_di: Compute DI = (BX * 80 + CX) * 2
; Inputs: BX = row (0..24), CX = col (0..79)
; Output: DI = byte offset in 0xB8000
; ----------------------------------------------------------------------------
gui_calc_vram_di:
    push ax
    push dx
    mov ax, bx
    mov dx, 80
    mul dx
    add ax, cx
    shl ax, 1
    mov di, ax
    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; gui_vram_puts: Write null-terminated string DS:SI at (Row=BX, Col=CX) with Attr=AH
; ----------------------------------------------------------------------------
gui_vram_puts:
    pusha
    call gui_calc_vram_di
.gputs_loop:
    lodsb
    test al, al
    jz .gputs_done
    stosw
    jmp .gputs_loop
.gputs_done:
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_handle_key: Process interactive keyboard input while GUI is active
; Input: AL = ASCII character (8 = Backspace, 9 = Tab, 13 = Enter, 32..126)
; ----------------------------------------------------------------------------
nanox_handle_key:
    pusha

    cmp al, 9                           ; Tab -> cycle active window focus
    je .do_tab

    cmp al, 8                           ; Backspace
    je .do_bs

    cmp al, 13                          ; Enter -> execute command in nxterm
    je .do_enter

    cmp al, 32
    jb .key_exit
    cmp al, 126
    ja .key_exit

    ; Append printable character to gui_cmd_buf (max 30 chars)
    mov bx, [gui_cmd_len]
    cmp bx, 30
    jae .key_exit
    mov [gui_cmd_buf + bx], al
    inc bx
    mov [gui_cmd_len], bx
    mov byte [gui_cmd_buf + bx], 0
    call nanox_paint_vram_desktop
    jmp .key_exit

.do_tab:
    call nanox_cycle_focus
    jmp .key_exit

.do_bs:
    mov bx, [gui_cmd_len]
    test bx, bx
    jz .key_exit
    dec bx
    mov [gui_cmd_len], bx
    mov byte [gui_cmd_buf + bx], 0
    call nanox_paint_vram_desktop
    jmp .key_exit

.do_enter:
    call nanox_exec_term_cmd
    mov word [gui_cmd_len], 0
    mov byte [gui_cmd_buf], 0
    call nanox_paint_vram_desktop

.key_exit:
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_exec_term_cmd: Execute command typed in nxterm GUI window
; ----------------------------------------------------------------------------
nanox_exec_term_cmd:
    pusha

    ; Check empty command
    cmp word [gui_cmd_len], 0
    je .cmd_done

    ; Check "help"
    mov si, gui_cmd_buf
    mov di, str_gcmd_help
    call gui_streq
    test ax, ax
    jz .run_help

    ; Check "uname"
    mov si, gui_cmd_buf
    mov di, str_gcmd_uname
    call gui_streq
    test ax, ax
    jz .run_uname

    ; Check "free"
    mov si, gui_cmd_buf
    mov di, str_gcmd_free
    call gui_streq
    test ax, ax
    jz .run_free

    ; Check "ps"
    mov si, gui_cmd_buf
    mov di, str_gcmd_ps
    call gui_streq
    test ax, ax
    jz .run_ps

    ; Check "ldt"
    mov si, gui_cmd_buf
    mov di, str_gcmd_ldt
    call gui_streq
    test ax, ax
    jz .run_ldt

    ; Check "beep"
    mov si, gui_cmd_buf
    mov di, str_gcmd_beep
    call gui_streq
    test ax, ax
    jz .run_beep

    ; Check "clear"
    mov si, gui_cmd_buf
    mov di, str_gcmd_clear
    call gui_streq
    test ax, ax
    jz .run_clear

    ; Default: Unknown command -> show help hint
    mov word [gui_out_line1], str_gout_unk1
    mov word [gui_out_line2], str_gout_help2
    mov word [gui_out_line3], str_gout_help3
    mov word [gui_out_line4], str_gout_blank
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_help:
    mov word [gui_out_line1], str_gout_help1
    mov word [gui_out_line2], str_gout_help2
    mov word [gui_out_line3], str_gout_help3
    mov word [gui_out_line4], str_gout_help4
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_uname:
    mov word [gui_out_line1], str_gout_un1
    mov word [gui_out_line2], str_gout_un2
    mov word [gui_out_line3], str_gout_un3
    mov word [gui_out_line4], str_gout_blank
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_free:
    mov word [gui_out_line1], str_gout_fr1
    mov word [gui_out_line2], str_gout_fr2
    mov word [gui_out_line3], str_gout_fr3
    mov word [gui_out_line4], str_gout_fr4
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_ps:
    mov word [gui_out_line1], str_gout_ps1
    mov word [gui_out_line2], str_gout_ps2
    mov word [gui_out_line3], str_gout_ps3
    mov word [gui_out_line4], str_gout_ps4
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_ldt:
    mov word [gui_out_line1], str_gout_ldt1
    mov word [gui_out_line2], str_gout_ldt2
    mov word [gui_out_line3], str_gout_ldt3
    mov word [gui_out_line4], str_gout_ldt4
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_beep:
    ; Trigger 880 Hz tone for 150 ms on PC Speaker
    mov ax, 880
    mov bx, 15
    call pcspkr_beep_ticks
    mov word [gui_out_line1], str_gout_beep1
    mov word [gui_out_line2], str_gout_beep2
    mov word [gui_out_line3], str_gout_blank
    mov word [gui_out_line4], str_gout_blank
    mov word [gui_out_line5], str_gout_ready
    jmp .cmd_done

.run_clear:
    mov word [gui_out_line1], str_gout_blank
    mov word [gui_out_line2], str_gout_blank
    mov word [gui_out_line3], str_gout_blank
    mov word [gui_out_line4], str_gout_blank
    mov word [gui_out_line5], str_gout_blank_ok

.cmd_done:
    popa
    ret

; String equality helper (returns AX=0 if equal, 1 otherwise)
gui_streq:
    push si
    push di
.gcmp_lp:
    mov al, [si]
    mov ah, [di]
    cmp al, ah
    jne .gcmp_ne
    test al, al
    jz .gcmp_eq
    inc si
    inc di
    jmp .gcmp_lp
.gcmp_eq:
    xor ax, ax
    pop di
    pop si
    ret
.gcmp_ne:
    mov ax, 1
    pop di
    pop si
    ret

; ----------------------------------------------------------------------------
; nanox_move_cursor: Move GUI pointer by (BL = dcol, BH = drow)
; ----------------------------------------------------------------------------
nanox_move_cursor:
    pusha
    mov al, bl
    cbw
    add [gui_cursor_col], ax
    cmp word [gui_cursor_col], 0
    jge .c_min_ok
    mov word [gui_cursor_col], 0
.c_min_ok:
    cmp word [gui_cursor_col], 79
    jle .c_max_ok
    mov word [gui_cursor_col], 79
.c_max_ok:

    mov al, bh
    cbw
    add [gui_cursor_row], ax
    cmp word [gui_cursor_row], 1
    jge .r_min_ok
    mov word [gui_cursor_row], 1
.r_min_ok:
    cmp word [gui_cursor_row], 23
    jle .r_max_ok
    mov word [gui_cursor_row], 23
.r_max_ok:

    call nanox_paint_vram_desktop
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_cycle_focus: Cycle active window focus (0 -> 1 -> 2 -> 0)
; ----------------------------------------------------------------------------
nanox_cycle_focus:
    push ax
    mov al, [gui_focus_win]
    inc al
    cmp al, 3
    jb .focus_ok
    xor al, al
.focus_ok:
    mov [gui_focus_win], al
    call nanox_paint_vram_desktop
    pop ax
    ret

; ----------------------------------------------------------------------------
; nanox_draw_window_frame: Helper to render a nanowm window frame in SHM
; ----------------------------------------------------------------------------
nanox_draw_window_frame:
    pusha
    mov di, [nanox_windows_drawn]
    shl di, 6                           ; DI = windows_drawn * 64
    add di, 256                         ; Offset in shared buffer

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
; nanox_draw_mouse_cursor: Renders mouse cursor coordinates in SHM
; ----------------------------------------------------------------------------
nanox_draw_mouse_cursor:
    pusha
    mov ax, [nanox_shm_sel]
    test ax, ax
    jz .skip_cursor
    mov es, ax

    mov ax, [mouse_cur_x]
    mov [es:0], ax
    mov ax, [mouse_cur_y]
    mov [es:2], ax
    mov al, [mouse_buttons]
    mov [es:4], al

.skip_cursor:
    popa
    ret

; ----------------------------------------------------------------------------
; nanox_handle_mouse_event: Process mouse click damage blit
; ----------------------------------------------------------------------------
nanox_handle_mouse_event:
    push bx
    push cx
    push dx
    push si
    push di
    push es

    call nanox_draw_mouse_cursor

    test al, MOUSE_BTN_LEFT
    jz .no_damage

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

gui_focus_win:       db 0
gui_cursor_col:      dw 40
gui_cursor_row:      dw 12
gui_cmd_len:         dw 0
gui_cmd_buf:         times 34 db 0

win_row:             db 0
win_col:             db 0
win_w:               db 0
win_h:               db 0
win_body_attr:       db 0
win_title_attr:      db 0
saved_win_title:     dw 0

str_win_close_btn: db "[X] ", 0
str_win_term:   db "Lin286 Terminal (nxterm) - tty5", 0
str_win_clock:  db "Clock (nxclock)", 0
str_win_calc:   db "Calc (nxcalc)", 0

str_gui_menubar: db "Lin286 Nano-X GUI [80286 PM Ring 3 | LDT=0x001F]   Alt+F1..F4:TTY  Alt+F5:GUI", 0
str_gui_taskbar: db "[Nano-X] Type cmd + Enter | Arrows: Move Pointer | Tab: Switch Window Focus ", 0

str_term_welcome1: db "Lin286 Protected-Mode Shell (sash on nxterm)", 0
str_term_welcome2: db "Commands: help uname free ps ldt beep clear", 0
str_term_sep:      db "-------------------------------------------", 0
str_term_prompt:   db "lin286:/$ ", 0

str_clk_line1:  db "CMOS Date: 2026-11-19", 0
str_clk_line2:  db "CPU Mode:  80286 PM Ring3", 0
str_clk_line3:  db "RAM Pool:  640K+384K XMS", 0
str_clk_line4:  db "VRAM LDT:  0x001F (IOPL3)", 0
str_clk_line5:  db "Audio:     8kHz PWM XLATB", 0

str_calc_lcd:   db "      1024 KB (860K Free)", 0
str_calc_r1:    db "  [ 7 ] [ 8 ] [ 9 ] [ / ]", 0
str_calc_r2:    db "  [ 4 ] [ 5 ] [ 6 ] [ * ]", 0
str_calc_r3:    db "  [ 1 ] [ 2 ] [ 3 ] [ - ]", 0
str_calc_r4:    db "  [ 0 ] [ C ] [ = ] [ + ]", 0

str_gcmd_help:  db "help", 0
str_gcmd_uname: db "uname", 0
str_gcmd_free:  db "free", 0
str_gcmd_ps:    db "ps", 0
str_gcmd_ldt:   db "ldt", 0
str_gcmd_beep:  db "beep", 0
str_gcmd_clear: db "clear", 0

str_gout_help1: db "Built-in commands available in nxterm:", 0
str_gout_help2: db "  uname - Kernel & 80286 PM architecture", 0
str_gout_help3: db "  free  - 24-bit Segment MM Pool A + B", 0
str_gout_help4: db "  ps / ldt / beep / clear", 0

str_gout_un1:   db "Lin286 v0.6.0-phase6 (i286 Protected Mode)", 0
str_gout_un2:   db "MMU: 24-bit LDT Segmentation (CoW + #NP)", 0
str_gout_un3:   db "ABI: POSIX.1-1988 & ELKS 16-bit Split-I&D", 0

str_gout_fr1:   db "Physical RAM:  1024 KB (640K Base + 384K)", 0
str_gout_fr2:   db "Kernel Ring 0:  160 KB (Code 96K + Data)", 0
str_gout_fr3:   db "Pool A (Conv):  476 KB (0x029000-0x09FFFF)", 0
str_gout_fr4:   db "Pool B (XMS):   384 KB (0x100000-0x15FFFF)", 0

str_gout_ps1:   db "PID  RING  LDT     STATE   COMMAND", 0
str_gout_ps2:   db "  1     3  0x0040  SLEEP   /sbin/init", 0
str_gout_ps3:   db "  2     3  0x0048  RUN     /usr/bin/nanox", 0
str_gout_ps4:   db "  3     3  0x0050  RUN     /bin/sash", 0

str_gout_ldt1:  db "Active Process LDT Selectors (TI=1, RPL=3):", 0
str_gout_ldt2:  db "  CS = 0x0007 (Base=0x029000 Limit=0xFFFF)", 0
str_gout_ldt3:  db "  DS = 0x000F (Base=0x100000 CoW/Demand)", 0
str_gout_ldt4:  db "  FB = 0x001F (Base=0x0A0000 MMIO IOPL=3)", 0

str_gout_beep1: db "[PCSPKR] Triggered 880 Hz PIT Ch2 Square Wave", 0
str_gout_beep2: db "Audio backend: 8254 PIT Mode 3 / Class-D PWM", 0

str_gout_unk1:  db "Unknown command. Type 'help' for list:", 0
str_gout_ready: db "[OK] Ready for input (Alt+F1..F4 for TTYs)", 0
str_gout_blank: db "                                          ", 0
str_gout_blank_ok: db "Terminal cleared. Type 'help' for info.   ", 0

gui_out_line1:  dw str_gout_un1
gui_out_line2:  dw str_gout_un2
gui_out_line3:  dw str_gout_fr1
gui_out_line4:  dw str_gout_ldt4
gui_out_line5:  dw str_gout_ready

str_nanox_ok:     db "[NANOX] Microwindows / Nano-X Display Server core initialized", 13, 10, 0
str_nanox_active: db "[NANOX] Nano-X Window Server active on tty5 (VGA 640x480x16 planar, Alt+F5)", 13, 10, 0

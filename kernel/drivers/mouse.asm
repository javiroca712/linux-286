CPU 286
BITS 16

; ============================================================================
; Lin286 RS-232 Serial Mouse Driver (/dev/mouse)
;
; Implements Microsoft 2/3-Button Serial & Mouse Systems packet decoding,
; event normalization, and non-blocking event queueing for Ring 3 Display Servers.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global mouse_init
global mouse_feed_byte
global mouse_read
global mouse_select_check
global mouse_get_event_count
global mouse_cur_x
global mouse_cur_y
global mouse_buttons

section .text

; ----------------------------------------------------------------------------
; mouse_init: Initialize mouse state and event queue
; ----------------------------------------------------------------------------
mouse_init:
    push si
    mov word [mouse_head], 0
    mov word [mouse_tail], 0
    mov word [mouse_count], 0
    mov byte [mouse_proto_state], 0
    mov word [mouse_cur_x], 320
    mov word [mouse_cur_y], 240
    mov byte [mouse_buttons], 0

    mov si, str_mouse_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; mouse_feed_byte: Feed raw byte from UART into packet decoder
; Input:
;   AL = Raw serial byte
; ----------------------------------------------------------------------------
mouse_feed_byte:
    push bx
    push cx
    push dx
    push si
    push di

    ; Microsoft Serial Mouse Protocol:
    ; Byte 1 has bit 6 (0x40) set: 0 1 L R Y7 Y6 X7 X6
    test al, 0x40
    jnz .is_byte1

    cmp byte [mouse_proto_state], 1
    je .is_byte2

    cmp byte [mouse_proto_state], 2
    je .is_byte3

    ; Out of sync
    mov byte [mouse_proto_state], 0
    jmp .feed_done

.is_byte1:
    mov [mouse_raw_b1], al
    mov byte [mouse_proto_state], 1
    jmp .feed_done

.is_byte2:
    and al, 0x3F
    mov [mouse_raw_b2], al
    mov byte [mouse_proto_state], 2
    jmp .feed_done

.is_byte3:
    and al, 0x3F
    mov [mouse_raw_b3], al
    mov byte [mouse_proto_state], 0     ; Packet complete!

    ; --- Decode Packet into struct mouse286_event ---
    ; 1. Buttons
    xor bl, bl
    mov al, [mouse_raw_b1]
    test al, 0x20                       ; Left button
    jz .chk_right
    or bl, MOUSE_BTN_LEFT
.chk_right:
    test al, 0x10                       ; Right button
    jz .btns_done
    or bl, MOUSE_BTN_RIGHT
.btns_done:
    mov [mouse_buttons], bl

    ; 2. Relative X motion: ((b1 & 0x03) << 6) | (b2 & 0x3F)
    mov al, [mouse_raw_b1]
    and al, 0x03
    shl al, 6
    or al, [mouse_raw_b2]
    ; AL is 8-bit signed delta X
    mov cl, al                          ; CL = dx

    ; 3. Relative Y motion: ((b1 & 0x0C) << 4) | (b3 & 0x3F)
    mov al, [mouse_raw_b1]
    and al, 0x0C
    shl al, 4
    or al, [mouse_raw_b3]
    ; AL is 8-bit signed delta Y
    mov ch, al                          ; CH = dy

    ; Update cursor position tracking
    ; X += dx (sign extend CL)
    mov al, cl
    cbw
    add [mouse_cur_x], ax
    ; Clamp X to 0..639
    cmp word [mouse_cur_x], 0
    jge .x_not_neg
    mov word [mouse_cur_x], 0
.x_not_neg:
    cmp word [mouse_cur_x], 639
    jle .x_not_max
    mov word [mouse_cur_x], 639
.x_not_max:

    ; Y += dy (sign extend CH)
    mov al, ch
    cbw
    add [mouse_cur_y], ax
    ; Clamp Y to 0..479
    cmp word [mouse_cur_y], 0
    jge .y_not_neg
    mov word [mouse_cur_y], 0
.y_not_neg:
    cmp word [mouse_cur_y], 479
    jle .y_not_max
    mov word [mouse_cur_y], 479
.y_not_max:

    ; 4. Enqueue into mouse_ring if space available
    cmp word [mouse_count], 32
    jae .feed_done                      ; Drop if queue full

    mov di, [mouse_head]
    mov byte [mouse_ring + di + MEV_DX], cl
    mov byte [mouse_ring + di + MEV_DY], ch
    mov byte [mouse_ring + di + MEV_BUTTONS], bl
    mov byte [mouse_ring + di + MEV_RESERVED], 0

    add di, 4
    and di, 0x7F                        ; 32 * 4 = 128 bytes (mask 0x7F)
    mov [mouse_head], di
    inc word [mouse_count]

.feed_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; mouse_read: Read struct mouse286_event entries from mouse queue
; Inputs:
;   DI = Destination struct vfs_inode pointer (or ignored)
;   SI = Destination buffer offset in caller's DS [bp + 14]
;   CX = Requested byte count
; Returns:
;   AX = Number of bytes read
; ----------------------------------------------------------------------------
mouse_read:
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; Setup ES = caller DS [bp + 14]
    mov ax, [bp + 14]
    test ax, ax
    jnz .has_caller_ds
    mov ax, ds
.has_caller_ds:
    mov es, ax
    mov di, si                          ; ES:DI = destination buffer

    xor dx, dx                          ; DX = bytes read

.read_loop:
    cmp cx, 4
    jb .read_exit                       ; Need at least 4 bytes for struct mouse286_event

    cmp word [mouse_count], 0
    je .read_exit                       ; Queue empty

    ; Copy 4 bytes from mouse_ring[mouse_tail]
    mov si, [mouse_tail]
    add si, mouse_ring                  ; DS:SI = queue event
    mov ax, [si + 0]
    mov [es:di + 0], ax
    mov ax, [si + 2]
    mov [es:di + 2], ax

    add di, 4
    add dx, 4
    sub cx, 4

    ; Advance mouse_tail
    mov ax, [mouse_tail]
    add ax, 4
    and ax, 0x7F
    mov [mouse_tail], ax
    dec word [mouse_count]
    jmp .read_loop

.read_exit:
    mov ax, dx                          ; Return bytes read
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; mouse_select_check: Poll whether events are ready
; Returns:
;   AX = 1 if events available, 0 if empty
; ----------------------------------------------------------------------------
mouse_select_check:
    cmp word [mouse_count], 0
    je .not_ready
    mov ax, 1
    ret
.not_ready:
    xor ax, ax
    ret

; ----------------------------------------------------------------------------
; mouse_get_event_count: Return current queued events
; ----------------------------------------------------------------------------
mouse_get_event_count:
    mov ax, [mouse_count]
    ret

section .data
align 2
mouse_head:         dw 0
mouse_tail:         dw 0
mouse_count:        dw 0
mouse_proto_state:  db 0
mouse_raw_b1:       db 0
mouse_raw_b2:       db 0
mouse_raw_b3:       db 0
mouse_cur_x:        dw 320
mouse_cur_y:        dw 240
mouse_buttons:      db 0

str_mouse_ok: db "[MOUSE] RS-232 Serial Mouse driver (/dev/mouse) initialized", 13, 10, 0

section .bss
align 4
; 32 events * 4 bytes = 128 bytes
mouse_ring: resb 128

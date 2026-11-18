CPU 286
BITS 16

; ============================================================================
; Lin286 Circular FIFO Pipe Driver
;
; Implements POSIX in-memory unidirectional pipes with circular buffer,
; reader/writer tracking, EOF on writer closure, and SIGPIPE on broken pipe.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global pipe_init
global pipe_alloc
global pipe_read
global pipe_write
global pipe_close_reader
global pipe_close_writer
global pipe_select_check

section .text

; ----------------------------------------------------------------------------
; pipe_init: Initialize pipe pools
; ----------------------------------------------------------------------------
pipe_init:
    push di
    push cx
    push ax

    mov di, pipe_pool
    mov cx, (MAX_PIPES * PIPE_STRUCT_SIZE) / 2
    xor ax, ax
    cld
    rep stosw

    mov si, str_pipe_ok
    call uart_puts

    pop ax
    pop cx
    pop di
    ret

; ----------------------------------------------------------------------------
; pipe_alloc: Allocate a free pipe structure
; Returns:
;   AX = Pipe index (0..MAX_PIPES-1), or -1 on ENOMEM
; ----------------------------------------------------------------------------
pipe_alloc:
    push bx
    push cx
    push di

    mov cx, MAX_PIPES
    mov di, pipe_pool
    xor bx, bx                          ; Pipe index = 0

.scan_loop:
    cmp word [di + PIPE_STRUCT_IN_USE], 0
    je .found_slot
    add di, PIPE_STRUCT_SIZE
    inc bx
    loop .scan_loop

    mov ax, -ENOMEM
    jmp .alloc_done

.found_slot:
    ; Initialize pipe structure
    mov word [di + PIPE_STRUCT_IN_USE], 1
    mov word [di + PIPE_STRUCT_HEAD], 0
    mov word [di + PIPE_STRUCT_TAIL], 0
    mov word [di + PIPE_STRUCT_COUNT], 0
    mov word [di + PIPE_STRUCT_READERS], 1
    mov word [di + PIPE_STRUCT_WRITERS], 1

    mov ax, bx                          ; Return pipe index

.alloc_done:
    pop di
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; pipe_get_ptr: Helper to get pointer to struct pipe_struct in DS
; Input:  BX = Pipe ID (0..MAX_PIPES-1)
; Output: DI = Pointer to pipe_struct
; ----------------------------------------------------------------------------
pipe_get_ptr:
    push ax
    push dx
    mov ax, PIPE_STRUCT_SIZE            ; 524
    mul bx                              ; DX:AX = 524 * BX
    add ax, pipe_pool
    mov di, ax
    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; pipe_read: Read bytes from pipe
; Inputs:
;   BX = Pipe index (0..MAX_PIPES-1)
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count requested
; Returns:
;   AX = Bytes read (0 = EOF), or negative error code
; ----------------------------------------------------------------------------
pipe_read:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    cmp bx, MAX_PIPES
    jae .bad_pipe

    call pipe_get_ptr                   ; DI = &pipe_pool[bx]
    mov bp, di                          ; BP = pipe pointer

    test cx, cx
    jz .read_zero

    ; If buffer is empty:
    mov dx, [bp + PIPE_STRUCT_COUNT]
    test dx, dx
    jnz .has_data

    ; Buffer is empty: check if any writers remain open
    cmp word [bp + PIPE_STRUCT_WRITERS], 0
    je .eof                             ; No writers left -> EOF (return 0)

    ; In non-blocking/current simple model, return 0 when empty
    xor ax, ax
    jmp .read_exit

.eof:
    xor ax, ax
    jmp .read_exit

.has_data:
    ; Limit bytes to min(CX, count)
    cmp cx, dx
    jbe .count_ok
    mov cx, dx
.count_ok:
    mov [saved_pipe_xfer], cx           ; Total bytes we will read

    mov dx, [bp + PIPE_STRUCT_TAIL]     ; DX = tail index

.copy_loop:
    ; Read byte from pipe_buf[DX]
    lea di, [bp + PIPE_STRUCT_BUF]
    add di, dx
    mov al, [di]
    mov [si], al
    inc si

    ; Advance tail circularly
    inc dx
    cmp dx, PIPE_BUF_SIZE
    jb .tail_no_wrap
    xor dx, dx
.tail_no_wrap:
    loop .copy_loop

    ; Update pipe tail and decrement count
    mov [bp + PIPE_STRUCT_TAIL], dx
    mov ax, [saved_pipe_xfer]
    sub [bp + PIPE_STRUCT_COUNT], ax
    jmp .read_exit

.read_zero:
    xor ax, ax
    jmp .read_exit

.bad_pipe:
    mov ax, -EBADF

.read_exit:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; pipe_write: Write bytes to pipe
; Inputs:
;   BX = Pipe index (0..MAX_PIPES-1)
;   SI = Source buffer in Kernel Data (DS)
;   CX = Byte count to write
; Returns:
;   AX = Bytes written, or negative error code (-EPIPE)
; ----------------------------------------------------------------------------
pipe_write:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    cmp bx, MAX_PIPES
    jae .bad_pipe_w

    call pipe_get_ptr                   ; DI = &pipe_pool[bx]
    mov bp, di

    ; If no readers remain open, send SIGPIPE and return -EPIPE
    cmp word [bp + PIPE_STRUCT_READERS], 0
    jne .check_write_count

    ; Send SIGPIPE to current task
    mov al, [current_task]
    call task_get_ptr                   ; DI = task_struct
    mov ax, (1 << SIGPIPE)
    or [di + TS_SIG_PENDING], ax

    mov ax, -EPIPE
    jmp .write_exit

.check_write_count:
    test cx, cx
    jz .write_zero

    ; Available space = PIPE_BUF_SIZE - count
    mov dx, PIPE_BUF_SIZE
    sub dx, [bp + PIPE_STRUCT_COUNT]
    jz .write_zero                      ; Pipe buffer full

    ; Limit CX to available space
    cmp cx, dx
    jbe .wspace_ok
    mov cx, dx
.wspace_ok:
    mov [saved_pipe_xfer], cx

    mov dx, [bp + PIPE_STRUCT_HEAD]     ; DX = head index

.wcopy_loop:
    mov al, [si]
    inc si
    lea di, [bp + PIPE_STRUCT_BUF]
    add di, dx
    mov [di], al

    ; Advance head circularly
    inc dx
    cmp dx, PIPE_BUF_SIZE
    jb .head_no_wrap
    xor dx, dx
.head_no_wrap:
    loop .wcopy_loop

    ; Update pipe head and increment count
    mov [bp + PIPE_STRUCT_HEAD], dx
    mov ax, [saved_pipe_xfer]
    add [bp + PIPE_STRUCT_COUNT], ax
    jmp .write_exit

.write_zero:
    xor ax, ax
    jmp .write_exit

.bad_pipe_w:
    mov ax, -EBADF

.write_exit:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; pipe_close_reader: Decrement reader count on pipe
; Input: BX = Pipe ID
; ----------------------------------------------------------------------------
pipe_close_reader:
    push bx
    push di
    cmp bx, MAX_PIPES
    jae .pcr_done
    call pipe_get_ptr
    cmp word [di + PIPE_STRUCT_READERS], 0
    je .pcr_done
    dec word [di + PIPE_STRUCT_READERS]
    ; If both readers and writers are 0, free pipe
    mov ax, [di + PIPE_STRUCT_READERS]
    or ax, [di + PIPE_STRUCT_WRITERS]
    jnz .pcr_done
    mov word [di + PIPE_STRUCT_IN_USE], 0
.pcr_done:
    pop di
    pop bx
    ret

; ----------------------------------------------------------------------------
; pipe_close_writer: Decrement writer count on pipe
; Input: BX = Pipe ID
; ----------------------------------------------------------------------------
pipe_close_writer:
    push bx
    push di
    cmp bx, MAX_PIPES
    jae .pcw_done
    call pipe_get_ptr
    cmp word [di + PIPE_STRUCT_WRITERS], 0
    je .pcw_done
    dec word [di + PIPE_STRUCT_WRITERS]
    ; If both readers and writers are 0, free pipe
    mov ax, [di + PIPE_STRUCT_READERS]
    or ax, [di + PIPE_STRUCT_WRITERS]
    jnz .pcw_done
    mov word [di + PIPE_STRUCT_IN_USE], 0
.pcw_done:
    pop di
    pop bx
    ret

; ----------------------------------------------------------------------------
; pipe_select_check: Check if pipe is ready for read or write
; Inputs:
;   BX = Pipe index
;   AX = 0 for read, 1 for write
; Returns:
;   AX = 1 if ready, 0 if not ready
; ----------------------------------------------------------------------------
pipe_select_check:
    push bx
    push di
    cmp bx, MAX_PIPES
    jae .sel_not_ready

    call pipe_get_ptr
    test ax, ax
    jnz .check_sel_write

    ; Read readiness: count > 0 || writers == 0
    cmp word [di + PIPE_STRUCT_COUNT], 0
    ja .sel_ready
    cmp word [di + PIPE_STRUCT_WRITERS], 0
    je .sel_ready
    jmp .sel_not_ready

.check_sel_write:
    ; Write readiness: space available (count < 512) || readers == 0
    cmp word [di + PIPE_STRUCT_COUNT], PIPE_BUF_SIZE
    jb .sel_ready
    cmp word [di + PIPE_STRUCT_READERS], 0
    je .sel_ready

.sel_not_ready:
    xor ax, ax
    jmp .sel_done

.sel_ready:
    mov ax, 1

.sel_done:
    pop di
    pop bx
    ret

section .data
str_pipe_ok:    db "[PIPE] FIFO in-memory pipe subsystem initialized", 13, 10, 0
saved_pipe_xfer:dw 0

section .bss
alignb 4
pipe_pool:      resb (MAX_PIPES * PIPE_STRUCT_SIZE)

section .text

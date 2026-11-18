CPU 286
BITS 16

; ============================================================================
; Lin286 POSIX termios Terminal Driver & Line Discipline
;
; Manages line editing (ERASE backspace \b, KILL ^U, EOF ^D, ICRNL, ONLCR, ISIG ^C)
; for Serial (ttyS0 = tty 0) and 4 Virtual Consoles (tty1..4 = tty 1..4).
; Implements TCGETS, TCSETS, and TIOCGWINSZ ioctl handling.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global tty_init
global tty_input_char
global tty_read
global tty_write
global tty_output_char
global tty_ioctl
global tty_select_check
global tty_get_termios
global tty_set_termios

; struct tty_queue offsets (8 bytes)
TQ_HEAD         equ 0   ; db
TQ_TAIL         equ 1   ; db
TQ_LINE_START   equ 2   ; db
TQ_PAD          equ 3   ; db
TQ_COUNT        equ 4   ; dw
TQ_CANON_COUNT  equ 6   ; dw
TQ_SIZE         equ 8

section .text

; ----------------------------------------------------------------------------
; tty_init: Initialize termios structures and queues for all 5 TTYs
; ----------------------------------------------------------------------------
tty_init:
    pusha
    push es

    mov ax, ds
    mov es, ax

    mov cx, MAX_TTYS
    xor bx, bx                          ; BX = tty index (0..4)

.init_loop:
    ; 1. Clear input queue structure
    call get_tq_ptr                     ; SI = &tty_queues[bx * 8]
    mov byte [si + TQ_HEAD], 0
    mov byte [si + TQ_TAIL], 0
    mov byte [si + TQ_LINE_START], 0
    mov byte [si + TQ_PAD], 0
    mov word [si + TQ_COUNT], 0
    mov word [si + TQ_CANON_COUNT], 0

    ; 2. Populate struct termios (26 bytes)
    push bx
    push cx
    call get_termios_ptr                ; DI = termios ptr
    mov word [di + TERMIOS_IFLAG], TERMIOS_ICRNL
    mov word [di + TERMIOS_OFLAG], TERMIOS_ONLCR
    mov word [di + TERMIOS_CFLAG], 0
    mov word [di + TERMIOS_LFLAG], (TERMIOS_ISIG | TERMIOS_ICANON | TERMIOS_ECHO | TERMIOS_ECHOE | TERMIOS_ECHOK)
    mov byte [di + TERMIOS_LINE], 0

    ; Control characters (c_cc)
    mov byte [di + TERMIOS_CC + 0], 0x03 ; VINTR (^C)
    mov byte [di + TERMIOS_CC + 1], 0x1C ; VQUIT (^\)
    mov byte [di + TERMIOS_CC + 2], 0x08 ; VERASE (\b)
    mov byte [di + TERMIOS_CC + 3], 0x15 ; VKILL (^U)
    mov byte [di + TERMIOS_CC + 4], 0x04 ; VEOF (^D)
    mov byte [di + TERMIOS_CC + 5], 0    ; VTIME
    mov byte [di + TERMIOS_CC + 6], 1    ; VMIN
    mov byte [di + TERMIOS_CC + 7], 0
    mov byte [di + TERMIOS_CC + 8], 0x11 ; VSTART (^Q)
    mov byte [di + TERMIOS_CC + 9], 0x13 ; VSTOP (^S)
    mov byte [di + TERMIOS_CC + 10], 0x1A ; VSUSP (^Z)
    mov byte [di + TERMIOS_CC + 11], 0x0A ; VEOL (\n)
    mov byte [di + TERMIOS_CC + 12], 0
    mov byte [di + TERMIOS_CC + 13], 0
    mov byte [di + TERMIOS_CC + 14], 0
    mov byte [di + TERMIOS_CC + 15], 0
    pop cx
    pop bx

    inc bx
    loop .init_loop

    mov si, str_tty_ok
    call uart_puts

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; get_tq_ptr: Helper to get pointer to struct tty_queue for TTY BX
; Input:  BX = TTY index (0..4)
; Output: SI = Pointer to struct tty_queue in DS
; ----------------------------------------------------------------------------
get_tq_ptr:
    mov si, bx
    shl si, 3                          ; SI = BX * 8
    add si, tty_queues
    ret

; ----------------------------------------------------------------------------
; get_termios_ptr: Helper to get pointer to struct termios for TTY BX
; Input:  BX = TTY index (0..4)
; Output: DI = Pointer to struct termios in DS
; ----------------------------------------------------------------------------
get_termios_ptr:
    push ax
    push dx
    mov al, 26
    mul bl                             ; AX = 26 * BL (since BL < 5, AX < 130)
    add ax, tty_termios_table
    mov di, ax
    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------------
; get_tty_buf_ptr: Helper to get base pointer of input ring buffer for TTY BX
; Input:  BX = TTY index (0..4)
; Output: DI = Pointer to 256-byte buffer in DS
; ----------------------------------------------------------------------------
get_tty_buf_ptr:
    mov di, bx
    shl di, 8                          ; DI = BX * 256
    add di, tty_input_buffers
    ret

; ----------------------------------------------------------------------------
; tty_output_char: Send character to TTY output stream with ONLCR translation
; Inputs:
;   BX = TTY index (0 = serial ttyS0, 1..4 = virtual consoles tty1..4)
;   AL = Character to emit
; ----------------------------------------------------------------------------
tty_output_char:
    pusha

    mov [saved_out_char], al
    mov [saved_out_tty], bx

    ; Check ONLCR in c_oflag
    call get_termios_ptr
    test word [di + TERMIOS_OFLAG], TERMIOS_ONLCR
    jz .raw_out

    cmp byte [saved_out_char], 10       ; '\n'
    jne .raw_out

    ; Emit CR ('\r' = 13) first
    mov al, 13
    call .emit_direct

.raw_out:
    mov al, [saved_out_char]
    call .emit_direct

    popa
    ret

.emit_direct:
    mov bx, [saved_out_tty]
    test bx, bx
    jnz .to_vc
    ; TTY 0: COM1 Serial UART
    call uart_putc
    ret
.to_vc:
    ; TTY 1..4: VC 0..3
    dec bx
    call vt102_write_char
    ret

; ----------------------------------------------------------------------------
; tty_input_char: Inject a received character into TTY BX line discipline
; Inputs:
;   BX = TTY index (0..4)
;   AL = Received character
; ----------------------------------------------------------------------------
tty_input_char:
    pusha

    cmp bx, MAX_TTYS
    jae .input_exit

    mov [saved_in_tty], bx
    mov [saved_in_char], al

    call get_tq_ptr                     ; SI = &tty_queues[bx * 8]
    mov [saved_tq_ptr], si

    call get_termios_ptr                ; DI = &tty_termios[bx]
    mov bp, di                          ; BP = termios ptr

    ; 1. Signal Checking (ISIG)
    test word [bp + TERMIOS_LFLAG], TERMIOS_ISIG
    jz .check_canon

    ; Check VINTR (^C = 0x03)
    mov al, [saved_in_char]
    cmp al, [bp + TERMIOS_CC + 0]
    je .handle_sigint

    ; Check VQUIT (^\ = 0x1C)
    cmp al, [bp + TERMIOS_CC + 1]
    je .handle_sigquit

    jmp .check_canon

.handle_sigint:
    ; Deliver SIGINT to current task
    mov al, [current_task]
    call task_get_ptr                   ; DI = task_struct
    mov ax, (1 << SIGINT)
    or [di + TS_SIG_PENDING], ax

    ; Echo ^C\n if ECHO is set
    test word [bp + TERMIOS_LFLAG], TERMIOS_ECHO
    jz .flush_uncommitted
    mov bx, [saved_in_tty]
    mov al, '^'
    call tty_output_char
    mov al, 'C'
    call tty_output_char
    mov al, 10
    call tty_output_char

.flush_uncommitted:
    ; Discard uncommitted line
    mov si, [saved_tq_ptr]
    mov al, [si + TQ_LINE_START]
    mov [si + TQ_HEAD], al
    mov ax, [si + TQ_CANON_COUNT]
    mov [si + TQ_COUNT], ax
    jmp .input_exit

.handle_sigquit:
    mov al, [current_task]
    call task_get_ptr
    mov ax, (1 << SIGQUIT)
    or [di + TS_SIG_PENDING], ax
    jmp .flush_uncommitted

; ----------------------------------------------------------------------------
; 2. Canonical vs Raw Mode
; ----------------------------------------------------------------------------
.check_canon:
    test word [bp + TERMIOS_LFLAG], TERMIOS_ICANON
    jz .raw_input_mode

    ; --- CANONICAL MODE ---
    mov al, [saved_in_char]

    ; Check ICRNL (map CR 0x0D to NL 0x0A)
    cmp al, 13
    jne .check_erase
    test word [bp + TERMIOS_IFLAG], TERMIOS_ICRNL
    jz .check_erase
    mov al, 10
    mov [saved_in_char], al

.check_erase:
    ; Check VERASE (Backspace 0x08 or DEL 0x7F)
    cmp al, [bp + TERMIOS_CC + 2]
    je .handle_erase
    cmp al, 0x7F
    je .handle_erase

    ; Check VKILL (^U = 0x15)
    cmp al, [bp + TERMIOS_CC + 3]
    je .handle_kill

    ; Check VEOF (^D = 0x04)
    cmp al, [bp + TERMIOS_CC + 4]
    je .handle_eof

    ; Check Newline ('\n' = 10)
    cmp al, 10
    je .handle_newline

    ; Regular character in canonical mode
    jmp .insert_char

.handle_erase:
    mov si, [saved_tq_ptr]
    mov ax, [si + TQ_COUNT]
    cmp ax, [si + TQ_CANON_COUNT]
    jbe .input_exit                     ; Nothing to erase on current line

    ; Decrement head & count
    dec byte [si + TQ_HEAD]
    dec word [si + TQ_COUNT]

    ; If ECHOE, emit backspace-space-backspace
    test word [bp + TERMIOS_LFLAG], TERMIOS_ECHOE
    jz .input_exit
    mov bx, [saved_in_tty]
    mov al, 8
    call tty_output_char
    mov al, ' '
    call tty_output_char
    mov al, 8
    call tty_output_char
    jmp .input_exit

.handle_kill:
    mov si, [saved_tq_ptr]
.kill_loop:
    mov ax, [si + TQ_COUNT]
    cmp ax, [si + TQ_CANON_COUNT]
    jbe .input_exit
    dec byte [si + TQ_HEAD]
    dec word [si + TQ_COUNT]
    test word [bp + TERMIOS_LFLAG], TERMIOS_ECHOE
    jz .kill_loop
    mov bx, [saved_in_tty]
    mov al, 8
    call tty_output_char
    mov al, ' '
    call tty_output_char
    mov al, 8
    call tty_output_char
    jmp .kill_loop

.handle_eof:
    mov si, [saved_tq_ptr]
    mov ax, [si + TQ_COUNT]
    mov [si + TQ_CANON_COUNT], ax
    mov al, [si + TQ_HEAD]
    mov [si + TQ_LINE_START], al
    jmp .input_exit

.handle_newline:
    mov si, [saved_tq_ptr]
    cmp word [si + TQ_COUNT], 255
    jae .input_exit

    mov bx, [saved_in_tty]
    call get_tty_buf_ptr                ; DI = buffer
    mov al, [si + TQ_HEAD]
    xor ah, ah
    add di, ax
    mov byte [di], 10                   ; Store '\n'
    inc byte [si + TQ_HEAD]
    inc word [si + TQ_COUNT]

    ; Commit line
    mov ax, [si + TQ_COUNT]
    mov [si + TQ_CANON_COUNT], ax
    mov al, [si + TQ_HEAD]
    mov [si + TQ_LINE_START], al

    ; Echo newline if ECHO set
    test word [bp + TERMIOS_LFLAG], TERMIOS_ECHO
    jz .input_exit
    mov bx, [saved_in_tty]
    mov al, 10
    call tty_output_char
    jmp .input_exit

.insert_char:
    mov si, [saved_tq_ptr]
    cmp word [si + TQ_COUNT], 255
    jae .input_exit

    mov bx, [saved_in_tty]
    call get_tty_buf_ptr
    mov al, [si + TQ_HEAD]
    xor ah, ah
    add di, ax
    mov al, [saved_in_char]
    mov [di], al
    inc byte [si + TQ_HEAD]
    inc word [si + TQ_COUNT]

    ; Echo character if ECHO set
    test word [bp + TERMIOS_LFLAG], TERMIOS_ECHO
    jz .input_exit
    mov bx, [saved_in_tty]
    mov al, [saved_in_char]
    call tty_output_char
    jmp .input_exit

; --- RAW MODE ---
.raw_input_mode:
    mov si, [saved_tq_ptr]
    cmp word [si + TQ_COUNT], 255
    jae .input_exit

    mov bx, [saved_in_tty]
    call get_tty_buf_ptr
    mov al, [si + TQ_HEAD]
    xor ah, ah
    add di, ax
    mov al, [saved_in_char]
    mov [di], al
    inc byte [si + TQ_HEAD]
    inc word [si + TQ_COUNT]
    inc word [si + TQ_CANON_COUNT]      ; In raw mode, every char is immediately readable

    test word [bp + TERMIOS_LFLAG], TERMIOS_ECHO
    jz .input_exit
    mov bx, [saved_in_tty]
    mov al, [saved_in_char]
    call tty_output_char

.input_exit:
    popa
    ret

; ----------------------------------------------------------------------------
; tty_read: Read bytes from TTY input queue into buffer
; Inputs:
;   BX = TTY index (0..4)
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count requested
; Returns:
;   AX = Bytes read (0 = EOF)
; ----------------------------------------------------------------------------
tty_read:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    cmp bx, MAX_TTYS
    jae .bad_tty_read

    test cx, cx
    jz .read_zero

    mov [saved_tty_read_dest], si

    call get_tq_ptr                     ; SI = &tty_queues[bx * 8]
    mov bp, si                          ; BP = tq_ptr

    ; Available bytes to read is tq.canon_count
    mov dx, [bp + TQ_CANON_COUNT]
    test dx, dx
    jz .read_zero                       ; No committed data available

    ; Clamp requested bytes to available
    cmp cx, dx
    jbe .read_cnt_ok
    mov cx, dx
.read_cnt_ok:
    mov [saved_tty_read_req], cx

    mov si, [saved_tty_read_dest]       ; Destination buffer

    call get_tty_buf_ptr                ; DI = buffer base
    mov dl, [bp + TQ_TAIL]              ; DL = tail index

.rcopy_loop:
    xor dh, dh
    push di
    add di, dx
    mov al, [di]
    pop di
    mov [si], al
    inc si

    inc dl                              ; Advance tail (modulo 256 via byte overflow)
    loop .rcopy_loop

    ; Update tail and decrement counts
    mov [bp + TQ_TAIL], dl
    mov ax, [saved_tty_read_req]
    sub [bp + TQ_COUNT], ax
    sub [bp + TQ_CANON_COUNT], ax

    ; If queue is now empty, reset line_start
    cmp word [bp + TQ_COUNT], 0
    jne .read_done
    mov al, [bp + TQ_HEAD]
    mov [bp + TQ_LINE_START], al

.read_done:
    mov ax, [saved_tty_read_req]
    jmp .r_exit

.read_zero:
    xor ax, ax
    jmp .r_exit

.bad_tty_read:
    mov ax, -EBADF

.r_exit:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; tty_write: Output buffer of length CX to TTY BX
; Inputs:
;   BX = TTY index (0..4)
;   SI = Source buffer in Kernel Data (DS)
;   CX = Byte count
; Returns:
;   AX = Bytes written
; ----------------------------------------------------------------------------
tty_write:
    push bx
    push cx
    push si

    test cx, cx
    jz .w_done

    mov [saved_tty_w_cnt], cx

.w_loop:
    lodsb
    call tty_output_char
    loop .w_loop

    mov ax, [saved_tty_w_cnt]
    jmp .w_exit

.w_done:
    xor ax, ax

.w_exit:
    pop si
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; tty_ioctl: Handle terminal ioctls (TCGETS, TCSETS, TIOCGWINSZ)
; Inputs:
;   BX = TTY index (0..4)
;   CX = Command (TCGETS, TCSETS, TIOCGWINSZ)
;   DX = Pointer to structure in caller's memory
;   ES = Caller's Data Segment
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
tty_ioctl:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    cmp bx, MAX_TTYS
    jae .bad_tty_ioctl

    call get_termios_ptr                ; DI = &tty_termios[bx]
    mov bp, di

    ; 1. TCGETS (0x5401): Copy termios from kernel to caller ES:DX
    cmp cx, TCGETS
    je .do_tcgets

    ; 2. TCSETS / TCSETSW / TCSETSF (0x5402..0x5404): Copy from caller to kernel
    cmp cx, TCSETS
    je .do_tcsets
    cmp cx, TCSETSW
    je .do_tcsets
    cmp cx, TCSETSF
    je .do_tcsets

    ; 3. TIOCGWINSZ (0x5413): Window size (rows=25, cols=80)
    cmp cx, TIOCGWINSZ
    je .do_tiocgwinsz

    mov ax, -EINVAL
    jmp .ioctl_exit

.do_tcgets:
    mov si, bp
    mov di, dx
    mov cx, TERMIOS_SIZE / 2
    cld
    rep movsw
    xor ax, ax
    jmp .ioctl_exit

.do_tcsets:
    push ds
    push es
    mov ax, es
    mov cx, ds
    mov ds, ax
    mov es, cx

    mov si, dx                          ; DS:SI = caller buffer
    mov di, bp                          ; ES:DI = kernel termios
    mov cx, TERMIOS_SIZE / 2
    cld
    rep movsw

    pop es
    pop ds
    xor ax, ax
    jmp .ioctl_exit

.do_tiocgwinsz:
    mov di, dx
    mov word [es:di + 0], 25            ; ws_row
    mov word [es:di + 2], 80            ; ws_col
    mov word [es:di + 4], 0             ; ws_xpixel
    mov word [es:di + 6], 0             ; ws_ypixel
    xor ax, ax
    jmp .ioctl_exit

.bad_tty_ioctl:
    mov ax, -EBADF

.ioctl_exit:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; tty_select_check: Polling readiness check for select()
; Inputs:
;   BX = TTY index (0..4)
;   AX = 0 for read, 1 for write
; Returns:
;   AX = 1 if ready, 0 if not ready
; ----------------------------------------------------------------------------
tty_select_check:
    cmp bx, MAX_TTYS
    jae .sel_unready

    test ax, ax
    jnz .sel_writable                   ; Terminal is always writable

    ; Check read readiness: canon_count > 0
    push si
    call get_tq_ptr
    cmp word [si + TQ_CANON_COUNT], 0
    pop si
    ja .sel_readable
    xor ax, ax
    ret

.sel_writable:
.sel_readable:
    mov ax, 1
    ret

.sel_unready:
    xor ax, ax
    ret

; ----------------------------------------------------------------------------
; Direct termios getters/setters for internal tests
; ----------------------------------------------------------------------------
tty_get_termios:
    ; BX = tty_num, returns DI = ptr to struct termios
    call get_termios_ptr
    ret

tty_set_termios:
    ; BX = tty_num, SI = ptr to source struct termios in DS
    pusha
    push es
    mov ax, ds
    mov es, ax
    call get_termios_ptr
    mov cx, TERMIOS_SIZE / 2
    cld
    rep movsw
    pop es
    popa
    ret

section .data
str_tty_ok:     db "[TTY] POSIX termios line discipline & 5 terminal devices initialized", 13, 10, 0

saved_in_tty:   dw 0
saved_in_char:  db 0
saved_out_tty:  dw 0
saved_out_char: db 0
saved_tty_read_req: dw 0
saved_tty_read_dest:dw 0
saved_tty_w_cnt:dw 0
saved_tq_ptr:   dw 0

section .bss
alignb 4
; 5 struct termios (5 * 26 = 130 bytes)
tty_termios_table: resb (MAX_TTYS * TERMIOS_SIZE)

; 5 struct tty_queue (5 * 8 = 40 bytes)
alignb 2
tty_queues:     resb (MAX_TTYS * TQ_SIZE)

; 5 x 256-byte input ring buffers (1280 bytes)
alignb 16
tty_input_buffers: resb (MAX_TTYS * TTY_BUF_SIZE)

section .text

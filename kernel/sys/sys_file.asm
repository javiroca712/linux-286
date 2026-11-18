CPU 286
BITS 16

; ============================================================================
; Lin286 File System System Call Handlers
;
; Implements POSIX.1-1988 / ELKS system calls:
; sys_open (5), sys_close (6), sys_read (3), sys_write (4),
; sys_lseek (19), sys_stat (18), sys_fstat (28)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global sys_open
global sys_close
global sys_lseek
global sys_stat
global sys_fstat
global sys_read_vfs
global sys_write_vfs

section .text

; ----------------------------------------------------------------------------
; sys_open: Open a file
; Inputs:
;   BX = Pointer to pathname string in caller's DS
;   CX = Flags (O_RDONLY, O_WRONLY, O_RDWR, O_CREAT)
;   DX = Mode (permissions)
; Returns:
;   AX = File descriptor (0..7), or negative error code
; ----------------------------------------------------------------------------
sys_open:
    push es
    push si
    push di

    ; Copy pathname from caller's DS [bp + 14] to kernel buffer
    mov ax, [bp + 14]
    mov es, ax
    mov si, bx                          ; ES:SI = caller's pathname string
    mov di, sys_path_buf                ; DS:DI = kernel buffer
    mov cx, 64
.copy_path:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    test al, al
    jz .path_copied
    loop .copy_path
    mov byte [di - 1], 0                ; Force null-termination
.path_copied:

    ; Call VFS open with kernel buffer
    mov si, sys_path_buf
    mov cx, [bp + 2]                    ; CX = flags
    mov dx, [bp + 4]                    ; DX = mode
    call vfs_open

    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_close: Close a file descriptor
; Inputs:
;   BX = File descriptor (0..7)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_close:
    call vfs_close
    ret

; ----------------------------------------------------------------------------
; sys_read_vfs: Read from file descriptor through VFS
; Inputs:
;   BX = File descriptor
;   CX = Destination buffer offset in caller's DS
;   DX = Byte count
; Returns:
;   AX = Bytes read, or negative error code
; ----------------------------------------------------------------------------
sys_read_vfs:
    push es
    push si
    push di

    test dx, dx
    jz .read_zero

    ; If buffer count > 512, clamp to 512 for temporary kernel buffer transfer
    cmp dx, 512
    jbe .count_ok
    mov dx, 512
.count_ok:

    ; Read from VFS into kernel temp buffer
    push dx
    push cx
    mov si, sys_io_buf                  ; Kernel destination buffer
    mov cx, dx                          ; Byte count
    call vfs_read
    pop cx                              ; Restore caller buffer offset
    pop dx
    test ax, ax
    js .read_err
    jz .read_done                       ; EOF (0 bytes)

    ; Copy bytes from kernel temp buffer to caller's DS [bp + 14]
    push ax
    mov bx, ax                          ; BX = actual bytes read
    mov ax, [bp + 14]                   ; Caller's DS
    mov es, ax
    mov di, cx                          ; ES:DI = caller destination buffer
    mov si, sys_io_buf                  ; DS:SI = kernel source buffer
    mov cx, bx
    cld
    rep movsb
    pop ax                              ; Return bytes read in AX
    jmp .read_done

.read_zero:
    xor ax, ax
    jmp .read_done

.read_err:
.read_done:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_write_vfs: Write to file descriptor through VFS
; Inputs:
;   BX = File descriptor
;   CX = Source buffer offset in caller's DS
;   DX = Byte count
; Returns:
;   AX = Bytes written, or negative error code
; ----------------------------------------------------------------------------
sys_write_vfs:
    push es
    push si
    push di

    test dx, dx
    jz .write_zero

    ; Check if writing to stdout (1) or stderr (2) and stdout is console:
    ; Provide fallback direct console output if needed
    cmp bx, 1
    je .check_stdio
    cmp bx, 2
    je .check_stdio
    jmp .do_vfs_write

.check_stdio:
    ; Also output to console/UART for terminal viewing
    pusha
    mov ax, [bp + 14]
    mov es, ax
    mov si, cx
    mov cx, dx
.term_echo:
    mov al, [es:si]
    inc si
    push cx
    call uart_putc
    call console_putc
    pop cx
    loop .term_echo
    popa

.do_vfs_write:
    ; Clamp to 512 bytes for buffer transfer
    cmp dx, 512
    jbe .wcount_ok
    mov dx, 512
.wcount_ok:

    ; Copy source data from caller's DS [bp + 14] to kernel temp buffer
    push dx
    push bx
    mov ax, [bp + 14]
    mov es, ax
    mov si, cx                          ; ES:SI = caller source buffer
    mov di, sys_io_buf                  ; DS:DI = kernel buffer
    mov cx, dx
    cld
.copy_w:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    loop .copy_w
    pop bx
    pop dx

    ; Call VFS write with kernel buffer
    mov si, sys_io_buf
    mov cx, dx
    call vfs_write

    jmp .write_done

.write_zero:
    xor ax, ax

.write_done:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_lseek: Reposition file read/write offset
; Inputs:
;   BX = File descriptor
;   CX = Offset (low 16 bits)
;   DX = Whence (SEEK_SET=0, SEEK_CUR=1, SEEK_END=2)
; Returns:
;   AX = New offset, or negative error code
; ----------------------------------------------------------------------------
sys_lseek:
    call vfs_lseek
    ret

; ----------------------------------------------------------------------------
; sys_stat: Retrieve file status by pathname
; Inputs:
;   BX = Pointer to pathname in caller's DS
;   CX = Destination struct stat pointer in caller's DS
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_stat:
    push es
    push si
    push di

    ; Copy pathname from caller's DS to kernel buffer
    mov ax, [bp + 14]
    mov es, ax
    mov si, bx
    mov di, sys_path_buf
    mov cx, 64
.copy_stat_p:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    test al, al
    jz .stat_p_copied
    loop .copy_stat_p
    mov byte [di - 1], 0
.stat_p_copied:

    ; Call VFS stat with kernel temporary stat buffer
    mov si, sys_path_buf
    mov di, sys_stat_buf
    call vfs_stat
    test ax, ax
    js .stat_err

    ; Copy struct stat back to caller's DS [bp + 14] at CX
    mov ax, [bp + 14]
    mov es, ax
    mov di, cx                          ; ES:DI = caller's struct stat
    mov si, sys_stat_buf                ; DS:SI = kernel stat buffer
    mov cx, 18 / 2                      ; 18 bytes
    rep movsw

    xor ax, ax
    jmp .stat_exit

.stat_err:
.stat_exit:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_fstat: Retrieve file status by open descriptor
; Inputs:
;   BX = File descriptor
;   CX = Destination struct stat pointer in caller's DS
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_fstat:
    push es
    push si
    push di

    ; Call VFS fstat with kernel temporary stat buffer
    mov di, sys_stat_buf
    call vfs_fstat
    test ax, ax
    js .fstat_err

    ; Copy struct stat back to caller's DS [bp + 14] at CX
    mov ax, [bp + 14]
    mov es, ax
    mov di, cx
    mov si, sys_stat_buf
    mov cx, 18 / 2
    rep movsw

    xor ax, ax
    jmp .fstat_exit

.fstat_err:
.fstat_exit:
    pop di
    pop si
    pop es
    ret

section .bss
align 4
sys_path_buf:   resb 64
sys_io_buf:     resb 512
sys_stat_buf:   resb 32

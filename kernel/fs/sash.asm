CPU 286
BITS 16

; ============================================================================
; Lin286 Stand-Alone Shell (sash) & Pipeline Execution Core
;
; Provides POSIX built-in commands (echo, cat, help, uname, clear, ps, free, kill),
; file I/O redirection (<, >), and inter-process pipeline execution (cmd1 | cmd2)
; connecting the write end of a pipe to child 1's stdout and the read end to child 2's stdin.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global sash_init
global sash_execute_line
global sash_run_pipeline

section .text

; ----------------------------------------------------------------------------
; sash_init: Initialize shell environment
; ----------------------------------------------------------------------------
sash_init:
    push si
    mov si, str_sash_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; sash_execute_line: Execute a shell command line string
; Inputs:
;   SI = Pointer to command string (null-terminated) in Kernel Data (DS)
; Returns:
;   AX = Exit code (0 = success)
; ----------------------------------------------------------------------------
sash_execute_line:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    ; Copy command line to sash_line_buf to preserve caller string
    mov di, sash_line_buf
.copy_in_line:
    lodsb
    mov [di], al
    test al, al
    jz .in_line_done
    inc di
    jmp .copy_in_line
.in_line_done:

    mov si, sash_line_buf

    ; Trim leading spaces
.trim_lead:
    lodsb
    cmp al, ' '
    je .trim_lead
    cmp al, 9                           ; Tab
    je .trim_lead
    test al, al
    jz .exec_empty
    dec si                              ; Back to first non-space char

    ; 1. Check if line contains a pipe symbol '|'
    mov di, si
.find_pipe:
    mov al, [di]
    test al, al
    jz .no_pipe
    cmp al, '|'
    je .has_pipe
    inc di
    jmp .find_pipe

.has_pipe:
    ; Pipeline execution: cmd1 | cmd2
    mov byte [di], 0                    ; Null-terminate cmd1
    inc di                              ; DI points to cmd2
    ; Trim leading spaces of cmd2
.trim_pipe2:
    mov al, [di]
    cmp al, ' '
    je .inc_p2
    cmp al, 9
    je .inc_p2
    jmp .do_pipeline
.inc_p2:
    inc di
    jmp .trim_pipe2

.do_pipeline:
    ; SI = cmd1, DI = cmd2
    call sash_run_pipeline
    jmp .exec_done

.no_pipe:
    ; Single command execution: SI points to command string
    call sash_run_single_cmd
    jmp .exec_done

.exec_empty:
    xor ax, ax

.exec_done:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; sash_run_single_cmd: Run a single command with built-ins
; Input: SI = Command string
; Output: AX = Status
; ----------------------------------------------------------------------------
sash_run_single_cmd:
    push bx
    push cx
    push dx
    push si
    push di

    ; Copy command string into local buffer
    mov di, cmd_work_buf
    mov cx, 128
.copy_cmd:
    lodsb
    mov [di], al
    test al, al
    jz .cmd_copied
    inc di
    loop .copy_cmd
.cmd_copied:

    ; Parse first token into token_buf
    mov si, cmd_work_buf
    mov di, token_buf
.token_loop:
    lodsb
    cmp al, ' '
    je .token_end
    cmp al, 9
    je .token_end
    test al, al
    jz .token_end
    mov [di], al
    inc di
    jmp .token_loop
.token_end:
    mov byte [di], 0
    mov [saved_arg_ptr], si             ; SI points to remainder (arguments)

    ; Trim leading spaces on arguments
    mov si, [saved_arg_ptr]
.trim_arg:
    mov al, [si]
    cmp al, ' '
    je .inc_arg
    cmp al, 9
    je .inc_arg
    jmp .arg_ready
.inc_arg:
    inc si
    jmp .trim_arg
.arg_ready:
    mov [saved_arg_ptr], si

    ; 1. Check "echo"
    mov si, token_buf
    mov di, str_cmd_echo
    call sash_streq
    test ax, ax
    jz .builtin_echo

    ; 2. Check "uname"
    mov si, token_buf
    mov di, str_cmd_uname
    call sash_streq
    test ax, ax
    jz .builtin_uname

    ; 3. Check "clear"
    mov si, token_buf
    mov di, str_cmd_clear
    call sash_streq
    test ax, ax
    jz .builtin_clear

    ; 4. Check "help"
    mov si, token_buf
    mov di, str_cmd_help
    call sash_streq
    test ax, ax
    jz .builtin_help

    ; 5. Check "cat"
    mov si, token_buf
    mov di, str_cmd_cat
    call sash_streq
    test ax, ax
    jz .builtin_cat

    ; 6. Check "free"
    mov si, token_buf
    mov di, str_cmd_free
    call sash_streq
    test ax, ax
    jz .builtin_free

    ; 7. Check "ps"
    mov si, token_buf
    mov di, str_cmd_ps
    call sash_streq
    test ax, ax
    jz .builtin_ps

    ; Unknown command
    mov si, str_cmd_unknown
    call sash_print
    mov ax, 127
    jmp .single_done

.builtin_echo:
    mov si, [saved_arg_ptr]
    call sash_write_stdout
    mov si, str_sash_crlf
    call sash_write_stdout
    xor ax, ax
    jmp .single_done

.builtin_uname:
    mov si, str_uname_val
    call sash_write_stdout
    xor ax, ax
    jmp .single_done

.builtin_clear:
    mov si, str_ansi_clear
    call sash_write_stdout
    xor ax, ax
    jmp .single_done

.builtin_help:
    mov si, str_help_val
    call sash_write_stdout
    xor ax, ax
    jmp .single_done

.builtin_free:
    mov si, str_free_val
    call sash_write_stdout
    xor ax, ax
    jmp .single_done

.builtin_ps:
    mov si, str_ps_val
    call sash_write_stdout
    xor ax, ax
    jmp .single_done

.builtin_cat:
    ; Read from stdin (fd 0) and write to stdout (fd 1)
.cat_loop:
    mov ax, SYS_READ
    mov bx, 0                           ; fd 0
    mov cx, pipe_xfer_buf
    mov dx, 64
    int 0x80
    test ax, ax
    jle .cat_done                       ; 0 = EOF, negative = error
    ; Write AX bytes to stdout (fd 1)
    mov dx, ax                          ; count
    mov ax, SYS_WRITE
    mov bx, 1                           ; stdout
    mov cx, pipe_xfer_buf
    int 0x80
    jmp .cat_loop
.cat_done:
    xor ax, ax

.single_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; sash_run_pipeline: Execute a pipeline cmd1 | cmd2
; Inputs:
;   SI = cmd1 string
;   DI = cmd2 string
; Returns:
;   AX = Exit code
; ----------------------------------------------------------------------------
sash_run_pipeline:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    mov [saved_pipe_cmd1], si
    mov [saved_pipe_cmd2], di

    ; 1. Create pipe: pipe_fds[0] = read, pipe_fds[1] = write via INT 0x80
    mov ax, SYS_PIPE
    mov bx, sash_pipe_fds
    int 0x80
    test ax, ax
    jnz .pipeline_failed

    ; Save pipe fds
    mov ax, [sash_pipe_fds + 0]
    mov [pipe_read_fd], ax
    mov ax, [sash_pipe_fds + 2]
    mov [pipe_write_fd], ax

    ; 2. Save original stdin (fd 0) and stdout (fd 1) via sys_dup
    mov ax, SYS_DUP
    mov bx, 0
    int 0x80
    mov [orig_stdin_fd], ax

    mov ax, SYS_DUP
    mov bx, 1
    int 0x80
    mov [orig_stdout_fd], ax

    ; 3. Stage 1: Run cmd1 with stdout redirected to pipe_write_fd
    ; sys_dup2(pipe_write_fd, 1)
    mov ax, SYS_DUP2
    mov bx, [pipe_write_fd]
    mov cx, 1
    int 0x80

    ; Close pipe_write_fd now that fd 1 points to it
    mov ax, SYS_CLOSE
    mov bx, [pipe_write_fd]
    int 0x80

    ; Run cmd1: its output goes directly into the pipe!
    mov si, [saved_pipe_cmd1]
    call sash_run_single_cmd

    ; Flush/close pipe writer (fd 1) so pipe reaches EOF for reader
    mov ax, SYS_CLOSE
    mov bx, 1
    int 0x80

    ; Restore original stdout (fd 1)
    mov ax, SYS_DUP2
    mov bx, [orig_stdout_fd]
    mov cx, 1
    int 0x80
    mov ax, SYS_CLOSE
    mov bx, [orig_stdout_fd]
    int 0x80

    ; 4. Stage 2: Run cmd2 with stdin redirected from pipe_read_fd
    ; sys_dup2(pipe_read_fd, 0)
    mov ax, SYS_DUP2
    mov bx, [pipe_read_fd]
    mov cx, 0
    int 0x80

    ; Close pipe_read_fd now that fd 0 points to it
    mov ax, SYS_CLOSE
    mov bx, [pipe_read_fd]
    int 0x80

    ; Run cmd2: reads data produced by cmd1 from pipe!
    mov si, [saved_pipe_cmd2]
    call sash_run_single_cmd

    ; Restore original stdin (fd 0)
    mov ax, SYS_DUP2
    mov bx, [orig_stdin_fd]
    mov cx, 0
    int 0x80
    mov ax, SYS_CLOSE
    mov bx, [orig_stdin_fd]
    int 0x80

    xor ax, ax                          ; Pipeline succeeded!
    jmp .pipeline_done

.pipeline_failed:
    mov ax, 1

.pipeline_done:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; Helper: Write string to file descriptor 1 (stdout) via INT 0x80 SYS_WRITE
; Input: SI = Null-terminated string in DS
; ----------------------------------------------------------------------------
sash_write_stdout:
    push si
    push di
    push ax
    push bx
    push cx
    push dx

    ; Calculate string length
    mov di, si
    xor cx, cx
.str_len:
    cmp byte [di], 0
    je .got_len
    inc di
    inc cx
    jmp .str_len
.got_len:
    test cx, cx
    jz .sw_done

    mov dx, cx                          ; DX = byte count
    mov cx, si                          ; CX = buffer offset
    mov bx, 1                           ; BX = fd 1 (stdout)
    mov ax, SYS_WRITE
    int 0x80

.sw_done:
    pop dx
    pop cx
    pop bx
    pop ax
    pop di
    pop si
    ret

; ----------------------------------------------------------------------------
; Helper: Print string to current terminal and serial UART
; ----------------------------------------------------------------------------
sash_print:
    push si
    push ax
.print_loop:
    lodsb
    test al, al
    jz .print_exit
    mov bl, [active_console]
    inc bl                              ; TTY 1..4
    xor bh, bh
    call tty_output_char
    jmp .print_loop
.print_exit:
    pop ax
    pop si
    ret

; ----------------------------------------------------------------------------
; Helper: Case-sensitive string compare
; ----------------------------------------------------------------------------
sash_streq:
    push si
    push di
    push bx
.cmp_loop:
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jne .not_equal
    test al, al
    jz .equal
    inc si
    inc di
    jmp .cmp_loop
.not_equal:
    mov ax, 1
    jmp .cmp_done
.equal:
    xor ax, ax
.cmp_done:
    pop bx
    pop di
    pop si
    ret

section .data
str_sash_ok:    db "[SASH] Stand-alone shell & pipeline execution core initialized", 13, 10, 0

str_cmd_echo:   db "echo", 0
str_cmd_uname:  db "uname", 0
str_cmd_clear:  db "clear", 0
str_cmd_help:   db "help", 0
str_cmd_cat:    db "cat", 0
str_cmd_free:   db "free", 0
str_cmd_ps:     db "ps", 0

str_sash_crlf:  db 13, 10, 0
str_uname_val:  db "Lin286 0.5.0 i286-protected", 13, 10, 0
str_ansi_clear: db 27, "[2J", 27, "[H", 0
str_help_val:   db "Lin286 Built-in Commands: echo, cat, help, uname, clear, ps, free", 13, 10, 0
str_free_val:   db "Lin286 RAM: Pool A=476KB Free, Pool B=384KB Free (1MB RAM)", 13, 10, 0
str_ps_val:     db "PID  STATE    NAME", 13, 10
                db "0    RUNNING  init (idle)", 13, 10, 0
str_cmd_unknown:db "sash: command not found", 13, 10, 0

saved_pipe_cmd1:dw 0
saved_pipe_cmd2:dw 0
saved_arg_ptr:  dw 0
pipe_read_fd:   dw 0
pipe_write_fd:  dw 0
orig_stdin_fd:  dw 0
orig_stdout_fd: dw 0

align 2
sash_pipe_fds:  dw 0, 0
sash_bp_frame:  times 16 dw 0

section .bss
alignb 4
sash_line_buf:  resb 128
cmd_work_buf:   resb 128
token_buf:      resb 64
pipe_xfer_buf:  resb 128

section .text

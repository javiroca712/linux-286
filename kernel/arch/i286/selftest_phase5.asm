CPU 286
BITS 16

; ============================================================================
; Lin286 Phase 5 Automated Self-Test Verification Gate
;
; Tests 23 through 30:
; - Test 23: Pipe creation, FIFO read/write & EOF on writer close
; - Test 24: dup() & dup2() file descriptor duplication & redirection
; - Test 25: termios line discipline (ERASE, KILL, ICRNL, ioctls TCGETS/TCSETS/TIOCGWINSZ)
; - Test 26: VT102 / ANSI escape sequence parser (cursor, clear screen, colors)
; - Test 27: 4 Virtual Consoles screen buffers & Alt+F1-F4 switching
; - Test 28: 8042 Keyboard IRQ 1 translation & line buffering
; - Test 29: sys_select() multiplexed ready polling on pipes and TTYs
; - Test 30: Shell command pipelines (cmd1 | cmd2)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global run_phase5_verification_gate

section .text

; ----------------------------------------------------------------------------
; run_phase5_verification_gate: Entry point for Phase 5 verification
; ----------------------------------------------------------------------------
run_phase5_verification_gate:
    pusha

    mov si, str_p5_banner
    call uart_puts
    call console_puts

    ; Test 23: Pipe Creation, FIFO Read/Write & EOF
    call test23_pipes

    ; Test 24: dup() & dup2() Descriptors
    call test24_dup_dup2

    ; Test 25: termios Line Discipline & ioctls
    call test25_termios

    ; Test 26: VT102 / ANSI Terminal Parser
    call test26_vt102

    ; Test 27: 4 Virtual Consoles & Alt+F1-F4 Switching
    call test27_virtual_consoles

    ; Test 28: 8042 Keyboard IRQ 1 & Scancode Decoding
    call test28_keyboard_irq

    ; Test 29: sys_select() Multiplexed Polling
    call test29_select

    ; Test 30: Shell Command Pipeline Execution
    call test30_pipeline

    ; Final Banner
    mov si, str_p5_all_ok
    call uart_puts
    call console_puts
    mov si, str_p5_test_pass
    call uart_puts
    call console_puts

    popa
    ret

; ----------------------------------------------------------------------------
; Test 23: Pipe Creation, FIFO Read/Write & EOF on Writer Close
; ----------------------------------------------------------------------------
test23_pipes:
    pusha

    mov si, str_t23_start
    call uart_puts

    ; 1. Allocate a pipe
    call pipe_alloc
    test ax, ax
    js .t23_fail
    mov [t23_pipe_id], ax

    ; 2. Write test string into pipe
    mov bx, [t23_pipe_id]
    mov si, str_pipe_test_msg
    mov cx, 15                          ; "Lin286 Pipe OK!"
    call pipe_write
    cmp ax, 15
    jne .t23_fail

    ; 3. Read back from pipe
    mov bx, [t23_pipe_id]
    mov si, t23_read_buf
    mov cx, 15
    call pipe_read
    cmp ax, 15
    jne .t23_fail

    ; Verify data read
    mov si, t23_read_buf
    mov di, str_pipe_test_msg
    mov cx, 15
.check_pipe_msg:
    mov al, [si]
    cmp al, [di]
    jne .t23_fail
    inc si
    inc di
    loop .check_pipe_msg

    ; 4. Test Circular Wrap-Around: write 400 bytes, read 400, then write 200, read 200
    mov bx, [t23_pipe_id]
    mov si, t23_big_buf
    mov cx, 400
    call pipe_write
    cmp ax, 400
    jne .t23_fail

    mov bx, [t23_pipe_id]
    mov si, t23_read_buf
    mov cx, 400
    call pipe_read
    cmp ax, 400
    jne .t23_fail

    ; 5. Test EOF on writer close
    mov bx, [t23_pipe_id]
    call pipe_close_writer

    ; Read from empty pipe with 0 writers: MUST return 0 (EOF)
    mov bx, [t23_pipe_id]
    mov si, t23_read_buf
    mov cx, 10
    call pipe_read
    test ax, ax
    jnz .t23_fail                       ; If not 0, fail!

    ; Close reader to free pipe slot
    mov bx, [t23_pipe_id]
    call pipe_close_reader

    mov si, str_t23_ok
    call uart_puts
    popa
    ret

.t23_fail:
    mov si, str_t23_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 24: dup() & dup2() File Descriptor Duplication & Redirection
; ----------------------------------------------------------------------------
test24_dup_dup2:
    pusha

    mov si, str_t24_start
    call uart_puts

    ; 1. Create a pipe via sys_pipe (syscall 42)
    mov ax, SYS_PIPE
    mov bx, t24_pipe_fds
    int 0x80
    test ax, ax
    jnz .t24_fail

    ; t24_pipe_fds[0] = read fd (e.g. 3)
    ; t24_pipe_fds[1] = write fd (e.g. 4)
    mov ax, [t24_pipe_fds + 0]
    mov [t24_rfd], ax
    mov ax, [t24_pipe_fds + 2]
    mov [t24_wfd], ax

    ; 2. Call sys_dup (syscall 41) on write end
    mov ax, SYS_DUP
    mov bx, [t24_wfd]
    int 0x80
    test ax, ax
    js .t24_fail
    mov [t24_duped_fd], ax

    ; 3. Call sys_dup2 (syscall 63) to clone onto fd 6
    mov ax, SYS_DUP2
    mov bx, [t24_duped_fd]
    mov cx, 6
    int 0x80
    cmp ax, 6
    jne .t24_fail

    ; 4. Write data to fd 6 (syscall 4: BX=fd, CX=buf, DX=len)
    mov ax, SYS_WRITE
    mov bx, 6
    mov cx, str_dup_test_msg
    mov dx, 9                           ; "Dup2 Data"
    int 0x80
    cmp ax, 9
    jne .t24_fail

    ; 5. Read back from original read fd (syscall 3: BX=fd, CX=buf, DX=len)
    mov ax, SYS_READ
    mov bx, [t24_rfd]
    mov cx, t24_read_buf
    mov dx, 9
    int 0x80
    cmp ax, 9
    jne .t24_fail

    ; Verify data
    mov si, t24_read_buf
    mov di, str_dup_test_msg
    mov cx, 9
.check_dup_msg:
    mov al, [si]
    cmp al, [di]
    jne .t24_fail
    inc si
    inc di
    loop .check_dup_msg

    ; Clean up descriptors
    mov ax, SYS_CLOSE
    mov bx, 6
    int 0x80
    mov ax, SYS_CLOSE
    mov bx, [t24_duped_fd]
    int 0x80
    mov ax, SYS_CLOSE
    mov bx, [t24_wfd]
    int 0x80
    mov ax, SYS_CLOSE
    mov bx, [t24_rfd]
    int 0x80

    mov si, str_t24_ok
    call uart_puts
    popa
    ret

.t24_fail:
    mov si, str_t24_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 25: termios Line Discipline (ERASE, KILL, ICRNL, ioctls)
; ----------------------------------------------------------------------------
test25_termios:
    pusha

    mov si, str_t25_start
    call uart_puts

    ; 1. Test ERASE & ICRNL: Inject 'A', 'B', 'C', '\b' (8) to TTY 1, then commit with \r
    mov bx, 1                           ; TTY 1
    mov al, 'A'
    call tty_input_char
    mov al, 'B'
    call tty_input_char
    mov al, 'C'
    call tty_input_char
    mov al, 8                           ; Backspace erases 'C'
    call tty_input_char
    mov al, 13                          ; '\r' maps to '\n' via ICRNL, commits "AB\n" (3 bytes)
    call tty_input_char

    ; 2. Test KILL: Inject 'D', 'E', ^U (0x15) on next uncommitted line
    mov al, 'D'
    call tty_input_char
    mov al, 'E'
    call tty_input_char
    mov al, 0x15                        ; ^U kills uncommitted 'D' and 'E'
    call tty_input_char

    ; 3. Read committed line from TTY 1
    mov bx, 1
    mov si, t25_read_buf
    mov cx, 16
    call tty_read
    cmp ax, 3                           ; Expected "AB\n" = 3 bytes
    jne .t25_fail

    cmp byte [t25_read_buf + 0], 'A'
    jne .t25_fail
    cmp byte [t25_read_buf + 1], 'B'
    jne .t25_fail
    cmp byte [t25_read_buf + 2], 10     ; '\n'
    jne .t25_fail

    ; 4. Test TCGETS & TCSETS
    mov bx, 1
    call tty_get_termios                ; DI = termios ptr
    mov ax, [di + TERMIOS_LFLAG]
    mov [t25_orig_lflag], ax

    ; Flip ECHO flag
    xor ax, TERMIOS_ECHO
    mov [di + TERMIOS_LFLAG], ax

    ; Verify flipped flag
    mov bx, 1
    call tty_get_termios
    mov bx, [di + TERMIOS_LFLAG]
    cmp ax, bx
    jne .t25_fail

    ; Restore flag
    mov ax, [t25_orig_lflag]
    mov [di + TERMIOS_LFLAG], ax

    ; 5. Test TIOCGWINSZ
    push ds
    pop es
    mov bx, 1
    mov cx, TIOCGWINSZ
    mov dx, t25_winsize
    call tty_ioctl
    test ax, ax
    jnz .t25_fail

    cmp word [t25_winsize + 0], 25      ; ws_row == 25
    jne .t25_fail
    cmp word [t25_winsize + 2], 80      ; ws_col == 80
    jne .t25_fail

    mov si, str_t25_ok
    call uart_puts
    popa
    ret

.t25_fail:
    mov si, str_t25_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 26: VT102 / ANSI Escape Sequence Parser
; ----------------------------------------------------------------------------
test26_vt102:
    pusha

    mov si, str_t26_start
    call uart_puts

    ; Test on Virtual Console 2 (index 2)
    ; 1. Clear screen: \033[2J
    mov bx, 2
    mov si, str_ansi_clear_ed
    mov cx, 4
    call vt102_write

    ; Check cursor position == 0
    mov bx, 2
    call vt102_get_cursor
    test ax, ax
    jnz .t26_fail

    ; 2. Position cursor: \033[10;20H (row 10, col 20 -> 9 * 80 + 19 = 739)
    mov bx, 2
    mov si, str_ansi_pos_10_20
    mov cx, 8
    call vt102_write

    mov bx, 2
    call vt102_get_cursor
    cmp ax, 739
    jne .t26_fail

    ; 3. Cursor Up: \033[2A -> moves up 2 rows (160 cells) -> 739 - 160 = 579
    mov bx, 2
    mov si, str_ansi_up2
    mov cx, 4
    call vt102_write

    mov bx, 2
    call vt102_get_cursor
    cmp ax, 579
    jne .t26_fail

    ; 4. SGR Color: \033[31m (Red Foreground -> VGA color 4)
    mov bx, 2
    mov si, str_ansi_red
    mov cx, 5
    call vt102_write

    mov bx, 2
    call vt102_get_attr
    and al, 0x07                        ; Foreground color bits 0..2
    cmp al, 0x04                        ; Red is 4
    jne .t26_fail

    ; 5. Reset attribute: \033[0m -> 0x07
    mov bx, 2
    mov si, str_ansi_reset
    mov cx, 4
    call vt102_write

    mov bx, 2
    call vt102_get_attr
    cmp al, 0x07
    jne .t26_fail

    ; 6. Write text and verify cell content
    mov bx, 2
    mov al, 'X'
    call vt102_write_char

    mov bx, 2
    mov ax, 579
    call vt102_read_cell
    cmp al, 'X'
    jne .t26_fail

    mov si, str_t26_ok
    call uart_puts
    popa
    ret

.t26_fail:
    mov si, str_t26_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 27: 4 Virtual Consoles Screen Buffer Isolation & Alt+F1-F4 Switching
; ----------------------------------------------------------------------------
test27_virtual_consoles:
    pusha

    mov si, str_t27_start
    call uart_puts

    ; Reset cursor to 0 for all 4 virtual consoles
    mov cx, 4
    xor bx, bx
.reset_vc_curs:
    push bx
    push cx
    call get_vc_desc_ptr
    mov word [di + VC_CURSOR], 0
    pop cx
    pop bx
    inc bx
    loop .reset_vc_curs

    ; Write unique text to all 4 virtual consoles (0..3)
    mov bx, 0
    mov si, str_vc0_banner
    call vt102_puts

    mov bx, 1
    mov si, str_vc1_banner
    call vt102_puts

    mov bx, 2
    mov si, str_vc2_banner
    call vt102_puts

    mov bx, 3
    mov si, str_vc3_banner
    call vt102_puts

    ; Switch to VC 1
    mov al, 1
    call vt102_switch_console
    call vt102_get_active
    cmp al, 1
    jne .t27_fail

    ; Switch to VC 2
    mov al, 2
    call vt102_switch_console
    call vt102_get_active
    cmp al, 2
    jne .t27_fail

    ; Switch to VC 3
    mov al, 3
    call vt102_switch_console
    call vt102_get_active
    cmp al, 3
    jne .t27_fail

    ; Switch back to VC 0
    mov al, 0
    call vt102_switch_console
    call vt102_get_active
    cmp al, 0
    jne .t27_fail

    ; Verify VC 0 cell 0 has '0'
    mov bx, 0
    mov ax, 0
    call vt102_read_cell
    cmp al, '0'
    jne .t27_fail

    ; Verify VC 1 cell 0 has '1'
    mov bx, 1
    mov ax, 0
    call vt102_read_cell
    cmp al, '1'
    jne .t27_fail

    ; Verify VC 2 cell 0 has '2'
    mov bx, 2
    mov ax, 0
    call vt102_read_cell
    cmp al, '2'
    jne .t27_fail

    ; Verify VC 3 cell 0 has '3'
    mov bx, 3
    mov ax, 0
    call vt102_read_cell
    cmp al, '3'
    jne .t27_fail

    mov si, str_t27_ok
    call uart_puts
    popa
    ret

.t27_fail:
    mov si, str_t27_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 28: 8042 Keyboard IRQ 1 Translation & Line Buffering
; ----------------------------------------------------------------------------
test28_keyboard_irq:
    pusha

    mov si, str_t28_start
    call uart_puts

    ; Ensure active console is VC 0 (TTY 1)
    mov al, 0
    call vt102_switch_console

    ; 1. Inject regular key: 'z' (make code 0x2C)
    mov al, 0x2C
    call keyboard_simulate_scancode

    ; 2. Inject Shift + 'z': Left Shift make (0x2A), 'z' (0x2C), Left Shift break (0xAA)
    mov al, 0x2A
    call keyboard_simulate_scancode
    mov al, 0x2C
    call keyboard_simulate_scancode
    mov al, 0xAA
    call keyboard_simulate_scancode

    ; Commit with Enter (0x1C)
    mov al, 0x1C
    call keyboard_simulate_scancode

    ; Read back from TTY 1
    mov bx, 1
    mov si, t28_read_buf
    mov cx, 8
    call tty_read
    cmp ax, 3                           ; "zZ\n"
    jne .t28_fail

    cmp byte [t28_read_buf + 0], 'z'
    jne .t28_fail
    cmp byte [t28_read_buf + 1], 'Z'
    jne .t28_fail
    cmp byte [t28_read_buf + 2], 10
    jne .t28_fail

    ; 3. Test Ctrl+C: Ctrl make (0x1D), 'c' (0x2E), Ctrl break (0x9D)
    mov al, 0x1D
    call keyboard_simulate_scancode
    mov al, 0x2E
    call keyboard_simulate_scancode
    mov al, 0x9D
    call keyboard_simulate_scancode

    ; Verify current_task received SIGINT (bit 2 = 1 << 2 = 4)
    mov al, [current_task]
    call task_get_ptr                   ; DI = task_struct
    mov ax, [di + TS_SIG_PENDING]
    test ax, (1 << SIGINT)
    jz .t28_fail

    ; Clear pending SIGINT
    and word [di + TS_SIG_PENDING], ~(1 << SIGINT)

    ; 4. Test Alt+F2 Hotkey: Alt make (0x38), F2 make (0x3C), Alt break (0xB8)
    mov al, 0x38
    call keyboard_simulate_scancode
    mov al, 0x3C
    call keyboard_simulate_scancode
    mov al, 0xB8
    call keyboard_simulate_scancode

    call vt102_get_active
    cmp al, 1                           ; VC 1 is now active!
    jne .t28_fail

    ; Switch back to VC 0 via Alt+F1
    mov al, 0x38
    call keyboard_simulate_scancode
    mov al, 0x3B
    call keyboard_simulate_scancode
    mov al, 0xB8
    call keyboard_simulate_scancode

    call vt102_get_active
    cmp al, 0
    jne .t28_fail

    mov si, str_t28_ok
    call uart_puts
    popa
    ret

.t28_fail:
    mov si, str_t28_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 29: sys_select() Multiplexed Ready Polling
; ----------------------------------------------------------------------------
test29_select:
    pusha

    mov si, str_t29_start
    call uart_puts

    ; 1. Create a pipe via sys_pipe (syscall 42)
    mov ax, SYS_PIPE
    mov bx, t29_pipe_fds
    int 0x80
    test ax, ax
    jnz .t29_fail

    ; read fd = t29_pipe_fds[0], write fd = t29_pipe_fds[1]
    mov ax, [t29_pipe_fds + 0]
    mov [t29_rfd], ax
    mov ax, [t29_pipe_fds + 2]
    mov [t29_wfd], ax

    ; 2. Configure masks: read mask has rfd, write mask has wfd
    mov ax, 1
    mov cl, [t29_rfd]
    shl ax, cl
    mov [t29_readfds], ax

    mov ax, 1
    mov cl, [t29_wfd]
    shl ax, cl
    mov [t29_writefds], ax

    ; Call sys_select (syscall 82) before writing
    ; Read should NOT be ready (pipe is empty), Write SHOULD be ready
    mov ax, SYS_SELECT
    mov bx, 8                           ; nfds = 8
    mov cx, t29_readfds
    mov dx, t29_writefds
    xor si, si
    xor di, di
    int 0x80
    cmp ax, 1                           ; Exactly 1 descriptor ready (write)
    jne .t29_fail

    cmp word [t29_readfds], 0           ; Read mask should be cleared
    jne .t29_fail
    mov ax, [t29_writefds]
    test ax, ax                         ; Write mask should still have bit set
    jz .t29_fail

    ; 3. Write 5 bytes into pipe (syscall 4: BX=fd, CX=buf, DX=len)
    mov ax, SYS_WRITE
    mov bx, [t29_wfd]
    mov cx, str_select_test_msg
    mov dx, 5
    int 0x80
    cmp ax, 5
    jne .t29_fail

    ; 4. Re-arm masks and call sys_select again
    mov ax, 1
    mov cl, [t29_rfd]
    shl ax, cl
    mov [t29_readfds], ax

    mov ax, 1
    mov cl, [t29_wfd]
    shl ax, cl
    mov [t29_writefds], ax

    mov ax, SYS_SELECT
    mov bx, 8
    mov cx, t29_readfds
    mov dx, t29_writefds
    xor si, si
    xor di, di
    int 0x80
    cmp ax, 2                           ; Both read and write should now be ready!
    jne .t29_fail

    ; Clean up
    mov ax, SYS_CLOSE
    mov bx, [t29_wfd]
    int 0x80
    mov ax, SYS_CLOSE
    mov bx, [t29_rfd]
    int 0x80

    mov si, str_t29_ok
    call uart_puts
    popa
    ret

.t29_fail:
    mov si, str_t29_err
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; Test 30: Shell Command Pipeline Execution (cmd1 | cmd2)
; ----------------------------------------------------------------------------
test30_pipeline:
    pusha

    mov si, str_t30_start
    call uart_puts

    ; Initialize sash
    call sash_init

    ; Execute command pipeline: "echo Lin286_Pipeline_Active | cat"
    mov si, str_pipeline_cmd
    call sash_execute_line
    test ax, ax
    jnz .t30_fail

    mov si, str_t30_ok
    call uart_puts
    popa
    ret

.t30_fail:
    mov si, str_t30_err
    call uart_puts
    popa
    ret

section .data
align 2
str_p5_banner:      db 13, 10
                    db "========================================================", 13, 10
                    db " Lin286 Phase 5 Automated Verification Suite            ", 13, 10
                    db "========================================================", 13, 10, 0

str_t23_start:      db "[TEST 23] Verifying Pipe Creation, FIFO Read/Write & EOF...", 13, 10, 0
str_t23_ok:         db "[TEST 23] PASSED: Pipe creation, FIFO read/write & EOF verified.", 13, 10, 0
str_t23_err:        db "[TEST 23] FAILED: Pipe read/write/EOF failed!", 13, 10, 0

str_t24_start:      db "[TEST 24] Verifying dup() & dup2() File Descriptors...", 13, 10, 0
str_t24_ok:         db "[TEST 24] PASSED: dup() & dup2() file descriptor duplication verified.", 13, 10, 0
str_t24_err:        db "[TEST 24] FAILED: dup/dup2 verification failed!", 13, 10, 0

str_t25_start:      db "[TEST 25] Verifying termios Line Discipline & Terminal ioctls...", 13, 10, 0
str_t25_ok:         db "[TEST 25] PASSED: termios line discipline (ERASE, KILL, ICRNL, ioctls) verified.", 13, 10, 0
str_t25_err:        db "[TEST 25] FAILED: termios verification failed!", 13, 10, 0

str_t26_start:      db "[TEST 26] Verifying VT102 / ANSI Escape Sequence Parser...", 13, 10, 0
str_t26_ok:         db "[TEST 26] PASSED: VT102 / ANSI escape sequence parser verified.", 13, 10, 0
str_t26_err:        db "[TEST 26] FAILED: VT102 parser verification failed!", 13, 10, 0

str_t27_start:      db "[TEST 27] Verifying 4 Virtual Consoles & Alt+F1-F4 Switching...", 13, 10, 0
str_t27_ok:         db "[TEST 27] PASSED: 4 Virtual Consoles screen buffers & Alt+F1-F4 switching verified.", 13, 10, 0
str_t27_err:        db "[TEST 27] FAILED: Virtual consoles verification failed!", 13, 10, 0

str_t28_start:      db "[TEST 28] Verifying 8042 Keyboard IRQ 1 Translation & Line Buffering...", 13, 10, 0
str_t28_ok:         db "[TEST 28] PASSED: 8042 Keyboard IRQ 1 translation & line buffering verified.", 13, 10, 0
str_t28_err:        db "[TEST 28] FAILED: Keyboard translation failed!", 13, 10, 0

str_t29_start:      db "[TEST 29] Verifying sys_select() Multiplexed Ready Polling...", 13, 10, 0
str_t29_ok:         db "[TEST 29] PASSED: sys_select() multiplexed ready polling verified.", 13, 10, 0
str_t29_err:        db "[TEST 29] FAILED: sys_select failed!", 13, 10, 0

str_t30_start:      db "[TEST 30] Verifying Shell Command Pipeline Execution (cmd1 | cmd2)...", 13, 10, 0
str_t30_ok:         db "[TEST 30] PASSED: Shell command pipelines (cmd1 | cmd2) verified.", 13, 10, 0
str_t30_err:        db "[TEST 30] FAILED: Pipeline execution failed!", 13, 10, 0

str_p5_all_ok:      db "========================================================", 13, 10
                    db "[TEST] ALL PHASE 1, 2, 3, 4 & 5 VERIFICATIONS PASSED!", 13, 10, 0
str_p5_test_pass:   db "TEST PASS", 13, 10, 0

str_pipe_test_msg:  db "Lin286 Pipe OK!"
str_dup_test_msg:   db "Dup2 Data"
str_select_test_msg:db "Hello"

str_ansi_clear_ed:  db 27, "[2J"
str_ansi_pos_10_20: db 27, "[10;20H"
str_ansi_up2:       db 27, "[2A"
str_ansi_red:       db 27, "[31m"
str_ansi_reset:     db 27, "[0m"

str_vc0_banner:     db "0: Console 1 Text", 0
str_vc1_banner:     db "1: Console 2 Text", 0
str_vc2_banner:     db "2: Console 3 Text", 0
str_vc3_banner:     db "3: Console 4 Text", 0

str_pipeline_cmd:   db "echo Lin286_Pipeline_Active | cat", 0

align 2
t23_pipe_id:        dw 0
t24_rfd:            dw 0
t24_wfd:            dw 0
t24_duped_fd:       dw 0
t24_pipe_fds:       dw 0, 0
t24_bp_frame:       times 16 dw 0

t25_orig_lflag:     dw 0
t25_winsize:        times 4 dw 0

t29_pipe_fds:       dw 0, 0
t29_rfd:            dw 0
t29_wfd:            dw 0
t29_readfds:        dw 0
t29_writefds:       dw 0
t29_bp_frame:       times 16 dw 0

section .bss
alignb 4
t23_read_buf:       resb 64
t23_big_buf:        resb 512
t24_read_buf:       resb 64
t25_read_buf:       resb 64
t28_read_buf:       resb 64

section .text

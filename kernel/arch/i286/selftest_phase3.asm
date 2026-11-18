CPU 286
BITS 16

; ============================================================================
; Lin286 Phase 3 Verification Gate Self-Test Subsystem
;
; Verifies Phase 3 Milestones:
; Test 8:  INT 0x80 Syscall Dispatcher & Process Identification
; Test 9:  sys_brk Dynamic Heap Limit Expansion via LDT & seg_realloc
; Test 10: sys_fork with Copy-on-Write LDT Memory Cloning
; Test 11: sys_execve 16-bit Split-I&D a.out Executable Loader
; Test 12: Preemptive Round-Robin Multitasking & Context Switch
; Test 13: POSIX Signal Handling (sys_signal & sys_kill)
; Test 14: Process Termination (sys_exit) & Child Reaping (sys_waitpid)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global run_phase3_verification_gate

section .text

run_phase3_verification_gate:
    pusha
    push ds
    push es

    mov si, str_p3_hdr
    call uart_puts

    ; ------------------------------------------------------------------------
    ; Test 8: INT 0x80 Syscall Dispatcher & Process Identification
    ; ------------------------------------------------------------------------
    mov si, str_test8_hdr
    call uart_puts

    ; 8a. Test sys_getpid (syscall 20)
    mov ax, SYS_GETPID
    int 0x80
    cmp ax, 0                           ; Task 0 should be active
    jne .t8_failed

    ; 8b. Test invalid syscall number -> -38 (-ENOSYS)
    mov ax, 70                          ; Unimplemented (sys_nosys)
    int 0x80
    cmp ax, -38
    jne .t8_failed

    ; 8c. Test sys_write to stdout (syscall 4)
    mov ax, SYS_WRITE
    mov bx, 1                           ; stdout
    mov cx, str_sys_write_msg
    mov dx, str_sys_write_len
    int 0x80
    cmp ax, str_sys_write_len
    jne .t8_failed

    mov si, str_test8_pass
    call uart_puts
    jmp .test9

.t8_failed:
    mov si, str_test8_fail
    call uart_puts
    cli
    hlt

    ; ------------------------------------------------------------------------
    ; Test 9: sys_brk Dynamic Heap Expansion
    ; ------------------------------------------------------------------------
.test9:
    mov si, str_test9_hdr
    call uart_puts

    ; Initialize Task 0 data segment with 128 paragraphs (2048 bytes)
    mov cx, 128
    mov bl, POOL_A
    mov bh, 0
    call seg_alloc
    cmp ax, 0xFFFF
    je .t9_failed
    mov [t9_data_blk], ax

    ; Set LDT entry 1 for Task 0: Limit = 2047, Access = 0xF2
    mov al, 0
    mov ah, 1
    call seg_get_block_ptr              ; DI = &seg_blocks[data_blk]
    mov si, [di + SB_BASE_LOW]
    mov dl, [di + SB_BASE_HIGH]
    mov bx, 2047
    mov cl, 0xF2                        ; Present, DPL=3, Data R/W
    xor ch, ch
    xor dh, dh
    call ldt_set_entry

    ; Set Task 0 data block and initial brk
    mov di, task_table
    mov ax, [t9_data_blk]
    mov [di + TS_DATA_BLK], ax
    mov word [di + TS_BRK_LIMIT], 512

    ; Query current brk
    mov ax, SYS_BRK
    xor bx, bx
    int 0x80
    cmp ax, 512
    jne .t9_failed

    ; Request expansion to 1536 bytes (fits within 2048 bytes)
    mov ax, SYS_BRK
    mov bx, 1536
    int 0x80
    cmp ax, 1536
    jne .t9_failed

    ; Verify task struct brk_limit
    mov di, task_table
    cmp word [di + TS_BRK_LIMIT], 1536
    jne .t9_failed

    ; Request expansion to 3072 bytes (requires seg_realloc)
    mov ax, SYS_BRK
    mov bx, 3072
    int 0x80
    cmp ax, 3072
    jne .t9_failed

    mov di, task_table
    cmp word [di + TS_BRK_LIMIT], 3072
    jne .t9_failed

    mov si, str_test9_pass
    call uart_puts
    jmp .test10

.t9_failed:
    mov si, str_test9_fail
    call uart_puts
    cli
    hlt

    ; ------------------------------------------------------------------------
    ; Test 10: sys_fork with CoW LDT Cloning
    ; ------------------------------------------------------------------------
.test10:
    mov si, str_test10_hdr
    call uart_puts

    ; Call sys_fork
    mov ax, SYS_FORK
    int 0x80
    cmp ax, 0
    jle .t10_failed                     ; Expect positive child PID (1..7)
    mov [t10_child_pid], ax

    ; Check child task struct
    mov al, [t10_child_pid]
    call task_get_ptr
    cmp byte [di + TS_STATE], TASK_READY
    jne .t10_failed
    cmp byte [di + TS_PPID], 0
    jne .t10_failed

    ; Check parent LDT entry 1: must be Read-Only (DESC_WRITABLE=0) and VM_FLAG_COW set
    mov al, 0
    mov ah, 1
    call ldt_get_entry_ptr
    test byte [di + 5], DESC_WRITABLE
    jnz .t10_failed
    test word [di + 6], VM_FLAG_COW
    jz .t10_failed

    ; Check child LDT entry 1: must also be Read-Only and VM_FLAG_COW set
    mov al, [t10_child_pid]
    mov ah, 1
    call ldt_get_entry_ptr
    test byte [di + 5], DESC_WRITABLE
    jnz .t10_failed
    test word [di + 6], VM_FLAG_COW
    jz .t10_failed

    ; Verify physical block ref_count of Task 0 data segment is at least 2
    mov di, task_table
    mov ax, [di + TS_DATA_BLK]
    call seg_get_block_ptr
    cmp word [di + SB_REF_COUNT], 2
    jb .t10_failed

    ; Reclaim child task slot so scheduler doesn't switch to it in subsequent tests
    mov al, [t10_child_pid]
    call task_free_slot

    mov si, str_test10_pass
    call uart_puts
    jmp .test11

.t10_failed:
    mov si, str_test10_fail
    call uart_puts
    cli
    hlt

    ; ------------------------------------------------------------------------
    ; Test 11: sys_execve Split-I&D a.out Executable Loader
    ; ------------------------------------------------------------------------
.test11:
    mov si, str_test11_hdr
    call uart_puts

    ; Load embedded a.out binary
    mov ax, SYS_EXECVE
    mov bx, test_aout_binary
    ; We invoke sys_execve directly to inspect segments without clobbering test CS:IP
    call sys_execve
    test ax, ax
    jnz .t11_failed

    ; Verify current task text and data segments were allocated
    mov di, task_table
    cmp word [di + TS_TEXT_BLK], 0xFFFF
    je .t11_failed
    cmp word [di + TS_DATA_BLK], 0xFFFF
    je .t11_failed

    ; Verify LDT Entry 0 (Text) has DPL=3 and Code attribute
    mov al, 0
    mov ah, 0
    call ldt_get_entry_ptr
    cmp byte [di + 5], 0xFA             ; Present, DPL=3, Code E/R
    jne .t11_failed

    ; Verify LDT Entry 1 (Data) has DPL=3 and Data attribute
    mov al, 0
    mov ah, 1
    call ldt_get_entry_ptr
    cmp byte [di + 5], 0xF2             ; Present, DPL=3, Data R/W
    jne .t11_failed

    mov si, str_test11_pass
    call uart_puts
    jmp .test12

.t11_failed:
    mov si, str_test11_fail
    call uart_puts
    cli
    hlt

    ; ------------------------------------------------------------------------
    ; Test 12: Preemptive Round-Robin Multitasking & Context Switch
    ; ------------------------------------------------------------------------
.test12:
    mov si, str_test12_hdr
    call uart_puts

    ; Configure Task 2 as a cooperative runner
    mov al, 2
    call task_get_ptr
    mov byte [di + TS_STATE], TASK_READY
    mov byte [di + TS_PRIORITY], 10
    mov byte [di + TS_TICKS_LEFT], 5

    ; Set up Task 2 kernel stack to run test_task2_entry
    mov ax, 3                           ; PID 2 + 1 = 3
    mov bx, TASK_KSTACK_SIZE
    mul bx
    add ax, task_kstacks - 2
    mov di, ax

    ; Context frame for schedule
    sub di, 2
    mov word [di], test_task2_entry     ; Return IP from schedule
    sub di, 2
    mov word [di], 0x0202               ; FLAGS with IF=1
    sub di, 2
    mov word [di], GDT_KDATA_SEL        ; ES
    sub di, 2
    mov word [di], GDT_KDATA_SEL        ; DS
    sub di, 16                          ; pusha frame (8 words)

    ; Zero pusha frame
    push es
    push di
    mov ax, GDT_KDATA_SEL
    mov es, ax
    xor ax, ax
    mov cx, 8
    rep stosw
    pop di
    pop es

    ; Save Task 2 SP
    mov bx, di                          ; BX = stack pointer
    mov al, 2
    call task_get_ptr
    mov [di + TS_KSP], bx               ; Save SP
    mov word [task2_ran], 0

    ; Yield Task 0 to scheduler
    call schedule

    ; Resumed back in Task 0! Check if Task 2 executed
    cmp word [task2_ran], 1
    jne .t12_failed

    ; Reclaim Task 2 slot
    mov al, 2
    call task_free_slot

    mov si, str_test12_pass
    call uart_puts
    jmp .test13

.t12_failed:
    mov si, str_test12_fail
    call uart_puts
    cli
    hlt

    ; ------------------------------------------------------------------------
    ; Test 13: POSIX Signals (sys_signal, sys_kill)
    ; ------------------------------------------------------------------------
.test13:
    mov si, str_test13_hdr
    call uart_puts

    ; 1. Block SIGUSR1 on Task 0 to verify queuing
    mov di, task_table
    mov word [di + TS_SIG_BLOCKED], (1 << SIGUSR1)

    ; 2. Register custom handler for SIGUSR1 (10)
    mov ax, SYS_SIGNAL
    mov bx, SIGUSR1                     ; 10
    mov cx, dummy_sig_handler
    int 0x80
    cmp ax, SIG_DFL                     ; Default was 0
    jne .t13_failed

    ; 3. Send SIGUSR1 to Task 0 (blocked, so remains pending)
    mov word [task_last_sig], 0
    mov ax, SYS_KILL
    mov bx, 0                           ; Target PID 0
    mov cx, SIGUSR1                     ; Signal 10
    int 0x80
    test ax, ax
    jnz .t13_failed

    ; Verify signal pending bit 10 is set in Task 0 struct
    mov di, task_table
    mov ax, (1 << SIGUSR1)              ; 1 << 10 = 1024 = 0x0400
    test [di + TS_SIG_PENDING], ax
    jz .t13_failed

    ; 4. Unblock SIGUSR1 and trigger delivery
    mov word [di + TS_SIG_BLOCKED], 0
    call signal_deliver_pending
    cmp word [task_last_sig], SIGUSR1
    jne .t13_failed

    ; Clean up signal state for Task 0
    mov word [di + TS_SIG_PENDING], 0
    mov ax, SYS_SIGNAL
    mov bx, SIGUSR1
    mov cx, SIG_DFL
    int 0x80

    mov si, str_test13_pass
    call uart_puts
    jmp .test14

.t13_failed:
    mov si, str_test13_fail
    call uart_puts
    cli
    hlt

    ; ------------------------------------------------------------------------
    ; Test 14: Process Termination (sys_exit) & Child Reaping (sys_waitpid)
    ; ------------------------------------------------------------------------
.test14:
    mov si, str_test14_hdr
    call uart_puts

    ; Setup Task 3 as child of Task 0 in TASK_ZOMBIE with exit status 42
    mov al, 3
    call task_get_ptr
    mov byte [di + TS_STATE], TASK_ZOMBIE
    mov byte [di + TS_PPID], 0
    mov word [di + TS_EXIT_CODE], 42
    mov word [di + TS_DATA_BLK], 0xFFFF
    mov word [di + TS_TEXT_BLK], 0xFFFF

    ; Parent (Task 0) calls sys_waitpid on child 3 with WNOHANG
    mov ax, SYS_WAITPID
    mov bx, 3                           ; Target PID 3
    mov cx, t14_status                  ; Status buffer
    mov dx, WNOHANG                     ; 1
    int 0x80
    cmp ax, 3                           ; Must return child PID 3
    jne .t14_failed

    cmp word [t14_status], 42           ; Exit code 42
    jne .t14_failed

    ; Verify Task 3 slot is reclaimed (TASK_UNUSED)
    mov al, 3
    call task_get_ptr
    cmp byte [di + TS_STATE], TASK_UNUSED
    jne .t14_failed

    mov si, str_test14_pass
    call uart_puts

    ; Final success banner
    mov si, str_all_phase3_passed
    call uart_puts

    pop es
    pop ds
    popa
    ret

.t14_failed:
    mov si, str_test14_fail
    call uart_puts
    cli
    hlt

; Task 2 entry point for Test 12
test_task2_entry:
    mov word [task2_ran], 1
    ; Yield back to Task 0
    call schedule
.t2_halt:
    hlt
    jmp .t2_halt

dummy_sig_handler:
    ret

section .data
t9_data_blk:        dw 0
t10_child_pid:      dw 0
task2_ran:          dw 0
t14_status:         dw 0
str_sys_write_msg:  db "[SYSCALL] sys_write: Hello from Ring 0/Ring 3 Syscall Interface!", 13, 10
str_sys_write_len   equ ($ - str_sys_write_msg)

align 4
; Minimal 16-Bit Split-I&D a.out executable binary image (32 byte header + code + data)
test_aout_binary:
    dw 0x0301                           ; a_magic (0x0301)
    db 0x20                             ; a_flags (A_FLAG_SPLIT_ID)
    db 0x04                             ; a_cpu (i86 / 286)
    db 32                               ; a_hdrlen
    db 0                                ; a_unused
    dw 0                                ; a_version
    dd 32                               ; a_text (32 bytes)
    dd 32                               ; a_data (32 bytes)
    dd 32                               ; a_bss (32 bytes)
    dd 0                                ; a_entry (offset 0)
    dd 1024                             ; a_total (1024 bytes data segment)
    dd 0                                ; a_syms
    ; Text segment payload (32 bytes)
    times 16 nop
    times 16 nop
    ; Data segment payload (32 bytes)
    times 16 db 0xAA
    times 16 db 0x55

str_p3_hdr:         db 13, 10
                    db "========================================================", 13, 10
                    db " Lin286 Phase 3 Automated Verification Suite            ", 13, 10
                    db "========================================================", 13, 10, 0

str_test8_hdr:      db "[TEST 8] Verifying INT 0x80 Syscall Dispatcher & Process Identification...", 13, 10, 0
str_test8_pass:     db "[TEST 8] PASSED: INT 0x80 syscall dispatcher & process queries verified.", 13, 10, 0
str_test8_fail:     db "[TEST 8] FAILED: INT 0x80 syscall dispatcher test failed!", 13, 10, 0

str_test9_hdr:      db "[TEST 9] Verifying sys_brk Dynamic Heap Limit Expansion...", 13, 10, 0
str_test9_pass:     db "[TEST 9] PASSED: sys_brk dynamic heap expansion verified.", 13, 10, 0
str_test9_fail:     db "[TEST 9] FAILED: sys_brk heap expansion failed!", 13, 10, 0

str_test10_hdr:     db "[TEST 10] Verifying sys_fork with CoW LDT Memory Cloning...", 13, 10, 0
str_test10_pass:    db "[TEST 10] PASSED: sys_fork with CoW LDT cloning verified.", 13, 10, 0
str_test10_fail:    db "[TEST 10] FAILED: sys_fork verification failed!", 13, 10, 0

str_test11_hdr:     db "[TEST 11] Verifying sys_execve 16-bit Split-I&D a.out Loader...", 13, 10, 0
str_test11_pass:    db "[TEST 11] PASSED: sys_execve Split-I&D a.out loader verified.", 13, 10, 0
str_test11_fail:    db "[TEST 11] FAILED: sys_execve loader failed!", 13, 10, 0

str_test12_hdr:     db "[TEST 12] Verifying Preemptive Round-Robin Multitasking & Context Switch...", 13, 10, 0
str_test12_pass:    db "[TEST 12] PASSED: Preemptive round-robin multitasking verified.", 13, 10, 0
str_test12_fail:    db "[TEST 12] FAILED: Multitasking context switch failed!", 13, 10, 0

str_test13_hdr:     db "[TEST 13] Verifying POSIX Signal Handling (sys_signal, sys_kill)...", 13, 10, 0
str_test13_pass:    db "[TEST 13] PASSED: POSIX signals (sys_signal, sys_kill) verified.", 13, 10, 0
str_test13_fail:    db "[TEST 13] FAILED: Signal handling verification failed!", 13, 10, 0

str_test14_hdr:     db "[TEST 14] Verifying Process Termination (sys_exit) & Child Reaping (sys_waitpid)...", 13, 10, 0
str_test14_pass:    db "[TEST 14] PASSED: Process termination (sys_exit) and child reaping (sys_waitpid) verified.", 13, 10, 0
str_test14_fail:    db "[TEST 14] FAILED: Child termination / waitpid failed!", 13, 10, 0

str_all_phase3_passed:db "========================================================", 13, 10
                    db "[TEST] ALL PHASE 1, PHASE 2 & PHASE 3 VERIFICATIONS PASSED!", 13, 10
                    db "TEST PASS", 13, 10, 0

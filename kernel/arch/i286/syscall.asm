CPU 286
BITS 16

; ============================================================================
; Lin286 System Call Dispatcher (INT 0x80 ABI)
;
; Provides the Ring 3 -> Ring 0 system call interface matching Linux-16 / ELKS.
; Trap Gate IDT vector 0x80 is configured with DPL = 3.
;
; Register ABI:
;   AX: Syscall Number
;   BX: Argument 1
;   CX: Argument 2
;   DX: Argument 3
;   SI: Argument 4
;   DI: Argument 5
; Return value:
;   AX: Syscall result (negative error code on failure)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global syscall_init
global syscall_entry
global sys_call_table
global sys_nosys
global sys_write
global sys_read
global signal_deliver_pending

section .text

; ----------------------------------------------------------------------------
; syscall_init: Verify / initialize syscall subsystem
; ----------------------------------------------------------------------------
syscall_init:
    push si
    mov si, str_syscall_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; syscall_entry: Hardware Trap Gate entry point for INT 0x80
; ----------------------------------------------------------------------------
syscall_entry:
    push ds
    push es
    push bp
    push di
    push si
    push dx
    push cx
    push bx

    mov bp, sp                          ; BP points to saved register frame

    ; Switch to Kernel Data Segment
    mov dx, GDT_KDATA_SEL
    mov ds, dx
    mov es, dx

    ; Validate syscall number in AX
    cmp ax, MAX_SYSCALLS
    jae .bad_call

    ; Look up handler in sys_call_table
    mov bx, ax
    shl bx, 1
    mov bx, [sys_call_table + bx]
    test bx, bx
    jz .bad_call
    mov [syscall_handler], bx

    ; Restore argument registers from stack frame:
    ; [bp + 0] = BX
    ; [bp + 2] = CX
    ; [bp + 4] = DX
    ; [bp + 6] = SI
    ; [bp + 8] = DI
    mov bx, [bp + 0]
    mov cx, [bp + 2]
    mov dx, [bp + 4]
    mov si, [bp + 6]
    mov di, [bp + 8]

    ; Call syscall handler
    call [syscall_handler]
    ; Handler returns result in AX

.dispatch_done:
    ; Check and deliver any pending unblocked signals before returning
    push ax
    call signal_deliver_pending
    pop ax

    ; Restore registers (AX preserved as return value)
    pop bx
    pop cx
    pop dx
    pop si
    pop di
    pop bp
    pop es
    pop ds
    iret

.bad_call:
    mov ax, -38                         ; -ENOSYS
    jmp .dispatch_done

; ----------------------------------------------------------------------------
; sys_nosys: Default handler for unimplemented system calls
; ----------------------------------------------------------------------------
sys_nosys:
    mov ax, -38                         ; -ENOSYS
    ret

; ----------------------------------------------------------------------------
; sys_write: Write to file descriptor
;   BX = fd (1=stdout, 2=stderr)
;   CX = buffer offset in caller's DS
;   DX = byte count
; ----------------------------------------------------------------------------
sys_write:
    cmp bx, 1
    je .do_write
    cmp bx, 2
    je .do_write
    mov ax, -9                          ; -EBADF
    ret

.do_write:
    test dx, dx
    jz .write_zero

    push es
    push si
    push cx
    push dx

    ; Load caller's DS from saved stack frame [bp + 14]
    mov ax, [bp + 14]
    mov es, ax
    mov si, cx                          ; ES:SI = caller buffer

    mov cx, dx                          ; byte count

.write_loop:
    mov al, [es:si]
    inc si
    push cx
    call uart_putc
    call console_putc
    pop cx
    loop .write_loop

    pop dx
    pop cx
    pop si
    pop es
    mov ax, dx                          ; Return bytes written
    ret

.write_zero:
    xor ax, ax
    ret

; ----------------------------------------------------------------------------
; sys_read: Read from file descriptor (stdin stub)
; ----------------------------------------------------------------------------
sys_read:
    cmp bx, 0
    jne .bad_read_fd
    xor ax, ax                          ; Return 0 (EOF)
    ret
.bad_read_fd:
    mov ax, -9                          ; -EBADF
    ret

; ----------------------------------------------------------------------------
; signal_deliver_pending: Check and dispatch pending unblocked signals
; ----------------------------------------------------------------------------
signal_deliver_pending:
    push bp
    mov bp, sp
    ; Caller frame BP was pushed; stack is:
    ; [bp + 0] = old bp
    ; [bp + 2] = return address to syscall_entry
    ; [bp + 4] = saved AX
    ; [bp + 6] = saved BX
    ; ...
    ; We can read BP from the original syscall frame:
    ; [bp + 2] is return addr, [bp + 4] is pushed AX, and [bp + 6] begins syscall frame.
    ; But easier: [current_task] gives task struct!

    pusha
    push ds
    push es

    mov ax, GDT_KDATA_SEL
    mov ds, ax
    mov es, ax

    mov al, [current_task]
    call task_get_ptr                   ; DI = &task_table[current_task]

    ; Check pending unblocked signals: sig_pending & ~sig_blocked
    mov ax, [di + TS_SIG_PENDING]
    mov bx, [di + TS_SIG_BLOCKED]
    not bx
    and ax, bx
    jz .sig_return                      ; No pending unblocked signals

    ; Find lowest pending signal (bits 1 .. 15)
    mov cx, 1                           ; Signal 1 to 15
    mov bx, 2                           ; Bitmask for signal 1: (1 << 1) = 2

.scan_sig:
    test ax, bx
    jnz .sig_found
    inc cx
    shl bx, 1
    cmp cx, 16
    jb .scan_sig
    jmp .sig_return

.sig_found:
    ; Clear pending bit in task_struct
    not bx
    and [di + TS_SIG_PENDING], bx

    ; Fetch handler address for signal CX
    mov bx, cx
    shl bx, 1                           ; Word index
    add bx, TS_SIG_HANDLERS
    add bx, di                          ; BX = &task.sig_handlers[cx]
    mov dx, [bx]                        ; DX = handler offset

    ; Check if SIG_IGN
    cmp dx, SIG_IGN
    je .sig_return

    ; Check if SIG_DFL
    cmp dx, SIG_DFL
    jne .custom_handler

    ; Default action for terminating signals: SIGINT, SIGKILL, SIGSEGV, SIGTERM
    cmp cx, SIGINT
    je .do_terminate
    cmp cx, SIGKILL
    je .do_terminate
    cmp cx, SIGSEGV
    je .do_terminate
    cmp cx, SIGTERM
    je .do_terminate
    jmp .sig_return

.do_terminate:
    mov bx, cx
    call sys_exit                       ; Process termination
    jmp .sig_return

.custom_handler:
    ; If returning to user mode, redirect user IP to custom handler
    ; We need to access the syscall stack frame.
    ; In syscall_entry, BP pointed to the saved frame.
    ; If the caller was Ring 3, [bp + 18] has RPL_RING3.
    ; For now, if custom handler is set, store in task_last_sig
    mov [task_last_sig], cx

.sig_return:
    pop es
    pop ds
    popa
    pop bp
    ret

section .data
align 2
syscall_handler:dw 0
task_last_sig:  dw 0
str_syscall_ok: db "[SYSCALL] INT 0x80 Ring 3 trap gate (DPL=3) installed", 13, 10, 0

align 2
sys_call_table:
    dw sys_nosys                        ; 0: sys_setup / unused
    dw sys_exit                         ; 1: sys_exit
    dw sys_fork                         ; 2: sys_fork
    dw sys_read                         ; 3: sys_read
    dw sys_write                        ; 4: sys_write
    dw sys_nosys                        ; 5: sys_open (placeholder)
    dw sys_nosys                        ; 6: sys_close (placeholder)
    dw sys_waitpid                      ; 7: sys_waitpid
    times 3 dw sys_nosys                ; 8..10
    dw sys_execve                       ; 11: sys_execve
    times 5 dw sys_nosys                ; 12..16
    dw sys_brk                          ; 17: sys_brk
    times 2 dw sys_nosys                ; 18..19
    dw sys_getpid                       ; 20: sys_getpid
    times 16 dw sys_nosys               ; 21..36
    dw sys_kill                         ; 37: sys_kill
    times 10 dw sys_nosys               ; 38..47
    dw sys_signal                       ; 48: sys_signal
    times 15 dw sys_nosys               ; 49..63
    dw sys_getppid                      ; 64: sys_getppid

CPU 286
BITS 16

; ============================================================================
; Lin286 Process Lifecycle & POSIX System Calls
;
; Implements core process lifecycle syscalls:
; - sys_getpid (20) & sys_getppid (64)
; - sys_fork (2) with LDT Copy-on-Write cloning & child stack setup
; - sys_execve (11) 16-bit Split-I&D a.out executable loader
; - sys_brk (17) dynamic heap limit expansion via seg_realloc
; - sys_exit (1) & sys_waitpid (7) process termination and child reclamation
; - sys_kill (37) & sys_signal (48) POSIX signal dispatch
; ============================================================================

%include "kernel/include/i286_asm.inc"

global sys_getpid
global sys_getppid
global sys_brk
global sys_fork
global sys_execve
global sys_exit
global sys_waitpid
global sys_kill
global sys_signal
global fork_child_trampoline

section .text

; ----------------------------------------------------------------------------
; sys_getpid: Return current process ID
; ----------------------------------------------------------------------------
sys_getpid:
    mov al, [current_task]
    xor ah, ah
    ret

; ----------------------------------------------------------------------------
; sys_getppid: Return parent process ID
; ----------------------------------------------------------------------------
sys_getppid:
    mov al, [current_task]
    call task_get_ptr
    mov al, [di + TS_PPID]
    xor ah, ah
    ret

; ----------------------------------------------------------------------------
; sys_brk: Set process heap break limit
;   BX = Requested new break limit offset in user DS
; ----------------------------------------------------------------------------
sys_brk:
    push si
    push di
    push bp

    mov si, bx                          ; SI = requested brk

    ; Get current task struct
    mov al, [current_task]
    call task_get_ptr
    mov bp, di                          ; BP = &task_table[current_task]

    ; If requested brk == 0, query current limit
    test si, si
    jz .brk_query

    ; Reject break above 0xFF00
    cmp si, 0xFF00
    ja .brk_query

    mov ax, [bp + TS_BRK_LIMIT]
    cmp si, ax
    jbe .brk_shrink

    ; Growth requested: check if fits in current physical segment capacity
    mov bx, [bp + TS_DATA_BLK]
    cmp bx, 0xFFFF
    je .brk_query
    call seg_get_block_ptr              ; DI = &seg_blocks[data_blk]
    mov ax, [di + SB_SIZE_PARAS]
    shl ax, 4                           ; AX = capacity in bytes

    cmp si, ax
    jbe .brk_fits

    ; Needs segment reallocation
    mov [saved_req_brk], si
    mov bx, si
    add bx, 15
    shr bx, 4                           ; BX = needed_paras
    mov ax, [bp + TS_DATA_BLK]
    call seg_realloc
    cmp ax, 0xFFFF
    je .brk_nomem

    ; Update task's data block
    mov [bp + TS_DATA_BLK], ax

    ; Update LDT entry 1 descriptor with new base and limit
    push dx
    push si
    mov al, [current_task]
    mov ah, 1                           ; Entry 1 = User Data
    call ldt_get_entry_ptr              ; DI = &LDT[entry 1]
    pop si                              ; SI = physical base low
    pop dx                              ; DL = physical base high

    mov bx, [saved_req_brk]
    mov [di + 0], bx                    ; Update limit
    mov [di + 2], si                    ; Update physical base low
    mov [di + 4], dl                    ; Update physical base high

    mov [bp + TS_BRK_LIMIT], bx
    mov ax, bx
    jmp .brk_ret

.brk_fits:
    ; Fits in current block: simply update LDT limit
    mov al, [current_task]
    mov ah, 1
    call ldt_get_entry_ptr
    mov [di + 0], si
    mov [bp + TS_BRK_LIMIT], si
    mov ax, si
    jmp .brk_ret

.brk_shrink:
    ; Shrinking break limit
    mov al, [current_task]
    mov ah, 1
    call ldt_get_entry_ptr
    mov [di + 0], si
    mov [bp + TS_BRK_LIMIT], si
    mov ax, si
    jmp .brk_ret

.brk_query:
    mov ax, [bp + TS_BRK_LIMIT]
    jmp .brk_ret

.brk_nomem:
    mov ax, -12                         ; -ENOMEM

.brk_ret:
    pop bp
    pop di
    pop si
    ret

; ----------------------------------------------------------------------------
; sys_fork: Duplicate parent process with Copy-on-Write LDT memory
; ----------------------------------------------------------------------------
sys_fork:
    push si
    push di
    push bp

    ; 1. Allocate a free task slot for the child
    call task_alloc_slot
    cmp al, 0xFF
    jne .slot_ok
    mov ax, -11                         ; -EAGAIN
    pop bp
    pop di
    pop si
    ret

.slot_ok:
    mov [child_pid], al                 ; Save child PID

    ; Fetch parent task pointer
    mov al, [current_task]
    call task_get_ptr
    mov si, di                          ; SI = &parent task_struct

    ; Fetch child task pointer
    mov al, [child_pid]
    call task_get_ptr                   ; DI = &child task_struct
    mov [child_task_ptr], di

    ; 2. Initialize child metadata from parent
    mov al, [si + TS_PID]
    mov [di + TS_PPID], al              ; child.ppid = parent.pid
    mov al, [si + TS_PRIORITY]
    mov [di + TS_PRIORITY], al
    mov byte [di + TS_TICKS_LEFT], 5
    mov ax, [si + TS_BRK_LIMIT]
    mov [di + TS_BRK_LIMIT], ax
    mov ax, [si + TS_TEXT_BLK]
    mov [di + TS_TEXT_BLK], ax
    mov ax, [si + TS_DATA_BLK]
    mov [di + TS_DATA_BLK], ax

    ; Copy signal handlers and blocked mask
    mov ax, [si + TS_SIG_BLOCKED]
    mov [di + TS_SIG_BLOCKED], ax
    mov word [di + TS_SIG_PENDING], 0

    push si
    push di
    add si, TS_SIG_HANDLERS
    add di, TS_SIG_HANDLERS
    mov cx, 16
    rep movsw
    pop di
    pop si

    ; 3. Clone LDT Segments
    ; Text segment (LDT entry 0): Shared Read-Only
    mov ax, [si + TS_TEXT_BLK]
    cmp ax, 0xFFFF
    je .no_text_blk
    call seg_get_block_ptr              ; DI = &seg_blocks[text_blk]
    inc word [di + SB_REF_COUNT]        ; Increment text ref_count
.no_text_blk:

    ; Copy parent LDT entry 0 to child LDT entry 0 (8 bytes)
    mov al, [current_task]
    mov ah, 0
    call ldt_get_entry_ptr
    mov bx, di                          ; BX = parent LDT entry 0

    mov al, [child_pid]
    mov ah, 0
    call ldt_get_entry_ptr              ; DI = child LDT entry 0

    push si
    mov si, bx
    mov cx, 4
    rep movsw
    pop si

    ; Data segment (LDT entry 1): Copy-on-Write (CoW)
    mov ax, [si + TS_DATA_BLK]
    cmp ax, 0xFFFF
    je .no_data_blk
    call seg_get_block_ptr              ; DI = &seg_blocks[data_blk]
    inc word [di + SB_REF_COUNT]        ; Increment data ref_count
.no_data_blk:

    ; Mark parent LDT entry 1 as Read-Only and set VM_FLAG_COW
    mov al, [current_task]
    mov ah, 1
    call ldt_get_entry_ptr              ; DI = parent LDT entry 1
    and byte [di + 5], ~DESC_WRITABLE   ; Read-Only
    or word [di + 6], VM_FLAG_COW       ; CoW enabled

    ; Copy parent LDT entry 1 to child LDT entry 1
    mov bx, di                          ; BX = parent LDT entry 1
    mov al, [child_pid]
    mov ah, 1
    call ldt_get_entry_ptr              ; DI = child LDT entry 1

    push si
    mov si, bx
    mov cx, 4
    rep movsw
    pop si

    ; 4. Setup Child's Kernel Stack
    ; Calculate child's stack top: task_kstacks + (child_pid + 1) * 512 - 2
    mov al, [child_pid]
    xor ah, ah
    inc ax
    mov bx, TASK_KSTACK_SIZE
    mul bx
    add ax, task_kstacks - 2
    mov di, ax                          ; DI = top of child kernel stack

    ; Build child stack frame from top down
    ; 1. Hardware IRET frame (user SS, user SP, user FLAGS, user CS, user IP)
    sub di, 2
    mov ax, [bp + 24]
    mov [di], ax                        ; user SS

    sub di, 2
    mov ax, [bp + 22]
    mov [di], ax                        ; user SP

    sub di, 2
    mov ax, [bp + 20]
    mov [di], ax                        ; user FLAGS

    sub di, 2
    mov ax, [bp + 18]
    mov [di], ax                        ; user CS

    sub di, 2
    mov ax, [bp + 16]
    mov [di], ax                        ; user IP

    ; 2. Trampoline return address for schedule's RET instruction
    sub di, 2
    mov word [di], fork_child_trampoline

    ; 3. Flags for schedule's POPF
    sub di, 2
    mov word [di], 0x0202               ; FLAGS with IF=1

    ; 4. Segment registers for schedule's POP DS and POP ES
    sub di, 2
    mov word [di], LDT_UDATA_SEL        ; DS = 0x000F

    sub di, 2
    mov word [di], LDT_UDATA_SEL        ; ES = 0x000F

    ; 5. General registers for schedule's POPA (8 words = 16 bytes)
    ; Registers popped: DI, SI, BP, SP, BX, DX, CX, AX
    sub di, 16
    mov word [di + 0],  0               ; DI
    mov word [di + 2],  0               ; SI
    mov word [di + 4],  0               ; BP
    mov word [di + 6],  0               ; SP
    mov word [di + 8],  0               ; BX
    mov word [di + 10], 0               ; DX
    mov word [di + 12], 0               ; CX
    mov word [di + 14], 0               ; AX = 0 (Child fork return value!)

    ; Save child's SP in child task_struct
    mov bx, [child_task_ptr]
    mov [bx + TS_KSP], di               ; Save stack pointer

    ; Clone open file descriptors from parent to child
    mov al, [current_task]
    mov bl, [child_pid]
    call vfs_clone_task_fds

    ; 5. Mark Child as TASK_READY
    mov bx, [child_task_ptr]
    mov byte [bx + TS_STATE], TASK_READY

    ; Return child PID in AX to parent
    mov al, [child_pid]
    xor ah, ah

    pop bp
    pop di
    pop si
    ret

; ----------------------------------------------------------------------------
; fork_child_trampoline: Child entry point on first context switch
; ----------------------------------------------------------------------------
fork_child_trampoline:
    iret                                ; Returns directly to Ring 3 with AX = 0!

; ----------------------------------------------------------------------------
; sys_execve: Load and execute a 16-bit Split-I&D a.out binary
;   BX = Pointer to a.out binary in memory (or image buffer)
; ----------------------------------------------------------------------------
sys_execve:
    push si
    push di
    push bp

    mov si, bx                          ; SI = pointer to a.out image
    mov [image_ptr], bx

    ; 1. Validate a.out header
    cmp word [si + 0], A_MAGIC          ; Magic 0x0301
    jne .exec_noexec
    test byte [si + 2], A_FLAG_SPLIT_ID ; Split-I&D flag (0x20)
    jz .exec_noexec

    ; 2. Read sizes from header
    mov ax, [si + 8]                    ; AX = a_text size
    mov cx, [si + 12]                   ; CX = a_data size
    mov dx, [si + 16]                   ; DX = a_bss size
    mov bp, [si + 20]                   ; BP = a_entry IP
    mov bx, [si + 24]                   ; BX = a_total size

    test bx, bx
    jnz .total_valid
    mov bx, cx
    add bx, dx
    add bx, 2048                        ; Default 2 KB stack if total=0
.total_valid:
    mov [exec_total], bx
    mov [exec_text_sz], ax
    mov [exec_data_sz], cx
    mov [exec_bss_sz], dx
    mov [exec_entry_ip], bp

    ; 3. Allocate physical segment for Text
    mov cx, ax
    add cx, 15
    shr cx, 4                           ; Paras for text in CX
    mov bl, POOL_A                      ; Preferred pool in BL
    mov bh, [current_task]              ; Owner PID in BH
    call seg_alloc
    cmp ax, 0xFFFF
    je .exec_nomem
    mov [exec_new_text_blk], ax
    call seg_get_block_ptr              ; DI = &seg_blocks[text_blk]
    mov si, [di + SB_BASE_LOW]
    mov dl, [di + SB_BASE_HIGH]
    mov [exec_text_phys_low], si
    mov [exec_text_phys_high], dl

    ; Copy text segment bytes from image (offset 32)
    ; Source physical base: Kernel Data (0x019000) + image_ptr + 32
    mov ax, [image_ptr]
    add ax, 32
    add ax, 0x9000
    mov [copy_src_low], ax
    mov al, 0x01
    adc al, 0
    mov [copy_src_high], al

    ; Dest physical base = text_phys
    mov dl, [copy_src_high]
    mov si, [copy_src_low]
    mov dh, [exec_text_phys_high]
    mov di, [exec_text_phys_low]
    mov cx, [exec_text_sz]
    call phys_copy

    ; 4. Allocate physical segment for Data (Data + BSS + Stack)
    mov cx, [exec_total]
    add cx, 15
    shr cx, 4                           ; Paras for data in CX
    mov bl, POOL_A                      ; Preferred pool in BL
    mov bh, [current_task]              ; Owner PID in BH
    call seg_alloc
    cmp ax, 0xFFFF
    je .exec_nomem_cleanup
    mov [exec_new_data_blk], ax
    call seg_get_block_ptr              ; DI = &seg_blocks[data_blk]
    mov si, [di + SB_BASE_LOW]
    mov dl, [di + SB_BASE_HIGH]
    mov [exec_data_phys_low], si
    mov [exec_data_phys_high], dl

    ; Copy initialized data from image (offset 32 + text_size)
    mov ax, [image_ptr]
    add ax, 32
    add ax, [exec_text_sz]
    add ax, 0x9000
    mov [copy_src_low], ax
    mov al, 0x01
    adc al, 0
    mov [copy_src_high], al

    mov dl, [copy_src_high]
    mov si, [copy_src_low]
    mov dh, [exec_data_phys_high]
    mov di, [exec_data_phys_low]
    mov cx, [exec_data_sz]
    test cx, cx
    jz .no_data_to_copy
    call phys_copy
.no_data_to_copy:

    ; Zero remainder of data segment (BSS + Heap + Stack)
    mov dh, [exec_data_phys_high]
    mov di, [exec_data_phys_low]
    add di, [exec_data_sz]
    mov cx, [exec_total]
    sub cx, [exec_data_sz]
    xor al, al
    test cx, cx
    jz .no_bss_zero
    call phys_set
.no_bss_zero:

    ; 5. Update LDT of current task
    ; Text: Entry 0, Limit = text_sz - 1, Access = 0xFA (Present, DPL=3, Code E/R)
    mov al, [current_task]
    mov ah, 0
    mov dl, [exec_text_phys_high]
    mov si, [exec_text_phys_low]
    mov bx, [exec_text_sz]
    dec bx                              ; Limit = text_sz - 1
    mov cl, 0xFA                        ; Present, DPL=3, Code E/R
    xor ch, ch
    xor dh, dh
    call ldt_set_entry

    ; Data: Entry 1, Limit = total_sz - 1, Access = 0xF2 (Present, DPL=3, Data R/W)
    mov al, [current_task]
    mov ah, 1
    mov dl, [exec_data_phys_high]
    mov si, [exec_data_phys_low]
    mov bx, [exec_total]
    dec bx
    mov cl, 0xF2                        ; Present, DPL=3, Data R/W
    xor ch, ch
    xor dh, dh
    call ldt_set_entry

    ; 6. Free old segment blocks
    mov al, [current_task]
    call task_get_ptr
    mov bx, di                          ; BX = task_struct

    mov ax, [bx + TS_TEXT_BLK]
    cmp ax, 0xFFFF
    je .skip_free_text
    call seg_free
.skip_free_text:

    mov ax, [bx + TS_DATA_BLK]
    cmp ax, 0xFFFF
    je .skip_free_data
    call seg_free
.skip_free_data:

    ; Update task struct
    mov ax, [exec_new_text_blk]
    mov [bx + TS_TEXT_BLK], ax
    mov ax, [exec_new_data_blk]
    mov [bx + TS_DATA_BLK], ax
    mov ax, [exec_data_sz]
    add ax, [exec_bss_sz]
    mov [bx + TS_BRK_LIMIT], ax

    ; 7. Reset user registers on stack frame for IRET
    ; In syscall_entry:
    ; [bp + 16] = user IP
    ; [bp + 18] = user CS
    ; [bp + 20] = user FLAGS
    ; [bp + 22] = user SP
    ; [bp + 24] = user SS
    ; [bp + 14] = user DS
    ; [bp + 12] = user ES
    mov ax, [exec_entry_ip]
    mov [bp + 16], ax                   ; IP = a_entry
    mov word [bp + 18], LDT_UCODE_SEL   ; CS = 0x0007
    mov word [bp + 20], 0x0202          ; FLAGS (IF=1)
    mov ax, [exec_total]
    sub ax, 2
    mov [bp + 22], ax                   ; SP = total - 2
    mov word [bp + 24], LDT_UDATA_SEL   ; SS = 0x000F
    mov word [bp + 14], LDT_UDATA_SEL   ; DS = 0x000F
    mov word [bp + 12], LDT_UDATA_SEL   ; ES = 0x000F

    xor ax, ax                          ; Return 0
    pop bp
    pop di
    pop si
    ret

.exec_nomem_cleanup:
    mov ax, [exec_new_text_blk]
    call seg_free
.exec_nomem:
    mov ax, -12                         ; -ENOMEM
    pop bp
    pop di
    pop si
    ret

.exec_noexec:
    mov ax, -8                          ; -ENOEXEC
    pop bp
    pop di
    pop si
    ret

; ----------------------------------------------------------------------------
; sys_exit: Terminate process and notify parent
;   BX = Exit status code
; ----------------------------------------------------------------------------
sys_exit:
    mov al, [current_task]
    call task_get_ptr
    mov si, di                          ; SI = current task_struct

    ; Free allocated segments
    mov ax, [si + TS_DATA_BLK]
    cmp ax, 0xFFFF
    je .no_exit_data
    call seg_free
.no_exit_data:

    mov ax, [si + TS_TEXT_BLK]
    cmp ax, 0xFFFF
    je .no_exit_text
    call seg_free
.no_exit_text:

    ; Transition state to TASK_ZOMBIE
    mov byte [si + TS_STATE], TASK_ZOMBIE
    mov [si + TS_EXIT_CODE], bx

    ; Wake up parent if waiting
    mov al, [si + TS_PPID]
    call task_get_ptr
    cmp byte [di + TS_STATE], TASK_BLOCKED
    jne .no_parent_wake
    mov byte [di + TS_STATE], TASK_READY

.no_parent_wake:
    ; Context switch to next ready task
    call schedule
    ; Never returns here
    ret

; ----------------------------------------------------------------------------
; sys_waitpid: Wait for child process state change
;   BX = Target child PID (-1 for any child)
;   CX = Pointer to status in user DS (or 0)
;   DX = Options (WNOHANG = 1)
; ----------------------------------------------------------------------------
sys_waitpid:
    push si
    push di
    push bp

    mov bp, sp

.scan_children:
    mov si, 1                           ; Check child tasks 1 .. MAX_TASKS - 1
    mov word [child_found_flag], 0

.child_loop:
    mov ax, si
    call task_get_ptr                   ; DI = &task_table[si]
    cmp byte [di + TS_STATE], TASK_UNUSED
    je .next_child

    ; Check if child belongs to current task
    mov al, [current_task]
    cmp [di + TS_PPID], al
    jne .next_child

    ; Child exists!
    mov word [child_found_flag], 1

    ; If waiting for specific PID, match it
    cmp bx, -1
    je .check_zombie
    cmp bx, si
    jne .next_child

.check_zombie:
    cmp byte [di + TS_STATE], TASK_ZOMBIE
    je .reap_child

.next_child:
    inc si
    cmp si, MAX_TASKS
    jb .child_loop

    ; No zombie child found during this pass
    cmp word [child_found_flag], 0
    je .no_child_error

    ; Child exists but is still running
    test dx, WNOHANG
    jnz .wait_nohang

    ; Block current task and yield to scheduler
    mov al, [current_task]
    call task_get_ptr
    mov byte [di + TS_STATE], TASK_BLOCKED
    mov [di + TS_WAIT_PID], bx

    call schedule

    ; Woken up: re-scan children
    jmp .scan_children

.reap_child:
    ; Found zombie child SI: collect status and reap slot
    mov ax, [di + TS_EXIT_CODE]
    test cx, cx
    jz .no_status_write

    ; Write status word to caller's DS at offset CX
    push es
    push bx
    mov bx, [bp + 0]                    ; BX = syscall_entry's BP frame
    mov es, [bx + 14]                   ; Caller's saved DS
    mov di, cx
    mov [es:di], ax
    pop bx
    pop es

.no_status_write:
    ; Reclaim child task slot
    mov ax, si
    call task_free_slot

    ; Return child PID in AX
    mov ax, si
    jmp .wait_ret

.wait_nohang:
    xor ax, ax                          ; Return 0 if WNOHANG and child running
    jmp .wait_ret

.no_child_error:
    mov ax, -10                         ; -ECHILD

.wait_ret:
    pop bp
    pop di
    pop si
    ret

; ----------------------------------------------------------------------------
; sys_kill: Send signal to process
;   BX = Target PID
;   CX = Signal (1 .. 15)
; ----------------------------------------------------------------------------
sys_kill:
    push di

    ; Validate PID
    cmp bx, MAX_TASKS
    jae .kill_srch

    ; Validate Signal
    cmp cx, 1
    jb .kill_inval
    cmp cx, 15
    ja .kill_inval

    ; Look up target task
    mov al, bl
    call task_get_ptr
    cmp byte [di + TS_STATE], TASK_UNUSED
    je .kill_srch

    ; Set pending signal bit: (1 << CX)
    mov ax, 1
    push cx
    shl ax, cl
    pop cx
    or [di + TS_SIG_PENDING], ax

    ; Wake up target task if it is blocked
    cmp byte [di + TS_STATE], TASK_BLOCKED
    jne .kill_success
    mov byte [di + TS_STATE], TASK_READY

.kill_success:
    xor ax, ax
    pop di
    ret

.kill_srch:
    mov ax, -3                          ; -ESRCH
    pop di
    ret

.kill_inval:
    mov ax, -22                         ; -EINVAL
    pop di
    ret

; ----------------------------------------------------------------------------
; sys_signal: Set signal handler
;   BX = Signal (1 .. 15)
;   CX = Handler function offset in user CS
; ----------------------------------------------------------------------------
sys_signal:
    push di
    push si

    cmp bx, 1
    jb .sig_inval
    cmp bx, 15
    ja .sig_inval
    cmp bx, SIGKILL                     ; SIGKILL (9) cannot be caught
    je .sig_inval

    mov al, [current_task]
    call task_get_ptr

    mov si, bx
    shl si, 1
    add si, TS_SIG_HANDLERS
    add si, di

    mov ax, [si]                        ; Return old handler in AX
    mov [si], cx                        ; Set new handler
    pop si
    pop di
    ret

.sig_inval:
    mov ax, -22                         ; -EINVAL
    pop si
    pop di
    ret

section .data
saved_req_brk:      dw 0
child_pid:          db 0
child_task_ptr:     dw 0
child_found_flag:   dw 0
exec_total:         dw 0
exec_text_sz:       dw 0
exec_data_sz:       dw 0
exec_bss_sz:        dw 0
exec_entry_ip:      dw 0
exec_new_text_blk:  dw 0
exec_new_data_blk:  dw 0
exec_text_phys_low: dw 0
exec_text_phys_high:db 0
exec_data_phys_low: dw 0
exec_data_phys_high:db 0
copy_src_low:       dw 0
copy_src_high:      db 0
image_ptr:          dw 0

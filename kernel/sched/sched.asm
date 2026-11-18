CPU 286
BITS 16

; ============================================================================
; Lin286 Preemptive Round-Robin Scheduler
;
; Manages 100 Hz timer tick preemption, context switching across Ring 0 kernel
; stacks, hardware LLDT task switching, and TSS.sp0 Ring 0 stack updates.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global sched_init
global schedule
global sched_tick
global sched_active
global task_trampoline_user

section .text

; ----------------------------------------------------------------------------
; sched_init: Initialize multitasking scheduler and task subsystem
; ----------------------------------------------------------------------------
sched_init:
    pusha
    call task_init

    mov byte [sched_active], 1

    mov si, str_sched_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; schedule: Preemptive/cooperative context switcher
;
; Saves current task context, selects next runnable task via round-robin,
; switches LLDT and TSS.sp0, switches stack pointer, and resumes execution.
; ----------------------------------------------------------------------------
schedule:
    pushf
    cli                                 ; Disable interrupts during switch
    push ds
    push es
    pusha

    ; Load Kernel Data Segment
    mov ax, GDT_KDATA_SEL
    mov ds, ax
    mov es, ax

    ; If scheduler is not enabled, do not switch
    cmp byte [sched_active], 1
    jne .switch_done

    ; 1. Save SP of current running task
    mov al, [current_task]
    call task_get_ptr                   ; DI = &task_table[current_task]
    mov [di + TS_KSP], sp

    ; If current task was RUNNING, set to READY (unless BLOCKED or ZOMBIE)
    cmp byte [di + TS_STATE], TASK_RUNNING
    jne .select_next
    mov byte [di + TS_STATE], TASK_READY

.select_next:
    ; 2. Round-robin search for next TASK_READY or TASK_RUNNING task
    mov cl, [current_task]
    mov ch, MAX_TASKS                   ; Search up to MAX_TASKS times

.search_loop:
    inc cl
    cmp cl, MAX_TASKS
    jb .cl_valid
    xor cl, cl                          ; Wrap around to Task 0
.cl_valid:
    mov al, cl
    call task_get_ptr                   ; DI = &task_table[cl]
    cmp byte [di + TS_STATE], TASK_READY
    je .task_found
    cmp byte [di + TS_STATE], TASK_RUNNING
    je .task_found

    dec ch
    jnz .search_loop

    ; If no ready task found, fall back to Task 0 (Idle task)
    xor cl, cl
    mov al, cl
    call task_get_ptr

.task_found:
    ; cl = next_pid, DI = &task_table[next_pid]
    mov byte [di + TS_STATE], TASK_RUNNING
    mov byte [di + TS_TICKS_LEFT], 5    ; 5 ticks = 50ms quantum

    ; If switching to same task, no stack switch needed
    cmp cl, [current_task]
    je .switch_done

    ; Update active task & LDT PID tracker
    mov [current_task], cl
    mov [current_pid], cl

    ; 3. Update Shared TSS.sp0 to top of next task's Ring 0 stack
    mov ax, cx
    inc ax                              ; (PID + 1)
    mov bx, TASK_KSTACK_SIZE
    mul bx                              ; AX = (PID + 1) * 512
    add ax, task_kstacks - 2
    mov [tss_struct + 2], ax            ; Set TSS.sp0

    ; 4. Switch LDT via 80286 LLDT instruction
    mov ax, [di + TS_LDT_SEL]
    lldt ax

    ; 5. Switch Kernel Stack Pointer
    mov sp, [di + TS_KSP]

.switch_done:
    popa
    pop es
    pop ds
    popf
    ret

; ----------------------------------------------------------------------------
; sched_tick: Timer tick handler hook called from IRQ 0 (100 Hz PIT)
; ----------------------------------------------------------------------------
sched_tick:
    cmp byte [sched_active], 1
    jne .tick_done

    push ax
    push di

    mov al, [current_task]
    call task_get_ptr
    cmp byte [di + TS_STATE], TASK_RUNNING
    jne .tick_pop

    ; Decrement remaining quantum
    dec byte [di + TS_TICKS_LEFT]
    jnz .tick_pop

    ; Time quantum expired: reset quantum and trigger preemption
    mov byte [di + TS_TICKS_LEFT], 5
    pop di
    pop ax

    call schedule
    ret

.tick_pop:
    pop di
    pop ax
.tick_done:
    ret

; ----------------------------------------------------------------------------
; task_trampoline_user: Initial entry point for newly spawned Ring 3 tasks
; ----------------------------------------------------------------------------
task_trampoline_user:
    popa
    pop es
    pop ds
    iret

section .data
sched_active:   db 0
str_sched_ok:   db "[SCHED] Preemptive round-robin scheduler & task table initialized", 13, 10, 0

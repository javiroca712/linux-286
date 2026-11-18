CPU 286
BITS 16

; ============================================================================
; Lin286 Task Structure & Process Table Subsystem
;
; Manages up to MAX_TASKS (8) processes:
; - Task 0: Ring 0 Kernel Idle Task
; - Tasks 1..7: User/Kernel Ring 3 / Ring 0 processes
; Allocates per-process kernel stacks (512 bytes each) and tracks
; PID, PPID, execution states, LDT selectors, signals, and segment blocks.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global task_init
global task_get_ptr
global task_alloc_slot
global task_free_slot
global current_task
global task_table
global task_kstacks

section .text

; ----------------------------------------------------------------------------
; task_init: Initialize task table and set up Task 0 (Kernel/Idle Task)
; ----------------------------------------------------------------------------
task_init:
    pusha
    push es

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; 1. Zero out entire task table (8 * 64 = 512 bytes)
    mov di, task_table
    mov cx, (MAX_TASKS * TASK_STRUCT_SIZE) / 2
    xor ax, ax
    cld
    rep stosw

    ; 2. Initialize default structures for each task slot
    xor cx, cx                          ; CX = PID (0 .. MAX_TASKS - 1)

.init_loop:
    mov ax, cx
    shl ax, 6                           ; AX = PID * 64
    add ax, task_table
    mov di, ax                          ; DI = &task_table[PID]

    ; PID
    mov [di + TS_PID], cx

    ; State: TASK_UNUSED (Task 0 will be set to RUNNING below)
    mov byte [di + TS_STATE], TASK_UNUSED
    mov byte [di + TS_PPID], 0
    mov byte [di + TS_PRIORITY], 10
    mov byte [di + TS_TICKS_LEFT], 5

    ; LDT selector in GDT: 0x0040 + (PID * 8)
    mov ax, cx
    shl ax, 3                           ; PID * 8
    add ax, GDT_FIRST_LDT
    mov [di + TS_LDT_SEL], ax

    ; Kernel stack: top of task_kstacks[(PID + 1) * 512] - 2
    mov ax, cx
    inc ax                              ; PID + 1
    mov bx, TASK_KSTACK_SIZE
    mul bx                              ; AX = (PID + 1) * 512
    add ax, task_kstacks - 2
    mov [di + TS_KSP], ax
    mov word [di + TS_KSS], GDT_KDATA_SEL

    inc cx
    cmp cx, MAX_TASKS
    jb .init_loop

    ; 3. Setup Task 0 as the active Kernel / Idle Task
    mov di, task_table                  ; Task 0 is at offset 0
    mov byte [di + TS_STATE], TASK_RUNNING
    mov byte [di + TS_PRIORITY], 0      ; Lowest priority (idle)
    mov byte [di + TS_TICKS_LEFT], 5
    mov word [di + TS_KSP], 0xFFF0      ; Initial kernel boot stack
    mov byte [current_task], 0
    mov byte [current_pid], 0

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; task_get_ptr: Get pointer to task_struct for a given PID
;
; Input:
;   AL = PID (0 .. MAX_TASKS - 1)
; Output:
;   DI = Offset in Kernel Data of struct task_struct
; ----------------------------------------------------------------------------
task_get_ptr:
    push ax
    xor ah, ah
    shl ax, 6                           ; AX = PID * 64
    add ax, task_table
    mov di, ax
    pop ax
    ret

; ----------------------------------------------------------------------------
; task_alloc_slot: Allocate a free task slot (PID 1 .. MAX_TASKS - 1)
;
; Output:
;   AL = Allocated PID (1 .. MAX_TASKS - 1), or 0xFF if no slot available
;   DI = Pointer to task_struct (if allocated)
; ----------------------------------------------------------------------------
task_alloc_slot:
    push cx
    mov cx, 1                           ; Start from PID 1 (Task 0 is kernel)

.scan_loop:
    mov al, cl
    call task_get_ptr
    cmp byte [di + TS_STATE], TASK_UNUSED
    je .found

    inc cx
    cmp cx, MAX_TASKS
    jb .scan_loop

    ; No free slots
    pop cx
    mov al, 0xFF
    ret

.found:
    mov al, cl
    pop cx
    ret

; ----------------------------------------------------------------------------
; task_free_slot: Mark a task slot as UNUSED
;
; Input:
;   AL = PID (0 .. MAX_TASKS - 1)
; ----------------------------------------------------------------------------
task_free_slot:
    push di
    call task_get_ptr
    mov byte [di + TS_STATE], TASK_UNUSED
    pop di
    ret

section .data
current_task:   db 0

section .bss
align 8
; 8 tasks * 64 bytes = 512 bytes
task_table:     resb MAX_TASKS * TASK_STRUCT_SIZE

align 8
; 8 tasks * 512 bytes = 4096 bytes per-process Ring 0 kernel stacks
task_kstacks:   resb MAX_TASKS * TASK_KSTACK_SIZE

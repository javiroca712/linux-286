CPU 286
BITS 16

; ============================================================================
; Lin286 Local Descriptor Table (LDT) & Task State Segment (TSS) Manager
;
; Manages per-process LDT tables, per-task LDT descriptors in the GDT
; (selectors 0x0040 to 0x0078), hardware LLDT task switching, and the
; shared 80286 Hardware TSS (0x0038) for Ring 3 -> Ring 0 stack switching.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global ldt_init
global ldt_set_entry
global ldt_get_entry_ptr
global ldt_switch_task
global ldt_get_current_pid
global current_pid
global task_ldts

section .text

; ----------------------------------------------------------------------------
; ldt_init: Initialize GDT descriptors for all task LDTs and load Task 0
; ----------------------------------------------------------------------------
ldt_init:
    pusha

    ; Kernel data base is physical 0x019000
    ; For each task pid (0 .. MAX_TASKS - 1):
    ; Compute physical address: 0x019000 + task_ldts + (pid * 64)
    xor cx, cx                          ; pid = 0

.loop_tasks:
    ; Calculate offset of task_ldts[pid] in DS
    mov ax, cx
    mov bl, 64                          ; 8 entries * 8 bytes = 64 bytes per task
    mul bl                              ; AX = pid * 64
    add ax, task_ldts                   ; AX = offset in DS (Kernel Data)

    ; Calculate 24-bit physical address: 0x019000 + AX
    ; Low 16 bits = 0x9000 + AX
    ; High 8 bits = 0x01 + carry
    mov dx, 0x9000
    add dx, ax                          ; DX = physical base low
    mov bl, 0x01
    adc bl, 0                           ; BL = physical base high

    ; Offset in GDT for this task: 0x40 + (pid * 8)
    mov di, cx
    shl di, 3                           ; DI = pid * 8
    add di, gdt_table + 0x40            ; DI points to descriptor in GDT

    ; Fill GDT LDT descriptor:
    mov word [di + 0], (8 * 8) - 1      ; Limit = 63 bytes (8 descriptors)
    mov word [di + 2], dx               ; Base 15..0
    mov byte [di + 4], bl               ; Base 23..16
    mov byte [di + 5], 0x82             ; Present(1), DPL=0, Type=0010 (286 LDT)
    mov word [di + 6], 0x0000           ; Reserved

    inc cx
    cmp cx, MAX_TASKS
    jb .loop_tasks

    ; Default to Task 0
    mov byte [current_pid], 0
    mov ax, GDT_FIRST_LDT               ; 0x0040
    lldt ax                             ; 80286 LLDT instruction!

    mov si, str_ldt_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; ldt_set_entry: Set an entry in a task's LDT
;
; Inputs:
;   AL = PID (0 .. MAX_TASKS - 1)
;   AH = Entry Index (0 .. 7)
;   DL = Base High (bits 23..16)
;   SI = Base Low  (bits 15..0)
;   BX = Limit (16-bit)
;   CL = Access Byte (P | DPL | S | Type | A)
;   CH = VM Flags Low (VM_FLAG_COW, VM_FLAG_DIRTY, etc.)
;   DH = VM Flags High
; ----------------------------------------------------------------------------
ldt_set_entry:
    pusha

    ; Offset = (PID * 64) + (Entry * 8)
    push ax
    xor ah, ah
    shl ax, 6                           ; AX = PID * 64 (preserves BX!)
    mov di, ax
    pop ax

    mov al, ah                          ; AL = Entry Index
    xor ah, ah
    shl ax, 3                           ; AX = Entry * 8
    add di, ax
    add di, task_ldts                   ; DI points to desc286 in task_ldts

    ; Populate descriptor
    mov [di + 0], bx                    ; Limit
    mov [di + 2], si                    ; Base 15..0
    mov [di + 4], dl                    ; Base 23..16
    mov [di + 5], cl                    ; Access byte
    mov [di + 6], ch                    ; VM flags low
    mov [di + 7], dh                    ; VM flags high

    popa
    ret

; ----------------------------------------------------------------------------
; ldt_get_entry_ptr: Get pointer to desc286 struct in kernel DS
;
; Inputs:
;   AL = PID
;   AH = Entry Index
; Output:
;   DI = Offset of struct desc286 in DS
; ----------------------------------------------------------------------------
ldt_get_entry_ptr:
    push ax
    push bx
    push dx

    push ax
    xor ah, ah
    shl ax, 6
    mov di, ax
    pop ax

    mov al, ah
    xor ah, ah
    shl ax, 3
    add di, ax
    add di, task_ldts

    pop dx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; ldt_switch_task: Switch active LDT to specified PID
;
; Inputs:
;   AL = Target PID (0 .. MAX_TASKS - 1)
; ----------------------------------------------------------------------------
ldt_switch_task:
    push ax
    push bx

    mov [current_pid], al
    xor ah, ah
    shl ax, 3                           ; AX = PID * 8
    add ax, GDT_FIRST_LDT               ; Selector in GDT (0x0040, 0x0048, ...)
    lldt ax                             ; 80286 LLDT loads new LDT base & limit!

    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------------
; ldt_get_current_pid: Get active PID
;
; Output:
;   AL = current_pid
; ----------------------------------------------------------------------------
ldt_get_current_pid:
    mov al, [current_pid]
    ret

section .data
current_pid:    db 0
str_ldt_ok:     db "[LDT] Per-task LDTs (0x0040-0x0078) initialized and LLDT loaded", 13, 10, 0

section .bss
align 8
; 8 tasks * 8 entries * 8 bytes = 512 bytes
task_ldts:      resb MAX_TASKS * 8 * 8

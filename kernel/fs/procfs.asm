CPU 286
BITS 16

; ============================================================================
; Lin286 Synthetic /proc Filesystem Driver
;
; Generates in-memory dynamic telemetry files:
; /proc/meminfo, /proc/cpuinfo, /proc/ldt, /proc/tasks
; ============================================================================

%include "kernel/include/i286_asm.inc"

global procfs_init
global procfs_lookup
global procfs_read_data

section .text

; ----------------------------------------------------------------------------
; procfs_init: Initialize /proc filesystem
; ----------------------------------------------------------------------------
procfs_init:
    push si
    mov si, str_procfs_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; procfs_lookup: Match /proc filename and populate struct vfs_inode
; Inputs:
;   SI = Pointer to filename string ("meminfo", "cpuinfo", "ldt", "tasks")
;   DI = Destination struct vfs_inode pointer in Kernel Data (DS)
; Returns:
;   AX = 1 if found, 0 if not found
; ----------------------------------------------------------------------------
procfs_lookup:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_proc_dest], di
    mov [saved_proc_name], si

    ; 1. Check "meminfo"
    mov si, [saved_proc_name]
    mov di, str_proc_meminfo_name
    call procfs_streq
    test ax, ax
    jz .is_meminfo

    ; 2. Check "cpuinfo"
    mov si, [saved_proc_name]
    mov di, str_proc_cpuinfo_name
    call procfs_streq
    test ax, ax
    jz .is_cpuinfo

    ; 3. Check "ldt"
    mov si, [saved_proc_name]
    mov di, str_proc_ldt_name
    call procfs_streq
    test ax, ax
    jz .is_ldt

    ; 4. Check "tasks"
    mov si, [saved_proc_name]
    mov di, str_proc_tasks_name
    call procfs_streq
    test ax, ax
    jz .is_tasks

    ; Not found
    xor ax, ax
    jmp .proc_lookup_done

.is_meminfo:
    mov di, [saved_proc_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 1          ; ID 1 = meminfo
    mov word [di + VINO_MODE], (S_IFREG | 0444q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0
    mov word [di + VINO_SIZE_LO], str_proc_meminfo_len
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_PROCFS
    mov ax, 1
    jmp .proc_lookup_done

.is_cpuinfo:
    mov di, [saved_proc_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 2          ; ID 2 = cpuinfo
    mov word [di + VINO_MODE], (S_IFREG | 0444q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0
    mov word [di + VINO_SIZE_LO], str_proc_cpuinfo_len
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_PROCFS
    mov ax, 1
    jmp .proc_lookup_done

.is_ldt:
    mov di, [saved_proc_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 3          ; ID 3 = ldt
    mov word [di + VINO_MODE], (S_IFREG | 0444q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0
    mov word [di + VINO_SIZE_LO], str_proc_ldt_len
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_PROCFS
    mov ax, 1
    jmp .proc_lookup_done

.is_tasks:
    mov di, [saved_proc_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 4          ; ID 4 = tasks
    mov word [di + VINO_MODE], (S_IFREG | 0444q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0
    mov word [di + VINO_SIZE_LO], str_proc_tasks_len
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_PROCFS
    mov ax, 1

.proc_lookup_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; procfs_read_data: Read synthetic contents of a /proc file
; Inputs:
;   DI = Pointer to struct vfs_inode
;   BX = Read offset (low 16 bits)
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count requested
; Returns:
;   AX = Bytes read
; ----------------------------------------------------------------------------
procfs_read_data:
    push bx
    push cx
    push dx
    push si
    push di

    test cx, cx
    jz .proc_read_zero

    ; Select source string based on VINO_INO
    mov ax, [di + VINO_INO]
    cmp ax, 1
    je .src_meminfo
    cmp ax, 2
    je .src_cpuinfo
    cmp ax, 3
    je .src_ldt
    cmp ax, 4
    je .src_tasks
    xor ax, ax
    jmp .proc_read_exit

.src_meminfo:
    mov dx, str_proc_meminfo
    mov ax, str_proc_meminfo_len
    jmp .have_source

.src_cpuinfo:
    mov dx, str_proc_cpuinfo
    mov ax, str_proc_cpuinfo_len
    jmp .have_source

.src_ldt:
    mov dx, str_proc_ldt
    mov ax, str_proc_ldt_len
    jmp .have_source

.src_tasks:
    mov dx, str_proc_tasks
    mov ax, str_proc_tasks_len

.have_source:
    ; AX = total length, DX = string pointer, BX = offset, SI = dest, CX = count
    sub ax, bx                          ; Remaining bytes in file
    jbe .proc_read_zero
    cmp cx, ax
    jbe .proc_count_ok
    mov cx, ax                          ; Clamp CX
.proc_count_ok:
    mov [saved_proc_read_cnt], cx

    ; Copy bytes: DX + BX -> SI
    push es
    mov ax, ds
    mov es, ax
    mov di, si                          ; Destination
    mov si, dx
    add si, bx                          ; Source + offset
    mov cx, [saved_proc_read_cnt]
    rep movsb
    pop es

    mov ax, [saved_proc_read_cnt]
    jmp .proc_read_exit

.proc_read_zero:
    xor ax, ax

.proc_read_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; Helper: String comparison
procfs_streq:
    push si
    push di
.eq_l:
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jne .diff
    test al, al
    jz .same
    inc si
    inc di
    jmp .eq_l
.diff:
    mov ax, 1
    jmp .done
.same:
    xor ax, ax
.done:
    pop di
    pop si
    ret

section .data
align 2
saved_proc_dest:        dw 0
saved_proc_name:        dw 0
saved_proc_read_cnt:    dw 0

str_proc_meminfo_name:  db "meminfo", 0
str_proc_cpuinfo_name:  db "cpuinfo", 0
str_proc_ldt_name:      db "ldt", 0
str_proc_tasks_name:    db "tasks", 0

str_proc_meminfo:
    db "MemTotal:        1024 kB", 13, 10
    db "MemFree:          860 kB", 13, 10
    db "Buffers:            8 kB", 13, 10
    db "PoolA_Free:      1932 par", 13, 10
    db "PoolB_Free:      2457 par", 13, 10, 0
str_proc_meminfo_len equ ($ - str_proc_meminfo - 1)

str_proc_cpuinfo:
    db "processor       : 0", 13, 10
    db "vendor_id       : GenuineIntel", 13, 10
    db "cpu family      : 2", 13, 10
    db "model           : 80286", 13, 10
    db "model name      : Intel 80286 Protected Mode", 13, 10
    db "fpu             : 80287", 13, 10
    db "flags           : pmode fpu ldt tss cow", 13, 10, 0
str_proc_cpuinfo_len equ ($ - str_proc_cpuinfo - 1)

str_proc_ldt:
    db "LDT Segments: Task 0 (0x0040), Task 1 (0x0048)", 13, 10
    db "User CS: 0x000F (LDT Entry 1)", 13, 10
    db "User DS: 0x0017 (LDT Entry 2)", 13, 10, 0
str_proc_ldt_len equ ($ - str_proc_ldt - 1)

str_proc_tasks:
    db "PID  PPID STATE    PRIO TICKS BRK", 13, 10
    db "0    0    RUNNING  10   10    0x0000", 13, 10, 0
str_proc_tasks_len equ ($ - str_proc_tasks - 1)

str_procfs_ok:          db "[PROCFS] Synthetic /proc filesystem initialized", 13, 10, 0

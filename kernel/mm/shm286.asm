CPU 286
BITS 16

; ============================================================================
; Lin286 Zero-Copy LDT Shared Memory Subsystem (shmget286, shmat286, shmdt286)
;
; Provides zero-copy memory sharing between Ring 3 processes (e.g. GUI Client
; and Display Server) by aliasing the exact same 24-bit physical memory segment
; in Extended RAM (0x100000+) across multiple process LDTs (selectors 0x0027+).
; ============================================================================

%include "kernel/include/i286_asm.inc"

extern uart_puts
extern uart_putc
extern uart_print_hex8
extern uart_print_hex16

global shm_init
global sys_shmget286
global sys_shmat286
global sys_shmdt286
global shm_table

section .text

; ----------------------------------------------------------------------------
; shm_init: Initialize shared memory table
; ----------------------------------------------------------------------------
shm_init:
    pusha
    push es

    mov ax, ds
    mov es, ax
    mov di, shm_table
    mov cx, (MAX_SHM_SEGS * 16) / 2
    xor ax, ax
    cld
    rep stosw

    mov si, str_shm_ok
    call uart_puts

    pop es
    popa
    ret

; ----------------------------------------------------------------------------
; sys_shmget286: Allocate or find a shared memory segment
; Inputs:
;   BX = Key (or IPC_PRIVATE = 0)
;   CX = Requested size in bytes (1..65535)
;   DX = Flags
; Returns:
;   AX = Shared Memory ID (shmid 1..MAX_SHM_SEGS), or negative error code
; ----------------------------------------------------------------------------
sys_shmget286:
    push bx
    push cx
    push dx
    push si
    push di

    ; Validate size
    test cx, cx
    jz .bad_size

    ; 1. If key != IPC_PRIVATE, search for existing segment
    test bx, bx
    jz .find_slot

    xor di, di                          ; Slot index 0..MAX_SHM_SEGS-1
.search_key:
    mov si, di
    shl si, 4                           ; SI = di * 16
    add si, shm_table
    cmp byte [si + 9], 1                ; in_use?
    jne .next_key
    cmp [si + 0], bx                    ; key matches?
    je .found_key
.next_key:
    inc di
    cmp di, MAX_SHM_SEGS
    jb .search_key
    ; Not found, continue to allocate new

.find_slot:
    ; 2. Find free slot in shm_table
    xor di, di
.search_slot:
    mov si, di
    shl si, 4
    add si, shm_table
    cmp byte [si + 9], 0                ; in_use == 0?
    je .slot_found
    inc di
    cmp di, MAX_SHM_SEGS
    jb .search_slot

    ; Table full
    mov ax, -ENOMEM
    jmp .shmget_exit

.slot_found:
    ; DI = slot index
    mov [saved_shm_slot], di
    mov [saved_shm_key], bx
    mov [saved_shm_size], cx
    mov [saved_shm_flags], dx

    ; 3. Allocate physical segment in Extended RAM (POOL_B first)
    ; Convert size in bytes to 16-byte paragraphs: paras = (size + 15) >> 4
    mov ax, [saved_shm_size]
    add ax, 15
    shr ax, 4                           ; AX = paragraphs
    mov cx, ax                          ; CX = size in paragraphs

    mov bl, POOL_B                      ; BL = preferred pool
    call ldt_get_current_pid
    mov bh, al                          ; BH = owner PID
    call seg_alloc
    cmp ax, 0xFFFF
    jne .alloc_ok

    ; Allocation failed
    mov ax, -ENOMEM
    jmp .shmget_exit

.alloc_ok:
    ; AX = allocated seg_block index
    mov [saved_shm_blk], ax

    ; Calculate physical address from seg_blocks[AX]
    mov si, ax
    shl si, 4                           ; SI = blk_idx * 16
    add si, seg_blocks
    mov dx, [si + SB_BASE_LOW]
    mov bl, [si + SB_BASE_HIGH]

    ; Populate shm_table entry
    mov di, [saved_shm_slot]
    shl di, 4
    add di, shm_table

    mov ax, [saved_shm_key]
    mov [di + 0], ax                    ; Key
    mov ax, [saved_shm_size]
    mov [di + 2], ax                    ; Size
    mov ax, [saved_shm_blk]
    mov [di + 4], ax                    ; Block index
    mov [di + 6], dx                    ; Base Low
    mov [di + 8], bl                    ; Base High
    mov byte [di + 9], 1                ; in_use = 1
    mov word [di + 10], 0               ; ref_count = 0
    mov ax, [saved_shm_flags]
    mov [di + 12], ax                   ; Flags
    mov word [di + 14], 0               ; Reserved

    ; Return shmid = slot + 1
    mov ax, [saved_shm_slot]
    inc ax
    jmp .shmget_exit

.found_key:
    ; Return shmid = DI + 1
    mov ax, di
    inc ax
    jmp .shmget_exit

.bad_size:
    mov ax, -EINVAL

.shmget_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; sys_shmat286: Attach a shared segment into caller's LDT
; Inputs:
;   BX = shmid (1..MAX_SHM_SEGS)
;   CX = shmaddr (0 for automatic slot assignment)
;   DX = flags
; Returns:
;   AX = Ring 3 LDT Selector (e.g. 0x0027, 0x002F, 0x0037, 0x003F), or error
; ----------------------------------------------------------------------------
sys_shmat286:
    push bx
    push cx
    push dx
    push si
    push di

    ; 1. Validate shmid
    test bx, bx
    jz .bad_id
    cmp bx, MAX_SHM_SEGS
    ja .bad_id

    dec bx                              ; Convert to 0-based index
    mov si, bx
    shl si, 4
    add si, shm_table
    cmp byte [si + 9], 1                ; in_use?
    jne .bad_id

    mov [saved_attach_si], si           ; Save entry pointer

    ; 2. Determine caller PID
    call ldt_get_current_pid            ; AL = PID
    mov [saved_caller_pid], al

    ; 3. Find an available LDT descriptor slot (entries 4..7)
    ; Entry 4: 0x0027, Entry 5: 0x002F, Entry 6: 0x0037, Entry 7: 0x003F
    mov cx, 4                           ; Start at entry 4
.find_ldt_slot:
    mov al, [saved_caller_pid]
    mov ah, cl                          ; AH = entry index (4..7)
    call ldt_get_entry_ptr              ; DI = pointer to desc286 in task_ldts
    mov al, [di + 5]                    ; Access byte
    test al, DESC_PRESENT               ; Segment Present?
    jz .found_ldt_slot                  ; Free if not present!
    inc cl
    cmp cl, 8
    jb .find_ldt_slot

    ; All 4 shared memory slots are full
    mov ax, -ENOMEM
    jmp .shmat_exit

.found_ldt_slot:
    ; CL = chosen LDT entry (4..7)
    mov [saved_ldt_entry], cl

    ; 4. Install descriptor via ldt_set_entry
    mov di, [saved_attach_si]           ; DI = shm_table entry
    mov al, [saved_caller_pid]          ; AL = PID
    mov ah, [saved_ldt_entry]           ; AH = entry index (4..7)
    mov dl, [di + 8]                    ; DL = Base High
    mov bx, [di + 2]
    dec bx                              ; BX = Limit (size - 1)
    mov cl, (DESC_PRESENT | DESC_DPL_3 | DESC_SEG | DESC_WRITABLE) ; 0xF2
    mov ch, VM_FLAG_SHM                 ; Software VM Flag: SHM (0x0010)
    xor dh, dh
    mov si, [di + 6]                    ; SI = Base Low
    call ldt_set_entry

    ; 5. Increment refcounts
    mov si, [saved_attach_si]
    inc word [si + 10]                  ; shm_ref_count
    mov ax, [si + 4]                    ; seg_block index
    shl ax, 4
    add ax, seg_blocks
    mov di, ax
    inc word [di + SB_REF_COUNT]        ; SB_REF_COUNT

    ; 6. Calculate return selector: (entry << 3) | TI_LDT | RPL_RING3
    mov al, [saved_ldt_entry]
    xor ah, ah
    shl ax, 3                           ; AX = entry * 8
    or ax, (TI_LDT | RPL_RING3)         ; AX = 0x0027, 0x002F, ...
    jmp .shmat_exit

.bad_id:
    mov ax, -EINVAL

.shmat_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; sys_shmdt286: Detach a shared segment from caller's LDT
; Input:
;   BX = LDT Selector (0x0027..0x003F)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_shmdt286:
    push bx
    push cx
    push dx
    push si
    push di

    ; Verify selector is an LDT selector with RPL=3
    mov ax, bx
    and ax, 0x0007
    cmp ax, (TI_LDT | RPL_RING3)
    jne .bad_dt_sel

    ; Extract entry index: BX >> 3
    mov ax, bx
    shr ax, 3
    cmp ax, 4
    jb .bad_dt_sel
    cmp ax, 7
    ja .bad_dt_sel

    mov cl, al                          ; Entry index 4..7
    call ldt_get_current_pid            ; AL = PID
    mov ah, cl
    call ldt_get_entry_ptr              ; DI = &task_ldts[pid][entry]

    ; Check if present
    test byte [di + 5], DESC_PRESENT
    jz .bad_dt_sel

    ; Clear descriptor
    mov byte [di + 5], 0                ; Present = 0

    xor ax, ax
    jmp .shmdt_exit

.bad_dt_sel:
    mov ax, -EINVAL

.shmdt_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

section .data
align 2
saved_shm_slot:     dw 0
saved_shm_key:      dw 0
saved_shm_size:     dw 0
saved_shm_flags:    dw 0
saved_shm_blk:      dw 0
saved_attach_si:    dw 0
saved_caller_pid:   db 0
saved_ldt_entry:    db 0

str_shm_ok: db "[SHM286] Zero-Copy LDT Shared Memory (shmget/shmat) initialized", 13, 10, 0

section .bss
align 8
; 8 entries * 16 bytes = 128 bytes
shm_table:  resb (MAX_SHM_SEGS * 16)

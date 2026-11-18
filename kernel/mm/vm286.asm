CPU 286
BITS 16

; ============================================================================
; Lin286 Hardware-Trapped Segment Virtual Memory Core
;
; Implements:
; 1. Copy-on-Write (CoW) unsharing and software VM_DIRTY tracking on #GP (INT 13)
; 2. Demand segment loading and Clock-LRU eviction on #NP (INT 11)
; 3. Dynamic stack expansion for expand-down segments on #SS (INT 12)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global vm_init
global vm_handle_gp
global vm_handle_np
global vm_handle_ss
global vm_clock_lru_evict
global vm_cow_faults_handled
global vm_np_faults_handled
global vm_ss_faults_handled

section .text

; ----------------------------------------------------------------------------
; vm_init: Initialize Virtual Memory Subsystem
; ----------------------------------------------------------------------------
vm_init:
    pusha
    mov word [vm_cow_faults_handled], 0
    mov word [vm_np_faults_handled], 0
    mov word [vm_ss_faults_handled], 0
    mov word [clock_hand_task], 0
    mov word [clock_hand_entry], 0

    mov si, str_vm_init_ok
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; vm_handle_gp: Copy-on-Write (#GP INT 13) Handler
;
; Inputs:
;   AX = Error Code pushed by CPU
;   BX = Faulting CS
;   DX = Faulting IP
; Output:
;   AX = 1 if handled (IRET to retry instruction), 0 if unhandled
; ----------------------------------------------------------------------------
vm_handle_gp:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    ; In 80286 architecture, writes to a read-only segment push error code 0.
    ; Check if the current task's Data Segment (LDT_UDATA_SEL = 0x000F, Entry 1)
    ; has the VM_FLAG_COW flag set.
    mov al, [current_pid]
    xor ah, ah
    mov cl, 6
    shl ax, cl                          ; AX = PID * 64
    add ax, task_ldts + 8               ; Entry 1 is offset +8 (LDT_UDATA_SEL)
    mov di, ax                          ; DI points to LDT Entry 1 desc286

    ; Check if segment is mapped and writable is clear
    mov al, [di + 5]                    ; Access byte
    test al, DESC_WRITABLE              ; Already writable?
    jnz .check_clean_dirty              ; If already writable, write wasn't blocked by R/O

    ; Check if VM_FLAG_COW is set in reserved_vm (offset +6)
    mov bx, [di + 6]                    ; VM Flags
    test bx, VM_FLAG_COW
    jz .check_clean_dirty

    ; ------------------------------------------------------------------------
    ; Copy-on-Write (CoW) Unshare Resolution
    ; ------------------------------------------------------------------------
    ; Find the physical block in seg_blocks associated with this descriptor
    call find_block_for_desc
    cmp ax, 0xFFFF
    je .unhandled                       ; Block not found

    mov si, ax
    shl si, 4
    add si, seg_blocks                  ; SI points to seg_block

    ; Check reference count
    cmp word [si + SB_REF_COUNT], 1
    jbe .sole_owner

    ; Multiple references: allocate new frame and duplicate!
    mov cx, [si + SB_SIZE_PARAS]
    mov bl, [si + SB_POOL_ID]
    mov bh, [current_pid]
    call seg_alloc
    cmp ax, 0xFFFF
    je .unhandled                       ; Out of memory

    ; AX = new block index
    mov bp, ax
    shl bp, 4
    add bp, seg_blocks                  ; BP points to new seg_block

    ; Copy data from old physical block to new physical block
    push di
    ; DL = src_high, SI = src_low
    ; DH = dst_high, DI = dst_low
    ; CX = bytes
    mov dl, [si + SB_BASE_HIGH]
    mov ax, [si + SB_BASE_LOW]
    mov dh, [bp + SB_BASE_HIGH]
    mov di, [bp + SB_BASE_LOW]
    mov cx, [si + SB_SIZE_PARAS]
    shl cx, 4                           ; bytes
    push si
    mov si, ax
    call phys_copy
    pop si
    pop di

    ; Decrement old block's ref_count
    dec word [si + SB_REF_COUNT]

    ; Update LDT descriptor to point to new physical block
    mov ax, [bp + SB_BASE_LOW]
    mov [di + 2], ax
    mov al, [bp + SB_BASE_HIGH]
    mov [di + 4], al

    ; Enable DESC_WRITABLE, clear VM_FLAG_COW, set VM_FLAG_DIRTY
    or byte [di + 5], DESC_WRITABLE
    and word [di + 6], ~VM_FLAG_COW
    or word [di + 6], VM_FLAG_DIRTY

    ; Link new block to this descriptor
    mov ax, bp
    sub ax, seg_blocks
    shr ax, 4
    call seg_link_desc

    inc word [vm_cow_faults_handled]
    mov si, str_cow_unshared
    call uart_puts
    mov ax, 1                           ; Handled!
    jmp .done

.sole_owner:
    ; We are the sole owner: just flip to writable and clear COW
    or byte [di + 5], DESC_WRITABLE
    and word [di + 6], ~VM_FLAG_COW
    or word [di + 6], VM_FLAG_DIRTY
    inc word [vm_cow_faults_handled]
    mov si, str_cow_promoted
    call uart_puts
    mov ax, 1
    jmp .done

.check_clean_dirty:
    ; Check if this is a first write to a clean segment (Software Dirty Tracking)
    mov bx, [di + 6]
    test bx, VM_FLAG_DIRTY
    jnz .unhandled

    ; Mark dirty and enable write access
    or byte [di + 5], DESC_WRITABLE
    or word [di + 6], VM_FLAG_DIRTY
    inc word [vm_cow_faults_handled]
    mov si, str_dirty_handled
    call uart_puts
    mov ax, 1
    jmp .done

.unhandled:
    xor ax, ax                          ; 0 = Not handled

.done:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vm_handle_np: Demand Segment Loader & Swap-in (#NP INT 11) Handler
;
; Inputs:
;   AX = Faulting Selector pushed as error code
; Output:
;   AX = 1 if demand loaded (IRET to retry), 0 if unhandled
; ----------------------------------------------------------------------------
vm_handle_np:
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    mov bx, ax                          ; BX = Selector
    test bl, TI_LDT                     ; Is it LDT or GDT?
    jnz .from_ldt

    ; From GDT:
    mov di, bx
    and di, 0xFFF8                      ; Clear TI and RPL
    add di, gdt_table
    jmp .check_desc

.from_ldt:
    ; From active task's LDT:
    mov di, bx
    and di, 0x00F8                      ; Index * 8
    mov al, [current_pid]
    xor ah, ah
    mov cl, 6
    shl ax, cl
    add di, ax
    add di, task_ldts                   ; DI points to descriptor

.check_desc:
    ; Verify that Present == 0
    test byte [di + 5], DESC_PRESENT
    jnz .unhandled_np                   ; If already present, not an NP fault!

    ; Check if VM_FLAG_DEMAND or VM_FLAG_SWAPPED is set
    mov ax, [di + 6]                    ; VM Flags
    test ax, (VM_FLAG_DEMAND | VM_FLAG_SWAPPED)
    jz .unhandled_np

    ; Calculate paragraphs needed: (limit / 16) + 1
    mov cx, [di + 0]                    ; Limit
    shr cx, 4                           ; Paras = Limit / 16
    inc cx                              ; +1 para

    ; Allocate physical memory from Pool B (prefer extended RAM)
    mov bl, POOL_B
    mov bh, [current_pid]
    call seg_alloc
    cmp ax, 0xFFFF
    jne .alloc_ok

    ; If out of memory, run Clock-LRU eviction scanner
    call vm_clock_lru_evict
    test ax, ax
    jz .unhandled_np                    ; Cannot evict, truly OOM

    ; Retry allocation after eviction
    call seg_alloc
    cmp ax, 0xFFFF
    je .unhandled_np

.alloc_ok:
    ; AX = allocated block index
    mov si, ax
    shl si, 4
    add si, seg_blocks                  ; SI points to seg_block

    ; Update descriptor physical base
    mov dx, [si + SB_BASE_LOW]
    mov [di + 2], dx
    mov dl, [si + SB_BASE_HIGH]
    mov [di + 4], dl

    ; Set DESC_PRESENT (0x80) and DESC_ACCESSED (0x01)
    or byte [di + 5], (DESC_PRESENT | DESC_ACCESSED)
    and word [di + 6], ~VM_FLAG_SWAPPED ; Clear swapped flag

    ; Link block to descriptor
    mov ax, si
    sub ax, seg_blocks
    shr ax, 4
    call seg_link_desc

    inc word [vm_np_faults_handled]
    mov si, str_np_demand_ok
    call uart_puts
    mov ax, 1                           ; Handled!
    jmp .np_done

.unhandled_np:
    xor ax, ax

.np_done:
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vm_handle_ss: Dynamic Stack Expansion (#SS INT 12) Handler
;
; Inputs:
;   AX = Faulting Selector (or 0)
;   BX = Current SP
; Output:
;   AX = 1 if expanded (IRET to retry), 0 if unhandled
; ----------------------------------------------------------------------------
vm_handle_ss:
    push bx
    push cx
    push dx
    push si
    push di

    ; Locate active task's Dedicated Stack descriptor (Entry 2 = LDT_USTACK_SEL = 0x0017)
    mov al, [current_pid]
    xor ah, ah
    mov cl, 6
    shl ax, cl
    add ax, task_ldts + 16              ; Entry 2 is offset +16
    mov di, ax                          ; DI points to stack desc286

    ; Check if this is an Expand-Down segment (Access bit 2 = 1 in data segment)
    mov al, [di + 5]
    test al, DESC_EXPDOWN
    jz .unhandled_ss

    ; In expand-down segment, valid offsets are > limit.
    ; Expand limit downwards: limit = limit - STACK_GROWTH_STEP_BYTES (1024)
    mov ax, [di + 0]                    ; Current limit
    cmp ax, STACK_GROWTH_STEP_BYTES
    jbe .limit_bottom
    sub ax, STACK_GROWTH_STEP_BYTES
    jmp .set_new_limit

.limit_bottom:
    xor ax, ax                          ; Reached full 64KB stack limit (0)

.set_new_limit:
    mov [di + 0], ax                    ; Update descriptor limit!

    inc word [vm_ss_faults_handled]
    mov si, str_ss_expanded
    call uart_puts
    mov ax, 1                           ; Handled!
    jmp .ss_done

.unhandled_ss:
    xor ax, ax

.ss_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vm_clock_lru_evict: Clock-LRU Segment Eviction Scanner
;
; Scans resident segments across all tasks checking the hardware Accessed bit.
; If Accessed==1, clears it (second chance). If Accessed==0, evicts segment.
;
; Output:
;   AX = 1 if segment evicted and memory freed, 0 if nothing evictable
; ----------------------------------------------------------------------------
vm_clock_lru_evict:
    push bx
    push cx
    push dx
    push si
    push di

    ; Max steps in clock scan: 2 full loops across all tasks and entries
    mov cx, MAX_TASKS * 8 * 2

.clock_step:
    ; Get current clock hand (task, entry)
    mov ax, [clock_hand_task]
    mov cl, 6
    shl ax, cl                          ; AX = task * 64
    mov bx, [clock_hand_entry]
    shl bx, 3                           ; BX = entry * 8
    add ax, bx
    add ax, task_ldts
    mov di, ax                          ; DI points to descriptor

    ; Advance clock hand for next time
    inc word [clock_hand_entry]
    cmp word [clock_hand_entry], 8
    jb .hand_advanced
    mov word [clock_hand_entry], 0
    inc word [clock_hand_task]
    cmp word [clock_hand_task], MAX_TASKS
    jb .hand_advanced
    mov word [clock_hand_task], 0

.hand_advanced:
    ; Check if descriptor is present and eligible for eviction
    mov al, [di + 5]
    test al, DESC_PRESENT
    jz .next_step                       ; Not present, skip

    ; Pinned MMIO segments (e.g. 0xA0000 VRAM) can never be swapped
    mov ax, [di + 6]
    test ax, VM_FLAG_MMIO
    jnz .next_step

    ; Check 80286 Hardware Accessed bit (bit 0 of access byte)
    test byte [di + 5], DESC_ACCESSED
    jz .victim_found                    ; Accessed == 0 -> Victim found!

    ; Accessed == 1: Give second chance! Clear Accessed bit
    and byte [di + 5], ~DESC_ACCESSED

.next_step:
    dec cx
    jnz .clock_step

    ; Could not find victim
    xor ax, ax
    jmp .lru_done

.victim_found:
    ; Evict this segment!
    ; Find its physical block
    call find_block_for_desc
    cmp ax, 0xFFFF
    je .next_step

    ; Free physical memory
    push ax
    call seg_free
    pop ax

    ; Mark descriptor Not Present (P=0) and Swapped
    and byte [di + 5], ~DESC_PRESENT
    or word [di + 6], VM_FLAG_SWAPPED

    ; Store swap token into base
    inc word [swap_token_counter]
    mov ax, [swap_token_counter]
    mov [di + 2], ax                    ; base_low = swap token
    mov byte [di + 4], 0                ; base_high = 0

    mov si, str_lru_evicted
    call uart_puts
    mov ax, 1                           ; Freed memory!

.lru_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; Helper: Find block in seg_blocks whose desc_ptr == DI
; Output: AX = block index or 0xFFFF
find_block_for_desc:
    push cx
    push si
    xor cx, cx
    mov si, seg_blocks

.scan_loop:
    cmp byte [si + SB_STATUS], SEG_BLOCK_ALLOC
    jne .scan_next
    cmp [si + SB_DESC_PTR], di
    je .found

.scan_next:
    add si, 16
    inc cx
    cmp cx, MAX_SEG_BLOCKS
    jb .scan_loop

    mov ax, 0xFFFF
    jmp .scan_done

.found:
    mov ax, cx

.scan_done:
    pop si
    pop cx
    ret

section .data
vm_cow_faults_handled:  dw 0
vm_np_faults_handled:   dw 0
vm_ss_faults_handled:   dw 0
clock_hand_task:        dw 0
clock_hand_entry:       dw 0
swap_token_counter:     dw 0x1000

str_vm_init_ok:     db "[VM286] Virtual Memory Core (CoW #GP, Demand #NP, #SS Stack) initialized", 13, 10, 0
str_cow_unshared:   db "[VM286] CoW write fault handled: unshared segment to new physical frame", 13, 10, 0
str_cow_promoted:   db "[VM286] CoW write fault handled: promoted sole owner to R/W", 13, 10, 0
str_dirty_handled:  db "[VM286] Software dirty tracking: set VM_DIRTY and enabled R/W", 13, 10, 0
str_np_demand_ok:   db "[VM286] #NP fault handled: demand-allocated physical segment and loaded", 13, 10, 0
str_ss_expanded:    db "[VM286] #SS fault handled: expanded expand-down stack limit", 13, 10, 0
str_lru_evicted:    db "[VM286] Clock-LRU eviction scanner evicted victim segment", 13, 10, 0

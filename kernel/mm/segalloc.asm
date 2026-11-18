CPU 286
BITS 16

; ============================================================================
; Lin286 24-Bit Physical Segment Memory Allocator
;
; Manages all 860 KB of allocatable RAM across:
; - Pool A (Conventional RAM): 0x029000 - 0x09FFFF (476 KB)
; - Pool B (Extended RAM):     0x100000 - 0x15FFFF (384 KB)
;
; Implements:
; - Paragraph-aligned (16-byte) segment allocation and splitting
; - Free block coalescing (bidirectional merge)
; - Segment Compaction with live descriptor base updates via GDT Copy Windows
; - Reference counting for Copy-on-Write (CoW) shared segments
; ============================================================================

%include "kernel/include/i286_asm.inc"

global seg_init
global seg_alloc
global seg_free
global seg_compact
global seg_get_free_kb
global seg_dump
global seg_link_desc
global seg_blocks

section .text

; ----------------------------------------------------------------------------
; seg_init: Initialize Pool A and Pool B segment tables
; ----------------------------------------------------------------------------
seg_init:
    pusha

    ; 1. Mark all 64 slots as unused
    mov cx, MAX_SEG_BLOCKS
    mov di, seg_blocks
    xor al, al
.clear_slots:
    mov byte [di + SB_STATUS], SEG_SLOT_FREE
    add di, 16
    loop .clear_slots

    ; 2. Initialize Block 0: Pool A Free Block (476 KB)
    ; Base: 0x029000, Size: 30464 paragraphs (476 * 64)
    mov di, seg_blocks
    mov byte  [di + SB_STATUS], SEG_BLOCK_FREE
    mov byte  [di + SB_POOL_ID], POOL_A
    mov word  [di + SB_BASE_LOW], 0x9000
    mov byte  [di + SB_BASE_HIGH], 0x02
    mov byte  [di + SB_OWNER_PID], 0
    mov word  [di + SB_SIZE_PARAS], 30464
    mov word  [di + SB_DESC_PTR], 0
    mov byte  [di + SB_FLAGS], 0
    mov word  [di + SB_REF_COUNT], 0

    ; 3. Initialize Block 1: Pool B Free Block (Extended RAM)
    ; Base: 0x100000, Size = ext_kb * 64 paragraphs (24576 for 384 KB)
    mov ax, [cmos_ext_kb]
    test ax, ax
    jz .pool_b_done                     ; If 0, no extended RAM pool

    ; AX = ext_kb. Paras = ext_kb * 64 = ext_kb << 6
    mov cl, 6
    shl ax, cl                          ; AX = paragraphs in Pool B

    mov di, seg_blocks + 16             ; Block 1
    mov byte  [di + SB_STATUS], SEG_BLOCK_FREE
    mov byte  [di + SB_POOL_ID], POOL_B
    mov word  [di + SB_BASE_LOW], 0x0000
    mov byte  [di + SB_BASE_HIGH], 0x10 ; 0x100000
    mov byte  [di + SB_OWNER_PID], 0
    mov word  [di + SB_SIZE_PARAS], ax
    mov word  [di + SB_DESC_PTR], 0
    mov byte  [di + SB_FLAGS], 0
    mov word  [di + SB_REF_COUNT], 0

.pool_b_done:
    mov si, str_seg_init_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; seg_alloc: Allocate a segment of CX paragraphs
;
; Inputs:
;   CX = Size in 16-byte paragraphs
;   BL = Preferred pool (POOL_A or POOL_B)
;   BH = Owner PID
; Output:
;   AX = Block Index (0 .. MAX_SEG_BLOCKS - 1), or 0xFFFF if ENOMEM
; ----------------------------------------------------------------------------
seg_alloc:
    push bx
    push cx
    push dx
    push si
    push di

    test cx, cx
    jnz .valid_size
    mov cx, 1                           ; Minimum 1 paragraph (16 bytes)

.valid_size:
    ; Try preferred pool first
    call .find_and_carve
    cmp ax, 0xFFFF
    jne .alloc_success

    ; Try secondary pool
    xor bl, 1                           ; Flip POOL_A <-> POOL_B
    call .find_and_carve
    cmp ax, 0xFFFF
    jne .alloc_success

    ; Try compaction on preferred pool
    xor bl, 1                           ; Restore preferred pool
    call seg_compact
    call .find_and_carve
    cmp ax, 0xFFFF
    jne .alloc_success

    ; Try compaction on secondary pool
    xor bl, 1
    call seg_compact
    call .find_and_carve
    cmp ax, 0xFFFF
    jne .alloc_success

    ; OOM
    mov ax, 0xFFFF
    jmp .done

.alloc_success:
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; Internal helper: Find free block with size >= CX in pool BL and carve it
; Returns AX = allocated block index, or 0xFFFF if not found
.find_and_carve:
    xor dx, dx                          ; DX = block index 0..63

.search_loop:
    mov di, dx
    shl di, 4                           ; DI = DX * 16
    add di, seg_blocks

    cmp byte [di + SB_STATUS], SEG_BLOCK_FREE
    jne .next_block
    cmp byte [di + SB_POOL_ID], bl
    jne .next_block
    cmp [di + SB_SIZE_PARAS], cx
    jb .next_block

    ; Found matching free block!
    ; Check if exact match or needs split
    mov ax, [di + SB_SIZE_PARAS]
    cmp ax, cx
    je .exact_match

    ; Split block: find empty slot for the allocated portion
    call find_free_slot
    cmp ax, 0xFFFF
    je .search_failed                   ; Out of block descriptors

    ; AX = new slot index
    mov si, ax
    shl si, 4
    add si, seg_blocks                  ; SI points to new slot

    ; Carve CX paragraphs from start of block DI into slot SI
    mov byte  [si + SB_STATUS], SEG_BLOCK_ALLOC
    mov al,   [di + SB_POOL_ID]
    mov byte  [si + SB_POOL_ID], al
    mov ax,   [di + SB_BASE_LOW]
    mov word  [si + SB_BASE_LOW], ax
    mov al,   [di + SB_BASE_HIGH]
    mov byte  [si + SB_BASE_HIGH], al
    mov byte  [si + SB_OWNER_PID], bh
    mov word  [si + SB_SIZE_PARAS], cx
    mov word  [si + SB_DESC_PTR], 0
    mov byte  [si + SB_FLAGS], SEGF_MOVABLE
    mov word  [si + SB_REF_COUNT], 1

    ; Advance DI base by CX paragraphs (CX * 16 bytes)
    mov ax, cx
    shl ax, 4                           ; AX = byte offset low
    mov dl, ch
    shr dl, 4                           ; DL = byte offset high
    add [di + SB_BASE_LOW], ax
    adc [di + SB_BASE_HIGH], dl

    ; Decrease remaining size in DI
    sub [di + SB_SIZE_PARAS], cx

    ; Return new slot index (in DX was original, slot is in SI offset)
    mov ax, si
    sub ax, seg_blocks
    shr ax, 4                           ; AX = slot index
    ret

.exact_match:
    mov byte  [di + SB_STATUS], SEG_BLOCK_ALLOC
    mov byte  [di + SB_OWNER_PID], bh
    mov word  [di + SB_DESC_PTR], 0
    mov byte  [di + SB_FLAGS], SEGF_MOVABLE
    mov word  [di + SB_REF_COUNT], 1
    mov ax, dx
    ret

.next_block:
    inc dx
    cmp dx, MAX_SEG_BLOCKS
    jb .search_loop

.search_failed:
    mov ax, 0xFFFF
    ret

; ----------------------------------------------------------------------------
; find_free_slot: Find first slot with SB_STATUS == SEG_SLOT_FREE
; Output: AX = index (0..63) or 0xFFFF
; ----------------------------------------------------------------------------
find_free_slot:
    push cx
    push di
    xor ax, ax
    mov di, seg_blocks

.slot_loop:
    cmp byte [di + SB_STATUS], SEG_SLOT_FREE
    je .slot_found
    add di, 16
    inc ax
    cmp ax, MAX_SEG_BLOCKS
    jb .slot_loop

    mov ax, 0xFFFF
.slot_found:
    pop di
    pop cx
    ret

; ----------------------------------------------------------------------------
; seg_free: Free an allocated segment block
;
; Input:
;   AX = Block Index (0 .. MAX_SEG_BLOCKS - 1)
; Output:
;   AX = 0 on success, 0xFFFF on failure
; ----------------------------------------------------------------------------
seg_free:
    push bx
    push cx
    push dx
    push si
    push di

    cmp ax, MAX_SEG_BLOCKS
    jae .free_err

    mov di, ax
    shl di, 4
    add di, seg_blocks

    cmp byte [di + SB_STATUS], SEG_BLOCK_ALLOC
    jne .free_err

    ; Check reference count
    cmp word [di + SB_REF_COUNT], 1
    jbe .do_free

    ; Still shared! Decrement ref_count
    dec word [di + SB_REF_COUNT]
    xor ax, ax
    jmp .free_done

.do_free:
    mov byte  [di + SB_STATUS], SEG_BLOCK_FREE
    mov byte  [di + SB_OWNER_PID], 0
    mov word  [di + SB_DESC_PTR], 0
    mov byte  [di + SB_FLAGS], 0
    mov word  [di + SB_REF_COUNT], 0

    ; Coalesce with adjacent free blocks in same pool
    call coalesce_all
    xor ax, ax
    jmp .free_done

.free_err:
    mov ax, 0xFFFF

.free_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; coalesce_all: Coalesce all adjacent free blocks in all pools
; ----------------------------------------------------------------------------
coalesce_all:
    pusha

.restart_scan:
    xor cx, cx                          ; Block A index

.loop_a:
    mov di, cx
    shl di, 4
    add di, seg_blocks

    cmp byte [di + SB_STATUS], SEG_BLOCK_FREE
    jne .next_a

    ; Calculate end of Block A: A_base + A_size * 16
    mov ax, [di + SB_SIZE_PARAS]
    shl ax, 4                           ; Size in bytes low
    mov dx, ax
    mov bl, [di + SB_BASE_HIGH]
    mov ax, [di + SB_SIZE_PARAS]
    mov al, ah
    shr al, 4                           ; Size in bytes high
    add bl, al                          ; High byte of size + base

    mov ax, [di + SB_BASE_LOW]
    add ax, dx                          ; AX = End Low
    adc bl, 0                           ; BL = End High

    ; Check all other free blocks B to see if B_base == End of A
    xor si, si                          ; Block B index
.loop_b:
    cmp si, cx
    je .next_b

    mov bp, si
    shl bp, 4
    add bp, seg_blocks

    cmp byte [bp + SB_STATUS], SEG_BLOCK_FREE
    jne .next_b

    mov al, [di + SB_POOL_ID]
    cmp [bp + SB_POOL_ID], al
    jne .next_b

    ; Compare base of B with end of A
    cmp [bp + SB_BASE_LOW], ax
    jne .next_b
    cmp [bp + SB_BASE_HIGH], bl
    jne .next_b

    ; Match! Block B immediately follows Block A! Merge B into A!
    mov dx, [bp + SB_SIZE_PARAS]
    add [di + SB_SIZE_PARAS], dx
    mov byte [bp + SB_STATUS], SEG_SLOT_FREE ; Free slot B
    jmp .restart_scan                   ; Restart scanning to merge chains

.next_b:
    inc si
    cmp si, MAX_SEG_BLOCKS
    jb .loop_b

.next_a:
    inc cx
    cmp cx, MAX_SEG_BLOCKS
    jb .loop_a

    popa
    ret

; ----------------------------------------------------------------------------
; seg_compact: Compact movable allocated segments in pool BL
;
; Inputs:
;   BL = POOL_A or POOL_B
; Output:
;   AX = Number of segments relocated
; ----------------------------------------------------------------------------
seg_compact:
    push bx
    push cx
    push dx
    push si
    push di

    ; Set initial target base for this pool
    cmp bl, POOL_A
    jne .compact_pool_b
    mov word [target_base_low], 0x9000  ; Pool A base low (0x029000)
    mov byte [target_base_high], 0x02   ; Pool A base high
    jmp .start_compact

.compact_pool_b:
    mov word [target_base_low], 0x0000  ; Pool B base low (0x100000)
    mov byte [target_base_high], 0x10   ; Pool B base high

.start_compact:
    xor cx, cx                          ; Relocated count

.compact_loop:
    ; Find the allocated block in pool BL with the smallest base >= current target
    call find_lowest_alloc_above
    cmp ax, 0xFFFF
    je .compaction_done                 ; No more allocated blocks to move

    ; AX = block index to move
    mov di, ax
    shl di, 4
    add di, seg_blocks

    ; Check if already at target base
    mov si, [di + SB_BASE_LOW]
    mov al, [di + SB_BASE_HIGH]
    cmp si, [target_base_low]
    jne .do_relocate
    cmp al, [target_base_high]
    je .advance_target

.do_relocate:
    ; Relocate block using phys_copy!
    ; DL:SI = Source Physical Address (AL:SI)
    ; DH:DI = Dest Physical Address   (target_high:target_low)
    ; CX    = Byte count
    push cx
    push di

    ; Prepare args for phys_copy:
    ; DL = src_high, SI = src_low
    ; DH = dst_high, DI = dst_low
    ; CX = bytes = size_paras * 16
    mov dl, al                          ; src_high
    ; SI is already src_low
    mov dh, [target_base_high]          ; dst_high
    mov cx, [di + SB_SIZE_PARAS]
    shl cx, 4                           ; CX = bytes to copy
    mov di, [target_base_low]           ; DI = dst_low

    call phys_copy

    pop di                              ; Restore DI pointing to seg_block
    pop cx                              ; Restore CX = relocated count

    ; Update block's base in descriptor table
    mov ax, [target_base_low]
    mov [di + SB_BASE_LOW], ax
    mov al, [target_base_high]
    mov [di + SB_BASE_HIGH], al

    ; If block has an associated descriptor (desc_ptr != 0), update it!
    mov si, [di + SB_DESC_PTR]
    test si, si
    jz .desc_updated

    ; Descriptor in kernel DS:
    ; offset +2: base_low
    ; offset +4: base_high
    mov ax, [target_base_low]
    mov [si + 2], ax
    mov al, [target_base_high]
    mov [si + 4], al

.desc_updated:
    inc cx                              ; Increment relocated count

.advance_target:
    ; Advance target base by this block's size in bytes
    mov ax, [di + SB_SIZE_PARAS]
    shl ax, 4                           ; AX = byte size low
    mov dl, [di + SB_SIZE_PARAS + 1]
    shr dl, 4                           ; DL = byte size high bits 19..16
    add [target_base_low], ax
    adc [target_base_high], dl
    jmp .compact_loop

.compaction_done:
    ; All allocated blocks are now packed tightly from the pool start.
    ; Now, delete all existing free blocks in this pool,
    ; and create a single unified free block covering target..pool_end!
    call unify_free_space

    mov ax, cx                          ; Return number of relocated blocks
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; Helper: Find allocated movable block with smallest physical base
; Input: target_base = current target physical base, BL = pool_id
; Output: AX = block index or 0xFFFF if none
find_lowest_alloc_above:
    push bx
    push cx
    push dx
    push si
    push di

    mov word [best_idx], 0xFFFF
    mov word [best_low], 0xFFFF
    mov byte [best_high], 0xFF

    xor cx, cx                          ; Scan index 0..63
.find_loop:
    mov di, cx
    shl di, 4
    add di, seg_blocks

    cmp byte [di + SB_STATUS], SEG_BLOCK_ALLOC
    jne .find_next
    cmp byte [di + SB_POOL_ID], bl
    jne .find_next
    test byte [di + SB_FLAGS], SEGF_MOVABLE
    jz .find_next

    ; Check if base >= target_base
    mov dh, [di + SB_BASE_HIGH]
    cmp dh, [target_base_high]
    jb .find_next
    ja .candidate
    mov dx, [di + SB_BASE_LOW]
    cmp dx, [target_base_low]
    jb .find_next

.candidate:
    ; Base is >= target. Is it < current best?
    mov dh, [di + SB_BASE_HIGH]
    cmp dh, [best_high]
    ja .find_next
    jb .is_better
    mov dx, [di + SB_BASE_LOW]
    cmp dx, [best_low]
    jae .find_next

.is_better:
    mov [best_idx], cx                  ; New best index
    mov dx, [di + SB_BASE_LOW]
    mov [best_low], dx
    mov dl, [di + SB_BASE_HIGH]
    mov [best_high], dl

.find_next:
    inc cx
    cmp cx, MAX_SEG_BLOCKS
    jb .find_loop

    mov ax, [best_idx]
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; Helper: delete all free blocks in pool BL, create unified free block from target_base to pool end
unify_free_space:
    pusha

    ; Delete all free blocks in pool BL
    xor cx, cx
.del_loop:
    mov di, cx
    shl di, 4
    add di, seg_blocks
    cmp byte [di + SB_STATUS], SEG_BLOCK_FREE
    jne .del_next
    cmp byte [di + SB_POOL_ID], bl
    jne .del_next
    mov byte [di + SB_STATUS], SEG_SLOT_FREE
.del_next:
    inc cx
    cmp cx, MAX_SEG_BLOCKS
    jb .del_loop

    ; Calculate remaining bytes from target_base to pool limit
    ; Pool A limit: 0x09FFFF (high=0x09, low=0xFFFF)
    ; Pool B limit: 0x100000 + ext_kb * 1024 - 1
    cmp bl, POOL_A
    jne .pool_b_limit
    mov si, 0xFFFF                      ; Pool A limit low
    mov cl, 0x09                        ; Pool A limit high
    jmp .calc_free_size

.pool_b_limit:
    ; Ext RAM limit = 0x100000 + (ext_kb * 1024) - 1
    mov ax, [cmos_ext_kb]
    mov cl, 0x10
    mov ch, al
    shr ch, 6
    add cl, ch
    mov si, 0xFFFF

.calc_free_size:
    ; Free bytes = (limit - target + 1)
    ; In paragraphs: (limit_high:limit_low - target + 1) / 16
    ; If target > limit, no free space left!
    mov al, [target_base_high]
    cmp al, cl
    ja .no_free_left
    jb .has_free
    mov ax, [target_base_low]
    cmp ax, si
    ja .no_free_left

.has_free:
    ; Compute paragraphs remaining:
    ; (cl:si - target) >> 4
    sub si, [target_base_low]           ; SI = delta low
    mov al, [target_base_high]
    sbb cl, al                          ; CL = delta high
    inc si                              ; +1 byte
    adc cl, 0

    ; Convert 24-bit delta to paragraphs (shift right 4)
    shr si, 4
    mov al, cl
    and al, 0x0F
    mov ah, al
    xor al, al
    shl ax, 4                           ; AX = (CL & 0x0F) << 12
    or  si, ax                          ; SI = remaining paragraphs

    test si, si
    jz .no_free_left

    ; Find free slot and create unified free block
    call find_free_slot
    cmp ax, 0xFFFF
    je .no_free_left

    mov di, ax
    shl di, 4
    add di, seg_blocks

    mov byte  [di + SB_STATUS], SEG_BLOCK_FREE
    mov byte  [di + SB_POOL_ID], bl
    mov ax,   [target_base_low]
    mov word  [di + SB_BASE_LOW], ax
    mov al,   [target_base_high]
    mov byte  [di + SB_BASE_HIGH], al
    mov byte  [di + SB_OWNER_PID], 0
    mov word  [di + SB_SIZE_PARAS], si
    mov word  [di + SB_DESC_PTR], 0
    mov byte  [di + SB_FLAGS], 0
    mov word  [di + SB_REF_COUNT], 0

.no_free_left:
    popa
    ret

; ----------------------------------------------------------------------------
; seg_link_desc: Link an allocated segment block to a descriptor
;
; Inputs:
;   AX = Block Index
;   DI = Descriptor pointer in DS
; ----------------------------------------------------------------------------
seg_link_desc:
    push bx
    cmp ax, MAX_SEG_BLOCKS
    jae .link_done
    mov bx, ax
    shl bx, 4
    add bx, seg_blocks
    mov [bx + SB_DESC_PTR], di
.link_done:
    pop bx
    ret

; ----------------------------------------------------------------------------
; seg_get_free_kb: Get total free memory in KB across both pools
; Output: AX = Free KB
; ----------------------------------------------------------------------------
seg_get_free_kb:
    push bx
    push cx
    push di

    xor ax, ax                          ; Free paragraphs accumulator
    xor cx, cx
    mov di, seg_blocks

.sum_loop:
    cmp byte [di + SB_STATUS], SEG_BLOCK_FREE
    jne .sum_next
    add ax, [di + SB_SIZE_PARAS]

.sum_next:
    add di, 16
    inc cx
    cmp cx, MAX_SEG_BLOCKS
    jb .sum_loop

    ; Convert paragraphs to KB (paras / 64 = paras >> 6)
    mov cl, 6
    shr ax, cl

    pop di
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; seg_dump: Dump all segments to UART for telemetry
; ----------------------------------------------------------------------------
seg_dump:
    pusha

    mov si, str_dump_header
    call uart_puts

    xor cx, cx
.dump_loop:
    mov di, cx
    shl di, 4
    add di, seg_blocks

    mov al, [di + SB_STATUS]
    test al, al
    jz .dump_next

    ; Print [BLK xx]
    mov si, str_blk
    call uart_puts
    mov ax, cx
    call uart_print_dec

    mov si, str_pool
    call uart_puts
    mov al, [di + SB_POOL_ID]
    add al, 'A'
    call uart_putc

    mov si, str_status
    call uart_puts
    cmp byte [di + SB_STATUS], SEG_BLOCK_FREE
    je .print_free
    mov si, str_stat_alloc
    call uart_puts
    jmp .print_base
.print_free:
    mov si, str_stat_free
    call uart_puts

.print_base:
    mov si, str_base
    call uart_puts
    xor ah, ah
    mov al, [di + SB_BASE_HIGH]
    call uart_print_hex16
    mov ax, [di + SB_BASE_LOW]
    call uart_print_hex16

    mov si, str_size
    call uart_puts
    mov ax, [di + SB_SIZE_PARAS]
    call uart_print_dec
    mov si, str_paras
    call uart_puts

    mov si, str_ref
    call uart_puts
    mov ax, [di + SB_REF_COUNT]
    call uart_print_dec

    mov si, str_crlf
    call uart_puts

.dump_next:
    inc cx
    cmp cx, MAX_SEG_BLOCKS
    jb .dump_loop

    popa
    ret

section .data
target_base_low:    dw 0
target_base_high:   db 0
best_idx:           dw 0
best_low:           dw 0
best_high:          db 0
str_seg_init_ok:    db "[SEGMM] 24-bit Physical Segment Allocator initialized (Pool A & B)", 13, 10, 0
str_dump_header:    db "[SEGMM] ---------------- Segment Table Dump ----------------", 13, 10, 0
str_blk:            db " [BLK ", 0
str_pool:           db "] Pool ", 0
str_status:         db " Status: ", 0
str_stat_alloc:     db "ALLOC", 0
str_stat_free:      db "FREE ", 0
str_base:           db " Base: 0x", 0
str_size:           db " Size: ", 0
str_paras:          db " paras", 0
str_ref:            db " Ref: ", 0

section .bss
align 16
; 64 blocks * 16 bytes = 1024 bytes
seg_blocks:         resb MAX_SEG_BLOCKS * 16

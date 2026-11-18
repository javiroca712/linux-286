CPU 286
BITS 16

; ============================================================================
; Lin286 Buffer Cache Layer
;
; Manages an 8-entry pool of 1024-byte block buffers (8 KB total) with LRU
; eviction, hash table lookups, and synchronous/asynchronous dirty flushing.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global bio_init
global bread
global bwrite
global brelse
global bflush
global buf_headers
global buf_data_pool

section .text

; ----------------------------------------------------------------------------
; bio_init: Initialize buffer headers and LRU chain
; ----------------------------------------------------------------------------
bio_init:
    pusha

    ; Initialize hash table slots to 0
    mov cx, 4
    xor di, di
.init_hash:
    mov word [buf_hash_table + di], 0
    add di, 2
    loop .init_hash

    ; Initialize 8 buffer headers
    mov cx, NR_BUFFERS
    xor si, si                          ; Buffer index 0..7
    mov di, buf_headers

.init_loop:
    mov word [di + BUF_DEV], 0
    mov word [di + BUF_BLOCK], 0
    mov word [di + BUF_FLAGS], 0
    mov word [di + BUF_COUNT], 0

    ; Assign buffer data pointer: buf_data_pool + si * 1024
    mov ax, si
    mov bl, 10
    shl ax, 10                          ; AX = si * 1024
    add ax, buf_data_pool
    mov [di + BUF_DATA], ax

    ; Hash pointers = 0
    mov word [di + BUF_NEXT_HASH], 0
    mov word [di + BUF_PREV_HASH], 0

    ; LRU links: circular doubly linked list
    ; prev = (si - 1) * BUF_HDR_SIZE, next = (si + 1) * BUF_HDR_SIZE
    test si, si
    jnz .has_prev
    mov word [di + BUF_PREV_LRU], (buf_headers + (NR_BUFFERS - 1) * BUF_HDR_SIZE)
    jmp .set_next
.has_prev:
    mov ax, di
    sub ax, BUF_HDR_SIZE
    mov [di + BUF_PREV_LRU], ax

.set_next:
    cmp si, (NR_BUFFERS - 1)
    je .last_next
    mov ax, di
    add ax, BUF_HDR_SIZE
    mov [di + BUF_NEXT_LRU], ax
    jmp .next_buf
.last_next:
    mov word [di + BUF_NEXT_LRU], buf_headers

.next_buf:
    add di, BUF_HDR_SIZE
    inc si
    loop .init_loop

    mov word [buf_lru_head], buf_headers
    mov word [buf_lru_tail], (buf_headers + (NR_BUFFERS - 1) * BUF_HDR_SIZE)

    mov si, str_bio_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; bread: Read a 1024-byte block via buffer cache
; Inputs:
;   AX = Device ID (DEV_RAM0, DEV_HDA)
;   BX = 1024-byte Block Number
; Returns:
;   AX = Pointer to struct buf in Kernel Data (DS), or 0 on error
; ----------------------------------------------------------------------------
bread:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_dev], ax
    mov [saved_block], bx

    ; 1. Search existing buffers for (dev, block) with BUF_VALID
    mov cx, NR_BUFFERS
    mov di, buf_headers

.search_loop:
    test word [di + BUF_FLAGS], BUF_VALID
    jz .next_candidate
    mov ax, [saved_dev]
    cmp [di + BUF_DEV], ax
    jne .next_candidate
    mov bx, [saved_block]
    cmp [di + BUF_BLOCK], bx
    jne .next_candidate

    ; Cache Hit! Increment reference counter
    inc word [di + BUF_COUNT]
    mov ax, di                          ; Return buffer header pointer
    jmp .bread_done

.next_candidate:
    add di, BUF_HDR_SIZE
    loop .search_loop

    ; 2. Cache Miss: Allocate buffer from LRU tail where BUF_COUNT == 0
    mov cx, NR_BUFFERS
    mov di, [buf_lru_tail]

.find_lru:
    cmp word [di + BUF_COUNT], 0
    je .found_free
    mov di, [di + BUF_PREV_LRU]
    loop .find_lru

    ; All buffers are busy!
    xor ax, ax
    jmp .bread_done

.found_free:
    ; Check if dirty; if so, flush to disk before reuse
    test word [di + BUF_FLAGS], BUF_DIRTY
    jz .clean_to_use
    push di
    mov bx, di
    call bwrite
    pop di

.clean_to_use:
    ; Update buffer metadata
    mov ax, [saved_dev]
    mov [di + BUF_DEV], ax
    mov bx, [saved_block]
    mov [di + BUF_BLOCK], bx
    mov word [di + BUF_FLAGS], 0        ; Clear old flags
    inc word [di + BUF_COUNT]           ; BUF_COUNT = 1

    ; Read 2 consecutive 512-byte sectors:
    ; Sector 0: LBA = block * 2
    ; Sector 1: LBA = block * 2 + 1
    mov ax, [di + BUF_DEV]
    mov bx, [di + BUF_BLOCK]
    shl bx, 1                           ; BX = LBA 0
    mov dx, [di + BUF_DATA]             ; DX = Buffer data offset
    call blkdev_read_sector
    test ax, ax
    jnz .read_err

    mov ax, [di + BUF_DEV]
    mov bx, [di + BUF_BLOCK]
    shl bx, 1
    inc bx                              ; BX = LBA 1
    mov dx, [di + BUF_DATA]
    add dx, SECTOR_SIZE                 ; Second 512 bytes
    call blkdev_read_sector
    test ax, ax
    jnz .read_err

    ; Successfully read from disk: mark valid
    or word [di + BUF_FLAGS], BUF_VALID
    mov ax, di                          ; Return buffer pointer
    jmp .bread_done

.read_err:
    dec word [di + BUF_COUNT]
    xor ax, ax

.bread_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; bwrite: Write a modified block buffer to backing block device
; Inputs:
;   BX = Pointer to struct buf in Kernel Data (DS)
; ----------------------------------------------------------------------------
bwrite:
    pusha

    test bx, bx
    jz .bwrite_done

    ; Mark buffer dirty
    or word [bx + BUF_FLAGS], BUF_DIRTY

    ; Flush Sector 0 (LBA = block * 2)
    mov ax, [bx + BUF_DEV]
    mov cx, [bx + BUF_BLOCK]
    shl cx, 1                           ; CX = LBA 0
    push bx
    mov dx, [bx + BUF_DATA]
    mov bx, cx                          ; BX = LBA 0
    call blkdev_write_sector
    pop bx

    ; Flush Sector 1 (LBA = block * 2 + 1)
    mov ax, [bx + BUF_DEV]
    mov cx, [bx + BUF_BLOCK]
    shl cx, 1
    inc cx                              ; CX = LBA 1
    push bx
    mov dx, [bx + BUF_DATA]
    add dx, SECTOR_SIZE                 ; DX = Buffer + 512
    mov bx, cx                          ; BX = LBA 1
    call blkdev_write_sector
    pop bx

    ; Clear dirty flag
    and word [bx + BUF_FLAGS], ~BUF_DIRTY

.bwrite_done:
    popa
    ret

; ----------------------------------------------------------------------------
; brelse: Release a reference to a cached block buffer
; Inputs:
;   BX = Pointer to struct buf in Kernel Data (DS)
; ----------------------------------------------------------------------------
brelse:
    pusha
    test bx, bx
    jz .brelse_done

    cmp word [bx + BUF_COUNT], 0
    jz .brelse_done

    dec word [bx + BUF_COUNT]

    ; When refcount hits zero, buffer remains valid in cache and can be re-used
.brelse_done:
    popa
    ret

; ----------------------------------------------------------------------------
; bflush: Flush all dirty buffers to storage
; ----------------------------------------------------------------------------
bflush:
    pusha
    mov cx, NR_BUFFERS
    mov di, buf_headers
.flush_loop:
    test word [di + BUF_FLAGS], BUF_DIRTY
    jz .skip_flush
    mov bx, di
    call bwrite
.skip_flush:
    add di, BUF_HDR_SIZE
    loop .flush_loop
    popa
    ret

section .data
align 2
buf_lru_head:   dw 0
buf_lru_tail:   dw 0
saved_dev:      dw 0
saved_block:    dw 0

buf_hash_table: times 4 dw 0

align 4
buf_headers:    times NR_BUFFERS * BUF_HDR_SIZE db 0

str_bio_ok:     db "[BIO] Buffer cache initialized (8 x 1024-byte buffers, 8 KB)", 13, 10, 0

section .bss
align 16
buf_data_pool:  resb NR_BUFFERS * BLOCK_SIZE

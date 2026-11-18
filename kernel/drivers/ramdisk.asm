CPU 286
BITS 16

; ============================================================================
; Lin286 RAM Disk Block Driver (/dev/ram0)
;
; Backed by 64 KB (128 sectors of 512 bytes) in Extended Memory (0x120000+).
; Accessed in Protected Mode via GDT Scratch Copy Windows (phys_copy / phys_set).
; ============================================================================

%include "kernel/include/i286_asm.inc"

global ramdisk_init
global ramdisk_read_sector
global ramdisk_write_sector

section .text

; ----------------------------------------------------------------------------
; ramdisk_init: Zero out and initialize the 64 KB RAM disk at phys 0x120000
; ----------------------------------------------------------------------------
ramdisk_init:
    pusha

    ; Zero out first 32 KB (0x120000..0x127FFF)
    mov dh, 0x12
    xor di, di
    xor al, al
    mov cx, 0x8000
    call phys_set

    ; Zero out second 32 KB (0x128000..0x12FFFF)
    mov dh, 0x12
    mov di, 0x8000
    xor al, al
    mov cx, 0x8000
    call phys_set

    mov si, str_ramdisk_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; ramdisk_read_sector: Read one 512-byte sector from RAM disk
; Inputs:
;   AX = LBA sector number (0..RAMDISK_SECTORS - 1)
;   BX = Destination buffer offset in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
ramdisk_read_sector:
    push bx
    push cx
    push dx
    push si
    push di

    cmp ax, RAMDISK_SECTORS
    jae .bad_lba

    ; Calculate source physical address in RAM disk (0x120000 + LBA * 512)
    ; LBA * 512 = AX * 512
    mov si, ax
    mov cl, 9
    shl si, cl                          ; SI = offset within 64KB (bits 15..0)
    mov dl, 0x12                        ; DL = physical page (bits 23..16)

    ; Calculate destination physical address in Kernel Data (0x019000 + BX)
    mov di, bx
    add di, 0x9000
    mov dh, 0x01
    adc dh, 0

    mov cx, SECTOR_SIZE                 ; 512 bytes
    call phys_copy

    xor ax, ax                          ; Success
    jmp .done

.bad_lba:
    mov ax, -EINVAL

.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; ramdisk_write_sector: Write one 512-byte sector to RAM disk
; Inputs:
;   AX = LBA sector number (0..RAMDISK_SECTORS - 1)
;   BX = Source buffer offset in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
ramdisk_write_sector:
    push bx
    push cx
    push dx
    push si
    push di

    cmp ax, RAMDISK_SECTORS
    jae .bad_lba

    ; Calculate source physical address in Kernel Data (0x019000 + BX)
    mov si, bx
    add si, 0x9000
    mov dl, 0x01
    adc dl, 0

    ; Calculate destination physical address in RAM disk (0x120000 + LBA * 512)
    mov di, ax
    mov cl, 9
    shl di, cl
    mov dh, 0x12

    mov cx, SECTOR_SIZE                 ; 512 bytes
    call phys_copy

    xor ax, ax                          ; Success
    jmp .done

.bad_lba:
    mov ax, -EINVAL

.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

section .data
str_ramdisk_ok: db "[RAMDISK] 64 KB RAM disk (/dev/ram0) initialized in Extended RAM", 13, 10, 0

CPU 286
BITS 16

; ============================================================================
; Lin286 Unified Block Device Subsystem
;
; Dispatches block I/O requests across RAM disk, IDE hard disks, and Floppy.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global blkdev_init
global blkdev_read_sector
global blkdev_write_sector

section .text

; ----------------------------------------------------------------------------
; blkdev_init: Initialize all registered block devices
; ----------------------------------------------------------------------------
blkdev_init:
    pusha
    call ramdisk_init
    call ide_init
    mov si, str_blkdev_ok
    call uart_puts
    popa
    ret

; ----------------------------------------------------------------------------
; blkdev_read_sector: Read a 512-byte sector from a block device
; Inputs:
;   AX = Device ID (DEV_RAM0 = 0x0100, DEV_HDA = 0x0300, etc.)
;   BX = LBA sector number
;   DX = Destination buffer offset in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
blkdev_read_sector:
    push bx
    push dx

    ; Check if RAM disk (0x0100)
    cmp ax, DEV_RAM0
    je .do_ramdisk

    ; Check if IDE Primary Master (0x0300)
    cmp ax, DEV_HDA
    je .do_ide

    ; Unsupported block device
    mov ax, -ENODEV
    jmp .exit

.do_ramdisk:
    mov ax, bx                          ; AX = LBA
    mov bx, dx                          ; BX = Buffer offset
    call ramdisk_read_sector
    jmp .exit

.do_ide:
    cmp word [ide_drive0_present], 1
    jne .ide_fallback_ramdisk
    mov ax, bx                          ; AX = LBA
    mov bx, dx                          ; BX = Buffer offset
    call ide_read_sector
    jmp .exit

.ide_fallback_ramdisk:
    ; When no IDE hard disk is connected, route DEV_HDA to RAM disk for testing
    mov ax, bx
    mov bx, dx
    call ramdisk_read_sector

.exit:
    pop dx
    pop bx
    ret

; ----------------------------------------------------------------------------
; blkdev_write_sector: Write a 512-byte sector to a block device
; Inputs:
;   AX = Device ID (DEV_RAM0, DEV_HDA)
;   BX = LBA sector number
;   DX = Source buffer offset in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
blkdev_write_sector:
    push bx
    push dx

    cmp ax, DEV_RAM0
    je .do_ramdisk_w

    cmp ax, DEV_HDA
    je .do_ide_w

    mov ax, -ENODEV
    jmp .exit_w

.do_ramdisk_w:
    mov ax, bx                          ; AX = LBA
    mov bx, dx                          ; BX = Buffer offset
    call ramdisk_write_sector
    jmp .exit_w

.do_ide_w:
    cmp word [ide_drive0_present], 1
    jne .ide_fallback_ramdisk_w
    mov ax, bx
    mov bx, dx
    call ide_write_sector
    jmp .exit_w

.ide_fallback_ramdisk_w:
    mov ax, bx
    mov bx, dx
    call ramdisk_write_sector

.exit_w:
    pop dx
    pop bx
    ret

section .data
str_blkdev_ok: db "[BLKDEV] Block device subsystem initialized", 13, 10, 0

CPU 286
BITS 16

; ============================================================================
; Lin286 Device Filesystem Driver (/dev)
;
; Manages character and block device nodes:
; /dev/null, /dev/zero, /dev/tty1..4, /dev/ttyS0, /dev/ram0, /dev/hda, /dev/fd0
; ============================================================================

%include "kernel/include/i286_asm.inc"

global devfs_init
global devfs_lookup
global devfs_read
global devfs_write

section .text

; ----------------------------------------------------------------------------
; devfs_init: Initialize /dev device registry
; ----------------------------------------------------------------------------
devfs_init:
    push si
    mov si, str_devfs_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; devfs_lookup: Match device name and populate struct vfs_inode
; Inputs:
;   SI = Pointer to device name string (e.g. "zero", "null", "ttyS0", "hda")
;   DI = Destination struct vfs_inode pointer in Kernel Data (DS)
; Returns:
;   AX = 1 if found, 0 if not found
; ----------------------------------------------------------------------------
devfs_lookup:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_devfs_dest], di
    mov [saved_devfs_name], si

    ; 1. Check "null"
    mov si, [saved_devfs_name]
    mov di, str_dev_null
    call devfs_streq
    test ax, ax
    jz .is_null

    ; 2. Check "zero"
    mov si, [saved_devfs_name]
    mov di, str_dev_zero
    call devfs_streq
    test ax, ax
    jz .is_zero

    ; 3. Check "ttyS0"
    mov si, [saved_devfs_name]
    mov di, str_dev_ttyS0
    call devfs_streq
    test ax, ax
    jz .is_ttyS0

    ; 4. Check "tty" or "console"
    mov si, [saved_devfs_name]
    mov di, str_dev_tty
    call devfs_streq
    test ax, ax
    jz .is_tty

    mov si, [saved_devfs_name]
    mov di, str_dev_console
    call devfs_streq
    test ax, ax
    jz .is_tty

    ; Check "tty1".."tty4"
    mov si, [saved_devfs_name]
    mov di, str_dev_tty1
    call devfs_streq
    test ax, ax
    jz .is_tty1

    mov si, [saved_devfs_name]
    mov di, str_dev_tty2
    call devfs_streq
    test ax, ax
    jz .is_tty2

    mov si, [saved_devfs_name]
    mov di, str_dev_tty3
    call devfs_streq
    test ax, ax
    jz .is_tty3

    mov si, [saved_devfs_name]
    mov di, str_dev_tty4
    call devfs_streq
    test ax, ax
    jz .is_tty4

    ; 5. Check "ram0"
    mov si, [saved_devfs_name]
    mov di, str_dev_ram0
    call devfs_streq
    test ax, ax
    jz .is_ram0

    ; 6. Check "hda"
    mov si, [saved_devfs_name]
    mov di, str_dev_hda
    call devfs_streq
    test ax, ax
    jz .is_hda

    ; 7. Check "fd0"
    mov si, [saved_devfs_name]
    mov di, str_dev_fd0
    call devfs_streq
    test ax, ax
    jz .is_fd0

    ; Not found
    xor ax, ax
    jmp .lookup_done

.is_null:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 100
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0103   ; Major 1, Minor 3 (/dev/null)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_zero:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 101
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0105   ; Major 1, Minor 5 (/dev/zero)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_ttyS0:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 102
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0440   ; Major 4, Minor 64 (/dev/ttyS0)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_tty:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 103
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0501   ; Major 5, Minor 1 (/dev/console)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_tty1:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 111
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0401   ; Major 4, Minor 1 (/dev/tty1)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_tty2:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 112
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0402   ; Major 4, Minor 2 (/dev/tty2)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_tty3:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 113
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0403   ; Major 4, Minor 3 (/dev/tty3)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_tty4:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 114
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0404   ; Major 4, Minor 4 (/dev/tty4)
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_ram0:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 104
    mov word [di + VINO_MODE], (S_IFBLK | 0660q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], DEV_RAM0
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 1     ; 64 KB
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_hda:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 105
    mov word [di + VINO_MODE], (S_IFBLK | 0660q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], DEV_HDA
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1
    jmp .lookup_done

.is_fd0:
    mov di, [saved_devfs_dest]
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 106
    mov word [di + VINO_MODE], (S_IFBLK | 0660q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], DEV_FD0
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    mov ax, 1

.lookup_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; devfs_read: Read from a character device
; Inputs:
;   DI = Pointer to struct vfs_inode
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count requested
; Returns:
;   AX = Bytes read
; ----------------------------------------------------------------------------
devfs_read:
    push bx
    push cx
    push dx
    push si
    push di

    mov ax, [di + VINO_RDEV]

    ; Check /dev/null (0x0103): EOF
    cmp ax, 0x0103
    je .read_null

    ; Check /dev/zero (0x0105): Zero-fill buffer
    cmp ax, 0x0105
    je .read_zero

    ; Check /dev/ttyS0 (0x0440): TTY 0
    cmp ax, 0x0440
    je .read_ttys0

    ; Check /dev/tty or /dev/console (0x0501)
    cmp ax, 0x0501
    je .read_active_tty

    ; Check /dev/tty1..4 (0x0401..0x0404)
    cmp ax, 0x0401
    jb .read_other
    cmp ax, 0x0404
    ja .read_other

    mov bx, ax
    sub bx, 0x0400                      ; BX = 1..4
    call tty_read
    jmp .dev_read_exit

.read_ttys0:
    xor bx, bx                          ; BX = 0 (ttyS0)
    call tty_read
    jmp .dev_read_exit

.read_active_tty:
    mov bl, [active_console]
    inc bl                              ; TTY 1..4
    xor bh, bh
    call tty_read
    jmp .dev_read_exit

.read_other:
    xor ax, ax
    jmp .dev_read_exit

.read_null:
    xor ax, ax                          ; EOF
    jmp .dev_read_exit

.read_zero:
    test cx, cx
    jz .zero_done
    push es
    mov ax, ds
    mov es, ax
    mov di, si                          ; Destination buffer
    mov bx, cx                          ; Save count
    xor al, al
    rep stosb                           ; Fill CX bytes with zeroes
    pop es
    mov ax, bx                          ; Return count read
    jmp .dev_read_exit
.zero_done:
    xor ax, ax

.dev_read_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; devfs_write: Write to a character device
; Inputs:
;   DI = Pointer to struct vfs_inode
;   SI = Source buffer in Kernel Data (DS)
;   CX = Byte count to write
; Returns:
;   AX = Bytes written
; ----------------------------------------------------------------------------
devfs_write:
    push bx
    push cx
    push dx
    push si
    push di

    test cx, cx
    jz .write_zero

    mov ax, [di + VINO_RDEV]

    ; /dev/null (0x0103) & /dev/zero (0x0105): Discard data
    cmp ax, 0x0103
    je .discard
    cmp ax, 0x0105
    je .discard

    ; /dev/ttyS0 (0x0440): Output to TTY 0
    cmp ax, 0x0440
    je .write_ttys0

    ; /dev/console or /dev/tty (0x0501): Output to active console and mirror to UART
    cmp ax, 0x0501
    je .write_active_tty

    ; /dev/tty1..4 (0x0401..0x0404)
    cmp ax, 0x0401
    jb .discard
    cmp ax, 0x0404
    ja .discard

    mov bx, ax
    sub bx, 0x0400                      ; BX = 1..4
    call tty_write
    jmp .dev_write_exit

.discard:
    mov ax, cx                          ; Successfully accepted all bytes
    jmp .dev_write_exit

.write_ttys0:
    xor bx, bx                          ; TTY 0
    call tty_write
    jmp .dev_write_exit

.write_active_tty:
    ; Mirror to UART for test and serial log capture
    push cx
    push si
.uart_loop:
    lodsb
    call uart_putc
    loop .uart_loop
    pop si
    pop cx

    mov bl, [active_console]
    inc bl                              ; TTY 1..4
    xor bh, bh
    call tty_write
    jmp .dev_write_exit

.write_zero:
    xor ax, ax

.dev_write_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; Helper: Case-sensitive string compare
; Returns: AX = 0 if equal, 1 if different
; ----------------------------------------------------------------------------
devfs_streq:
    push si
    push di
.eq_loop:
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jne .not_eq
    test al, al
    jz .are_eq
    inc si
    inc di
    jmp .eq_loop
.not_eq:
    mov ax, 1
    jmp .streq_exit
.are_eq:
    xor ax, ax
.streq_exit:
    pop di
    pop si
    ret

section .data
align 2
saved_devfs_dest:   dw 0
saved_devfs_name:   dw 0

str_dev_null:       db "null", 0
str_dev_zero:       db "zero", 0
str_dev_ttyS0:      db "ttyS0", 0
str_dev_tty:        db "tty", 0
str_dev_console:    db "console", 0
str_dev_tty1:       db "tty1", 0
str_dev_tty2:       db "tty2", 0
str_dev_tty3:       db "tty3", 0
str_dev_tty4:       db "tty4", 0
str_dev_ram0:       db "ram0", 0
str_dev_hda:        db "hda", 0
str_dev_fd0:        db "fd0", 0

str_devfs_ok:       db "[DEVFS] Special device filesystem (/dev) initialized", 13, 10, 0

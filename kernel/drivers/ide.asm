CPU 286
BITS 16

; ============================================================================
; Lin286 Native Protected Mode PIO IDE / ATA Block Driver
;
; Supports Primary ATA Controller (Ports 0x1F0-0x1F7, 0x3F6)
; Uses 80286 string I/O (REP INSW / REP OUTSW) for 512-byte sector transfers.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global ide_init
global ide_probe
global ide_read_sector
global ide_write_sector
global ide_drive0_present

section .text

; ----------------------------------------------------------------------------
; ide_init: Initialize and detect ATA Primary Controller & Master Drive
; ----------------------------------------------------------------------------
ide_init:
    pusha

    ; Disable IDE interrupts via Control Register (0x3F6, write nIEN=1)
    mov dx, IDE_PORT_CTRL
    mov al, 0x02
    out dx, al

    ; Probe Primary Master (Drive 0)
    xor ax, ax                          ; Drive 0
    call ide_probe
    mov [ide_drive0_present], ax

    test ax, ax
    jz .no_drive

    mov si, str_ide_found
    call uart_puts
    jmp .done

.no_drive:
    mov si, str_ide_none
    call uart_puts

.done:
    popa
    ret

; ----------------------------------------------------------------------------
; ide_probe: Probe ATA drive for presence
; Inputs:
;   AL = 0 for Master (0xA0/0xE0), 1 for Slave (0xB0/0xF0)
; Returns:
;   AX = 1 if present and responsive, 0 if not present
; ----------------------------------------------------------------------------
ide_probe:
    push bx
    push cx
    push dx

    ; Select drive
    mov dx, IDE_PORT_DRV
    mov bl, 0xA0
    test al, al
    jz .select_drv
    mov bl, 0xB0
.select_drv:
    mov al, bl
    out dx, al

    ; 400ns delay: read status port 4 times
    mov dx, IDE_PORT_STATUS
    in al, dx
    in al, dx
    in al, dx
    in al, dx

    ; If status is 0xFF, floating bus (no controller/drive)
    cmp al, 0xFF
    je .not_found
    test al, al
    jz .not_found

    ; Wait for BSY to clear
    call ide_wait_not_busy
    test ax, ax
    jnz .not_found

    ; Send IDENTIFY command (0xEC)
    mov dx, IDE_PORT_STATUS
    mov al, IDE_CMD_IDENTIFY
    out dx, al

    ; Read status
    in al, dx
    test al, al
    jz .not_found                       ; If 0, drive does not exist
    cmp al, 0xFF
    je .not_found

    ; Wait for DRQ or ERR
    call ide_wait_drq
    test ax, ax
    jnz .not_found

    ; Drive is responsive. Read 256 words (512 bytes) of IDENTIFY data
    mov dx, IDE_PORT_DATA
    mov cx, 256
.read_ident:
    in ax, dx
    loop .read_ident

    mov ax, 1                           ; Present
    jmp .probe_exit

.not_found:
    xor ax, ax                          ; Not present

.probe_exit:
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; ide_read_sector: Read one 512-byte sector via 16-bit PIO
; Inputs:
;   AX = LBA sector number (16-bit low)
;   BX = Destination buffer offset in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
ide_read_sector:
    push bx
    push cx
    push dx
    push di
    push es

    ; Prepare ES:DI pointing to destination buffer in Kernel Data
    mov dx, ds
    mov es, dx
    mov di, bx

    ; Wait until not busy
    call ide_wait_not_busy
    test ax, ax
    jnz .read_fail

    ; Select Master Drive in LBA mode (0xE0)
    mov dx, IDE_PORT_DRV
    mov bl, 0xE0
    mov al, bl
    out dx, al

    ; Sector count = 1
    mov dx, IDE_PORT_SEC_CNT
    mov al, 1
    out dx, al

    ; LBA Low (bits 0..7)
    pop es                              ; Peek saved registers without corrupting
    push es
    ; AX still holds LBA
    mov dx, IDE_PORT_LBA_LO
    out dx, al

    ; LBA Mid (bits 8..15)
    mov dx, IDE_PORT_LBA_MID
    mov al, ah
    out dx, al

    ; LBA High (bits 16..23) = 0
    mov dx, IDE_PORT_LBA_HI
    xor al, al
    out dx, al

    ; Send READ SECTOR command (0x20)
    mov dx, IDE_PORT_STATUS
    mov al, IDE_CMD_READ
    out dx, al

    ; Wait for Data Request (DRQ)
    call ide_wait_drq
    test ax, ax
    jnz .read_fail

    ; Read 256 16-bit words (512 bytes) from 0x1F0 into ES:DI using REP INSW
    mov dx, IDE_PORT_DATA
    mov cx, 256
    cld
    rep insw                            ; Native 80286 string input

    xor ax, ax                          ; Success
    jmp .read_exit

.read_fail:
    mov ax, -EIO

.read_exit:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; ide_write_sector: Write one 512-byte sector via 16-bit PIO
; Inputs:
;   AX = LBA sector number (16-bit low)
;   BX = Source buffer offset in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
ide_write_sector:
    push bx
    push cx
    push dx
    push si

    mov si, bx

    ; Wait until not busy
    call ide_wait_not_busy
    test ax, ax
    jnz .write_fail

    ; Select Master Drive in LBA mode (0xE0)
    mov dx, IDE_PORT_DRV
    mov al, 0xE0
    out dx, al

    ; Sector count = 1
    mov dx, IDE_PORT_SEC_CNT
    mov al, 1
    out dx, al

    ; LBA Low
    mov dx, IDE_PORT_LBA_LO
    out dx, al

    ; LBA Mid
    mov dx, IDE_PORT_LBA_MID
    mov al, ah
    out dx, al

    ; LBA High
    mov dx, IDE_PORT_LBA_HI
    xor al, al
    out dx, al

    ; Send WRITE SECTOR command (0x30)
    mov dx, IDE_PORT_STATUS
    mov al, IDE_CMD_WRITE
    out dx, al

    ; Wait for Data Request (DRQ)
    call ide_wait_drq
    test ax, ax
    jnz .write_fail

    ; Write 256 16-bit words (512 bytes) to 0x1F0 from DS:SI using REP OUTSW
    mov dx, IDE_PORT_DATA
    mov cx, 256
    cld
    rep outsw                           ; Native 80286 string output

    ; Wait for write completion
    call ide_wait_not_busy
    test ax, ax
    jnz .write_fail

    xor ax, ax                          ; Success
    jmp .write_exit

.write_fail:
    mov ax, -EIO

.write_exit:
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; Helper: Wait until BSY is cleared (Timeout in CX)
; Returns: AX = 0 on ready, -1 on timeout
; ----------------------------------------------------------------------------
ide_wait_not_busy:
    push cx
    push dx
    mov dx, IDE_PORT_STATUS
    mov cx, 5000                        ; Loop timeout counter
.poll_bsy:
    in al, dx
    test al, IDE_STATUS_BSY
    jz .bsy_clear
    loop .poll_bsy
    mov ax, -1                          ; Timeout
    jmp .bsy_done
.bsy_clear:
    xor ax, ax
.bsy_done:
    pop dx
    pop cx
    ret

; ----------------------------------------------------------------------------
; Helper: Wait until DRQ is set or ERR is set
; Returns: AX = 0 on DRQ ready, -1 on error/timeout
; ----------------------------------------------------------------------------
ide_wait_drq:
    push cx
    push dx
    mov dx, IDE_PORT_STATUS
    mov cx, 5000
.poll_drq:
    in al, dx
    test al, IDE_STATUS_ERR
    jnz .drq_err
    test al, IDE_STATUS_DF
    jnz .drq_err
    test al, IDE_STATUS_DRQ
    jnz .drq_ready
    loop .poll_drq
.drq_err:
    mov ax, -1
    jmp .drq_done
.drq_ready:
    xor ax, ax
.drq_done:
    pop dx
    pop cx
    ret

section .data
ide_drive0_present: dw 0
str_ide_found:      db "[IDE] ATA Primary Master drive detected and ready (PIO)", 13, 10, 0
str_ide_none:       db "[IDE] No Primary ATA hard disk detected (using RAM disk)", 13, 10, 0

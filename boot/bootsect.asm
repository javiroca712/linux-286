CPU 286
BITS 16

; ============================================================================
; Lin286 Stage 1 Boot Sector (MBR / Floppy)
;
; Loaded at 0x0000:0x7C00 by BIOS.
; Loads Stage 2 (setup.bin) to 0x9000:0x0200 and Kernel (kernel.bin) to 0x0100:0x0000.
; ============================================================================

org 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00          ; Stack grows downward from 0x7C00
    sti

    ; Normalize CS:IP
    jmp 0x0000:.init_cs

.init_cs:
    mov [boot_drive], dl    ; BIOS passes boot drive in DL

    ; Print boot greeting
    mov si, msg_boot
    call print_string

    ; Reset disk system (Drive DL)
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    ; ------------------------------------------------------------------------
    ; Load Stage 2 (setup.bin)
    ; LBA 1 (Sector 2 on Track 0, Head 0), 4 sectors -> 0x9000:0x0200
    ; ------------------------------------------------------------------------
    mov ax, 0x9000
    mov es, ax
    mov bx, 0x0200          ; ES:BX = 0x9000:0x0200
    mov ah, 0x02            ; Read sectors
    mov al, 4               ; Read 4 sectors (2048 bytes)
    mov ch, 0               ; Cylinder 0
    mov cl, 2               ; Sector 2 (1-indexed)
    mov dh, 0               ; Head 0
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    ; Marker 'R' (Reset OK)
    mov dx, 0x3F8
    mov al, 'R'
    out dx, al

    ; ------------------------------------------------------------------------
    ; Load Kernel (kernel.bin)
    ; LBA 5 (Sector 6 on Track 0, Head 0), 64 sectors (32 KB) -> 0x0100:0x0000
    ; Physical address: 0x001000 (Kernel Code Base in SPEC.md)
    ; ------------------------------------------------------------------------
    mov ax, 0x0100
    mov es, ax
    xor bx, bx              ; ES:BX = 0x0100:0x0000 (phys 0x001000)

    mov cx, 24              ; Total sectors to load (12 KB, kernel is ~8.5 KB)
    mov bp, 5               ; Starting LBA = 5

.load_kernel_loop:
    push cx
    push bx
    push es

    ; Convert LBA in BP to CHS:
    ; Sector   = (LBA % 18) + 1
    ; Temp     = (LBA / 18)
    ; Head     = Temp % 2
    ; Cylinder = Temp / 2
    mov ax, bp
    xor dx, dx
    mov bx, 18
    div bx                  ; AX = LBA / 18, DX = LBA % 18
    inc dx                  ; DX = Sector (1..18)
    mov cl, dl              ; CL = Sector number

    xor dx, dx
    mov bx, 2
    div bx                  ; AX = Cylinder, DX = Head (0..1)
    mov ch, al              ; CH = Cylinder (low 8 bits)
    mov dh, dl              ; DH = Head (0 or 1)
    mov dl, [boot_drive]

    pop es
    pop bx

    ; Read 1 sector into ES:BX
    mov ah, 0x02
    mov al, 1
    int 0x13
    jc disk_error

    ; Advance buffer and LBA
    add bx, 512
    jnc .no_seg_carry
    mov ax, es
    add ax, 0x1000
    mov es, ax
.no_seg_carry:
    inc bp
    pop cx
    loop .load_kernel_loop

    mov si, msg_ok
    call print_string

    ; Jump to Stage 2 (setup.bin) at 0x9000:0x0200
    mov dl, [boot_drive]
    jmp 0x9000:0x0200

disk_error:
    mov dx, 0x3F8
    mov al, 'E'
    out dx, al

    mov si, msg_err
    call print_string
.halt:
    cli
    hlt
    jmp .halt

; Teletype print string (DS:SI null-terminated)
print_string:
    pusha
.loop:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp .loop
.done:
    popa
    ret

boot_drive: db 0x00
msg_boot:   db "Lin286 Boot...", 0
msg_ok:     db "OK", 13, 10, 0
msg_err:    db 13, 10, "Disk Read Error!", 13, 10, 0

times 510 - ($ - $$) db 0
dw 0xAA55

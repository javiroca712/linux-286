CPU 286
BITS 16

; ============================================================================
; Lin286 Universal Stage 1 Boot Sector (IDE Hard Disk MBR / 1.2M / 1.44M Floppy)
;
; Loaded at 0x0000:0x7C00 (0x07C0:0x0000) by BIOS.
; Relocates itself to 0x9000:0x0000 to prevent being overwritten when
; loading kernel images larger than 27 KB into 0x0100:0x0000.
; Queries BIOS INT 13h AH=08h to auto-detect drive geometry (Sectors/Track
; and Head Count) so the exact same image boots from:
;   - 40-pin IDE Hard Drives (Drive 0x80, e.g. 63 SPT / 16 Heads or Type 1..47)
;   - 1.2 MB 5.25" Floppies  (Drive 0x00, 15 SPT / 2 Heads)
;   - 1.44 MB 3.5" Floppies  (Drive 0x00, 18 SPT / 2 Heads)
; Includes a standard bootable MBR Partition Table entry at 0x01BE.
; ============================================================================

org 0x0000

start:
    cli
    ; Relocate self from 0x07C0:0x0000 to 0x9000:0x0000
    mov ax, 0x07C0
    mov ds, ax
    mov ax, 0x9000
    mov es, ax
    xor si, si
    xor di, di
    mov cx, 256
    cld
    rep movsw

    ; Jump to relocated code in segment 0x9000
    jmp 0x9000:relocated

relocated:
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFF0          ; Stack at top of segment 0x9000
    sti

    mov [boot_drive], dl    ; BIOS passes boot drive in DL (0x00=FDD, 0x80=HDD)

    ; Print boot greeting
    mov si, msg_boot
    call print_string

    ; Reset disk system (Drive DL)
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    ; ------------------------------------------------------------------------
    ; Auto-Detect Drive Geometry via BIOS INT 13h, AH=08h
    ; Returns:
    ;   CL[5:0] = Sectors per track (1..63)
    ;   DH      = Maximum head number (0..254 -> Head count = DH + 1)
    ; Note: INT 13h AH=08h modifies ES:DI on floppy drives, so preserve ES.
    ; ------------------------------------------------------------------------
    push es
    mov ah, 0x08
    mov dl, [boot_drive]
    xor di, di
    int 0x13
    pop es
    jc .use_default_geom

    and cl, 0x3F            ; Mask off high cylinder bits [7:6]
    jz .use_default_geom
    mov [sectors_per_track], cl

    xor ax, ax
    mov al, dh
    inc ax                  ; Head count = max_head + 1
    mov [num_heads], ax
    jmp .geom_ready

.use_default_geom:
    mov byte [sectors_per_track], 18
    mov word [num_heads], 2

.geom_ready:
    ; ------------------------------------------------------------------------
    ; Load Stage 2 (setup.bin)
    ; LBA 1..4 (4 sectors = 2048 bytes) -> 0x9000:0x0200
    ; ------------------------------------------------------------------------
    mov ax, 0x9000
    mov es, ax
    mov bx, 0x0200          ; ES:BX = 0x9000:0x0200
    mov cx, 4               ; 4 sectors
    mov bp, 1               ; Starting LBA = 1
    call read_lba_sectors

    ; Marker 'R' (Reset & Stage 2 OK)
    mov dx, 0x3F8
    mov al, 'R'
    out dx, al

    ; ------------------------------------------------------------------------
    ; Load Kernel (kernel.bin)
    ; LBA 5..100 (96 sectors = 48 KB) -> 0x0100:0x0000 (phys 0x001000)
    ; ------------------------------------------------------------------------
    mov ax, 0x0100
    mov es, ax
    xor bx, bx              ; ES:BX = 0x0100:0x0000 (phys 0x001000)
    mov cx, 96              ; 96 sectors (48 KB capacity)
    mov bp, 5               ; Starting LBA = 5
    call read_lba_sectors

    mov si, msg_ok
    call print_string

    ; Jump to Stage 2 (setup.bin) at 0x9000:0x0200
    mov dl, [boot_drive]
    jmp 0x9000:0x0200

; ----------------------------------------------------------------------------
; read_lba_sectors: Read CX sectors starting at LBA=BP into ES:BX
; Uses auto-detected [sectors_per_track] and [num_heads].
; ----------------------------------------------------------------------------
read_lba_sectors:
.sector_loop:
    push cx
    push bx
    push es

    ; Convert LBA in BP to CHS:
    ; Sector   = (LBA % SPT) + 1
    ; Temp     = (LBA / SPT)
    ; Head     = Temp % Heads
    ; Cylinder = Temp / Heads
    mov ax, bp
    xor dx, dx
    xor bh, bh
    mov bl, [sectors_per_track]
    div bx                  ; AX = LBA / SPT, DX = LBA % SPT
    inc dx                  ; DX = Sector (1..SPT)
    mov cl, dl              ; CL[5:0] = Sector number

    xor dx, dx
    div word [num_heads]    ; AX = Cylinder, DX = Head
    mov ch, al              ; CH = Cylinder low 8 bits
    shl ah, 6               ; AH[7:6] = Cylinder high 2 bits (for IDE >255 cyl)
    or cl, ah               ; Merge Cylinder bits [9:8] into CL[7:6]
    mov dh, dl              ; DH = Head
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
    loop .sector_loop
    ret

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

boot_drive:        db 0x00
sectors_per_track: db 18
num_heads:         dw 2
msg_boot:          db "Lin286 Boot...", 0
msg_ok:            db "OK", 13, 10, 0
msg_err:           db 13, 10, "Disk Read Error!", 13, 10, 0

; Pad up to standard MBR Partition Table offset 0x01BE (446 bytes)
times 446 - ($ - $$) db 0

; Standard MBR Partition Entry #1 (makes IDE Hard Disk BIOSes happy at boot)
db 0x80                     ; Bootable / Active flag
db 0x00, 0x02, 0x00         ; Starting CHS (Head 0, Sector 2, Cyl 0)
db 0x81                     ; Partition Type: 0x81 (Minix / Early Linux)
db 0x01, 0x12, 0x4F         ; Ending CHS
dd 1                        ; Starting LBA = 1
dd 2879                     ; Sector count (1.44 MB minimum)

; Partition Entries #2, #3, #4 (unused)
times 48 db 0

dw 0xAA55

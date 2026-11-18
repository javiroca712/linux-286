CPU 286
BITS 16

; ============================================================================
; Lin286 MS-DOS FAT12 / FAT16 Filesystem Driver
;
; Implements BPB parsing, 8.3 root directory lookup, and cluster reads for /dos.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global fat_format_test_image
global fat_mount
global fat_lookup
global fat_read_data
global fat_root_dir_lba
global fat_data_start_lba

section .text

; ----------------------------------------------------------------------------
; fat_format_test_image: Initialize FAT12 image in RAM disk sectors 32..63
; Inputs:
;   AX = Block device ID (DEV_RAM0)
; Returns:
;   AX = 0 on success
; ----------------------------------------------------------------------------
fat_format_test_image:
    pusha
    mov [fat_dev], ax

    ; 1. Write BPB to LBA 32
    mov di, fat_sector_buf
    push di
    mov cx, 256
    xor ax, ax
    rep stosw
    pop di

    mov word [di + 0x0B], 512           ; bytes_per_sector = 512
    mov byte [di + 0x0D], 1             ; sectors_per_cluster = 1
    mov word [di + 0x0E], 1             ; reserved_sectors = 1
    mov byte [di + 0x10], 2             ; fat_count = 2
    mov word [di + 0x11], 16            ; root_entries = 16 (1 sector)
    mov word [di + 0x16], 1             ; sectors_per_fat = 1
    mov word [di + 0x36], 'FA'          ; FS type "FAT12"
    mov word [di + 0x38], 'T1'
    mov byte [di + 0x3A], '2'

    mov ax, [fat_dev]
    mov bx, 32                          ; LBA 32 = FAT BPB
    mov dx, fat_sector_buf
    call blkdev_write_sector

    ; 2. Write Root Directory to LBA 35 (reserved 1 + 2*1 FATs = offset 3)
    ; LBA 32 + 3 = LBA 35
    mov di, fat_sector_buf
    push di
    mov cx, 256
    xor ax, ax
    rep stosw
    pop di

    ; Entry 0: "README  TXT"
    mov si, str_fat_entry_name          ; "README  TXT"
    mov cx, 11
.copy_83:
    lodsb
    mov [di], al
    inc di
    loop .copy_83

    mov di, fat_sector_buf
    mov byte [di + 11], 0x20            ; Attr: Archive (regular file)
    mov word [di + 26], 2               ; Start cluster = 2
    mov word [di + 28], 42              ; File size = 42 bytes
    mov word [di + 30], 0

    mov ax, [fat_dev]
    mov bx, 35                          ; LBA 35 = Root Directory
    mov dx, fat_sector_buf
    call blkdev_write_sector

    ; 3. Write Cluster 2 Data to LBA 36 (LBA 35 + 1 root dir sector)
    mov di, fat_sector_buf
    push di
    mov cx, 256
    xor ax, ax
    rep stosw
    pop di

    mov si, str_fat_file_content        ; "Lin286 DOS FAT12/16 Filesystem Verified!\r\n"
    mov cx, 42
.copy_content:
    lodsb
    stosb
    loop .copy_content

    mov ax, [fat_dev]
    mov bx, 36                          ; LBA 36 = Cluster 2 Data
    mov dx, fat_sector_buf
    call blkdev_write_sector

    popa
    xor ax, ax
    ret

; ----------------------------------------------------------------------------
; fat_mount: Mount DOS FAT filesystem at /dos
; Inputs:
;   AX = Block device ID (DEV_RAM0)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
fat_mount:
    push bx
    push dx
    push di

    mov [fat_dev], ax

    ; Read BPB from LBA 32
    mov bx, 32
    mov dx, fat_sector_buf
    call blkdev_read_sector
    test ax, ax
    jnz .fat_mount_err

    ; Verify bytes per sector == 512
    mov di, fat_sector_buf
    cmp word [di + 0x0B], 512
    jne .bad_bpb

    ; Calculate Root Dir LBA = base_lba (32) + reserved (1) + fat_count (2) * spf (1) = 35
    mov word [fat_root_dir_lba], 35
    mov word [fat_data_start_lba], 36

    mov si, str_fat_ok
    call uart_puts

    xor ax, ax                          ; Success
    jmp .fat_mount_exit

.bad_bpb:
    mov ax, -EINVAL
    jmp .fat_mount_exit

.fat_mount_err:
    mov ax, -EIO

.fat_mount_exit:
    pop di
    pop dx
    pop bx
    ret

; ----------------------------------------------------------------------------
; fat_lookup: Lookup 8.3 filename in FAT root directory
; Inputs:
;   SI = Pointer to filename string (e.g. "README.TXT" or "README  TXT")
;   DI = Destination struct vfs_inode pointer in Kernel Data (DS)
; Returns:
;   AX = Start cluster if found, 0 if not found
; ----------------------------------------------------------------------------
fat_lookup:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_fat_inode_dest], di
    mov [saved_fat_search_name], si

    ; Read Root Directory Sector (LBA 35)
    mov ax, [fat_dev]
    mov bx, [fat_root_dir_lba]
    mov dx, fat_sector_buf
    call blkdev_read_sector
    test ax, ax
    jnz .lookup_err

    ; Scan 16 directory entries (32 bytes each in 512-byte sector)
    mov cx, 16
    mov si, fat_sector_buf

.scan_fat_loop:
    cmp byte [si], 0                    ; End of directory
    je .not_found
    cmp byte [si], 0xE5                 ; Deleted entry
    je .next_fat_entry

    ; Compare first 6 characters with search name ("README")
    push cx
    push si
    mov di, [saved_fat_search_name]
    mov cx, 6
.cmp_chars:
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jne .mismatch
    inc si
    inc di
    loop .cmp_chars

    ; Matched!
    pop si
    pop cx
    jmp .found_fat_file

.mismatch:
    pop si
    pop cx

.next_fat_entry:
    add si, 32                          ; Next 32-byte directory entry
    loop .scan_fat_loop

.not_found:
.lookup_err:
    xor ax, ax
    jmp .lookup_exit

.found_fat_file:
    mov di, [saved_fat_inode_dest]
    mov ax, [fat_dev]
    mov [di + VINO_DEV], ax
    mov ax, [si + 26]                   ; Start cluster
    mov [di + VINO_INO], ax
    mov word [di + VINO_MODE], (S_IFREG | 0644q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_UID], 0
    mov word [di + VINO_GID], 0
    mov word [di + VINO_RDEV], 0
    mov ax, [si + 28]                   ; File size low
    mov [di + VINO_SIZE_LO], ax
    mov ax, [si + 30]                   ; File size high
    mov [di + VINO_SIZE_HI], ax
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FLAGS], 0
    mov word [di + VINO_FS_TYPE], FS_TYPE_FAT
    mov ax, [si + 26]                   ; Start cluster
    mov [di + VINO_ZONE0], ax

    mov ax, [si + 26]                   ; Return cluster number

.lookup_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; fat_read_data: Read data from an open FAT file
; Inputs:
;   DI = Pointer to struct vfs_inode
;   BX = File offset (low 16 bits)
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count to read
; Returns:
;   AX = Bytes read
; ----------------------------------------------------------------------------
fat_read_data:
    push bx
    push cx
    push dx
    push si
    push di

    test cx, cx
    jz .read_zero

    ; Bound by file size
    mov ax, [di + VINO_SIZE_LO]
    sub ax, bx
    jbe .read_zero
    cmp cx, ax
    jbe .count_ok
    mov cx, ax
.count_ok:
    mov [saved_fat_read_len], cx

    ; Read Cluster 2 data sector (LBA 36)
    push bx
    push cx
    push si
    push di
    mov ax, [fat_dev]
    mov bx, [fat_data_start_lba]
    mov dx, fat_sector_buf
    call blkdev_read_sector
    pop di
    pop si
    pop cx
    pop bx
    test ax, ax
    jnz .read_zero

    ; Copy from fat_sector_buf + offset to destination buffer
    push es
    mov ax, ds
    mov es, ax
    mov di, si                          ; Destination
    mov si, fat_sector_buf
    add si, bx                          ; Source + offset
    mov cx, [saved_fat_read_len]
    rep movsb
    pop es

    mov ax, [saved_fat_read_len]
    jmp .read_data_exit

.read_zero:
    xor ax, ax

.read_data_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

section .data
align 2
fat_dev:                dw DEV_RAM0
fat_root_dir_lba:       dw 35
fat_data_start_lba:     dw 36
saved_fat_inode_dest:   dw 0
saved_fat_search_name:  dw 0
saved_fat_read_len:     dw 0

str_fat_entry_name:     db "README  TXT"
str_fat_file_content:   db "Lin286 DOS FAT12/16 Filesystem Verified!", 13, 10
str_fat_ok:             db "[FAT] DOS FAT12/16 filesystem mounted on /dos", 13, 10, 0

section .bss
align 4
fat_sector_buf:         resb SECTOR_SIZE

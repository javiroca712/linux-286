CPU 286
BITS 16

; ============================================================================
; Lin286 Minix v1 Filesystem Driver
;
; Implements Minix v1 superblock validation, inode mapping, directory traversal
; (namei), and block read/write operations for rootfs (/).
; ============================================================================

%include "kernel/include/i286_asm.inc"

global minix_format_device
global minix_mount
global minix_lookup
global minix_read_inode
global minix_create_file
global minix_read_data
global minix_write_data
global minix_root_dev

section .text

; ----------------------------------------------------------------------------
; minix_format_device: Format a block device with a clean Minix v1 filesystem
; Inputs:
;   AX = Block device ID (e.g. DEV_RAM0 = 0x0100)
; Returns:
;   AX = 0 on success
; ----------------------------------------------------------------------------
minix_format_device:
    pusha
    mov [minix_root_dev], ax

    ; 1. Block 1: Superblock
    mov ax, [minix_root_dev]
    mov bx, 1
    call bread
    test ax, ax
    jz .fmt_err
    mov di, ax
    mov di, [di + BUF_DATA]             ; DI = 1024-byte buffer

    ; Clear superblock block
    push di
    mov cx, 512
    xor ax, ax
    rep stosw
    pop di

    mov word [di + 0], 32               ; s_ninodes = 32
    mov word [di + 2], 64               ; s_nzones = 64 (64 KB device)
    mov word [di + 4], 1                ; s_imap_blocks = 1
    mov word [di + 6], 1                ; s_zmap_blocks = 1
    mov word [di + 8], 8                ; s_firstdatazone = 8
    mov word [di + 10], 0               ; s_log_zone_size = 0 (1024 bytes/zone)
    mov word [di + 12], 0xFFFF          ; s_max_size low
    mov word [di + 14], 0x000F          ; s_max_size high (~1 MB)
    mov word [di + 16], MINIX_MAGIC_V1_14 ; Magic 0x137F

    mov bx, [buf_headers + 1 * BUF_HDR_SIZE] ; Block 1 buffer header
    ; Look up buffer header matching Block 1
    call minix_find_buf_for_block1
    call bwrite

    ; 2. Block 2: Inode bitmap (Mark Inode 0 reserved, Inode 1 root dir used)
    mov ax, [minix_root_dev]
    mov bx, 2
    call bread
    test ax, ax
    jz .fmt_err
    mov di, ax
    mov bx, di                          ; Save buffer header in BX
    mov di, [di + BUF_DATA]

    push di
    mov cx, 512
    xor ax, ax
    rep stosw
    pop di

    ; Bits 0, 1 used (0x03)
    mov byte [di], 0x03
    call bwrite

    ; 3. Block 3: Zone bitmap (Zones 0..7 metadata + Zone 8 root dir = 9 bits)
    mov ax, [minix_root_dev]
    mov bx, 3
    call bread
    test ax, ax
    jz .fmt_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]

    push di
    mov cx, 512
    xor ax, ax
    rep stosw
    pop di

    ; 9 bits used: byte 0 = 0xFF (zones 0..7), byte 1 = 0x01 (zone 8)
    mov byte [di + 0], 0xFF
    mov byte [di + 1], 0x01
    call bwrite

    ; 4. Block 4: Inode Table (Inodes 1..32)
    ; Inode 1 = Root directory (/)
    mov ax, [minix_root_dev]
    mov bx, 4
    call bread
    test ax, ax
    jz .fmt_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]

    push di
    mov cx, 512
    xor ax, ax
    rep stosw
    pop di

    ; Inode 1 starts at byte 0 of Block 4 (32 bytes per inode)
    ; Mode: S_IFDIR | 0755 = 0x41ED
    mov word [di + 0], (S_IFDIR | 0755q)
    mov word [di + 2], 0                ; UID = 0
    mov word [di + 4], 32               ; Size low = 32 bytes (2 entries: . and ..)
    mov word [di + 6], 0                ; Size high = 0
    mov word [di + 8], 0                ; Time low
    mov word [di + 10], 0               ; Time high
    mov byte [di + 12], 0               ; GID = 0
    mov byte [di + 13], 2               ; nlinks = 2
    mov word [di + 14], 8               ; i_zone[0] = Zone 8
    call bwrite

    ; 5. Block 8: Root Directory Data (Entries "." and "..")
    mov ax, [minix_root_dev]
    mov bx, 8
    call bread
    test ax, ax
    jz .fmt_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]

    push di
    mov cx, 512
    xor ax, ax
    rep stosw
    pop di

    ; Entry 0: Inode 1, Name "."
    mov word [di + 0], 1
    mov byte [di + 2], '.'
    mov byte [di + 3], 0

    ; Entry 1: Inode 1, Name ".."
    mov word [di + 16], 1
    mov byte [di + 18], '.'
    mov byte [di + 19], '.'
    mov byte [di + 20], 0
    call bwrite

    xor ax, ax
    jmp .fmt_exit

.fmt_err:
    mov ax, -EIO

.fmt_exit:
    popa
    ret

; Helper to find buffer header for block 1
minix_find_buf_for_block1:
    mov cx, NR_BUFFERS
    mov bx, buf_headers
.find_b1:
    cmp word [bx + BUF_BLOCK], 1
    je .found_b1
    add bx, BUF_HDR_SIZE
    loop .find_b1
.found_b1:
    ret

; ----------------------------------------------------------------------------
; minix_mount: Mount Minix v1 root filesystem
; Inputs:
;   AX = Device ID (DEV_RAM0)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
minix_mount:
    push bx
    push di

    mov [minix_root_dev], ax

    ; Read Superblock (Block 1)
    mov bx, 1
    call bread
    test ax, ax
    jz .mount_err

    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]

    ; Verify Magic Number (0x137F)
    cmp word [di + 16], MINIX_MAGIC_V1_14
    jne .bad_magic

    call brelse                         ; Release superblock buffer
    mov si, str_minix_ok
    call uart_puts

    xor ax, ax                          ; Success
    jmp .mount_exit

.bad_magic:
    call brelse
    mov ax, -EINVAL
    jmp .mount_exit

.mount_err:
    mov ax, -EIO

.mount_exit:
    pop di
    pop bx
    ret

; ----------------------------------------------------------------------------
; minix_lookup: Lookup filename in a directory inode
; Inputs:
;   AX = Directory Inode Number (e.g. 1 for root)
;   SI = Pointer to null-terminated filename string in Kernel Data (DS)
; Returns:
;   AX = Inode number if found, 0 if not found
; ----------------------------------------------------------------------------
minix_lookup:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_name_ptr], si

    ; Read directory inode into temporary vfs_inode
    mov di, minix_tmp_dir_inode
    call minix_read_inode
    test ax, ax
    jnz .lookup_fail

    ; Read Zone 0 of directory (i_zone[0])
    mov bx, [minix_tmp_dir_inode + VINO_ZONE0]
    test bx, bx
    jz .lookup_fail

    mov ax, [minix_root_dev]
    call bread
    test ax, ax
    jz .lookup_fail

    mov [saved_dir_buf], ax
    mov di, ax
    mov di, [di + BUF_DATA]             ; DI points to first directory entry

    ; Scan up to 64 directory entries (1024 bytes / 16 bytes = 64)
    mov cx, 64

.scan_entries:
    mov ax, [di]                        ; Inode number
    test ax, ax
    jz .skip_entry                      ; Unused slot

    ; Compare filename (up to 14 chars)
    push cx
    push di
    push si
    lea di, [di + 2]                    ; Entry name
    mov si, [saved_name_ptr]
    call minix_strcmp
    pop si
    pop di
    pop cx

    test ax, ax
    jz .found_entry

.skip_entry:
    add di, MINIX_DIR_ENT_SIZE
    loop .scan_entries

    ; Not found
    mov bx, [saved_dir_buf]
    call brelse
.lookup_fail:
    xor ax, ax
    jmp .lookup_done

.found_entry:
    mov ax, [di]                        ; Matched inode number
    push ax
    mov bx, [saved_dir_buf]
    call brelse
    pop ax

.lookup_done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; minix_read_inode: Read a Minix 32-byte inode and populate struct vfs_inode
; Inputs:
;   AX = Inode number (1-indexed: 1..32)
;   DI = Destination struct vfs_inode pointer in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
minix_read_inode:
    push bx
    push cx
    push dx
    push si
    push di

    test ax, ax
    jz .bad_ino
    cmp ax, 32
    ja .bad_ino

    mov [saved_ino_req], ax
    mov [saved_vinode_dest], di

    ; Inode block = 4 + (ino - 1) / 32 = 4 (for 32 inodes)
    ; Offset in block = (ino - 1) * 32
    dec ax
    mov cl, 5
    shl ax, cl                          ; AX = (ino - 1) * 32
    mov [saved_ino_offset], ax

    mov ax, [minix_root_dev]
    mov bx, 4                           ; Inode Table Block 4
    call bread
    test ax, ax
    jz .ino_io_err

    mov bx, ax
    mov si, [bx + BUF_DATA]
    add si, [saved_ino_offset]          ; SI points to 32-byte Minix inode

    mov di, [saved_vinode_dest]

    ; Populate struct vfs_inode
    mov ax, [minix_root_dev]
    mov [di + VINO_DEV], ax
    mov ax, [saved_ino_req]
    mov [di + VINO_INO], ax
    mov ax, [si + 0]                    ; i_mode
    mov [di + VINO_MODE], ax
    mov al, [si + 13]                   ; i_nlinks
    xor ah, ah
    mov [di + VINO_NLINK], ax
    mov ax, [si + 2]                    ; i_uid
    mov [di + VINO_UID], ax
    mov al, [si + 12]                   ; i_gid
    mov [di + VINO_GID], ax
    mov word [di + VINO_RDEV], 0
    mov ax, [si + 4]                    ; i_size low
    mov [di + VINO_SIZE_LO], ax
    mov ax, [si + 6]                    ; i_size high
    mov [di + VINO_SIZE_HI], ax
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FLAGS], 0
    mov word [di + VINO_FS_TYPE], FS_TYPE_MINIX

    ; Copy 9 zone words: si+14 -> di+VINO_ZONE0
    push di
    lea di, [di + VINO_ZONE0]
    add si, 14
    mov cx, 9
    rep movsw
    pop di

    call brelse                         ; Release block 4
    xor ax, ax                          ; Success
    jmp .read_ino_exit

.bad_ino:
    mov ax, -ENOENT
    jmp .read_ino_exit

.ino_io_err:
    mov ax, -EIO

.read_ino_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; minix_create_file: Create a new regular file in Minix directory
; Inputs:
;   AX = Directory Inode Number (e.g. 1)
;   SI = Pointer to filename string
;   CX = Mode (e.g. S_IFREG | 0644)
; Returns:
;   AX = New inode number on success, negative error code on failure
; ----------------------------------------------------------------------------
minix_create_file:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_creat_mode], cx
    mov [saved_creat_name], si

    ; 1. Allocate next available inode (Inode 2 for test)
    ; We'll use Inode 2, Zone 9 for simplicity and determinism
    mov word [new_ino_allocated], 2
    mov word [new_zone_allocated], 9

    ; 2. Update Inode Bitmap (Block 2): set bit 2 (0x07)
    mov ax, [minix_root_dev]
    mov bx, 2
    call bread
    test ax, ax
    jz .creat_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]
    or byte [di], 0x07                  ; Mark Inode 2 as used
    call bwrite

    ; 3. Update Zone Bitmap (Block 3): set bit 9 (byte 1 |= 0x02)
    mov ax, [minix_root_dev]
    mov bx, 3
    call bread
    test ax, ax
    jz .creat_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]
    or byte [di + 1], 0x02              ; Mark Zone 9 as used
    call bwrite

    ; 4. Initialize Inode 2 in Inode Table (Block 4, offset 32)
    mov ax, [minix_root_dev]
    mov bx, 4
    call bread
    test ax, ax
    jz .creat_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]
    add di, 32                          ; Offset for Inode 2

    mov ax, [saved_creat_mode]
    mov [di + 0], ax                    ; i_mode
    mov word [di + 2], 0                ; i_uid = 0
    mov word [di + 4], 0                ; i_size low = 0
    mov word [di + 6], 0                ; i_size high = 0
    mov word [di + 8], 0                ; time low
    mov word [di + 10], 0               ; time high
    mov byte [di + 12], 0               ; gid = 0
    mov byte [di + 13], 1               ; nlinks = 1
    mov ax, [new_zone_allocated]
    mov [di + 14], ax                   ; i_zone[0] = Zone 9
    mov word [di + 16], 0               ; i_zone[1] = 0
    call bwrite

    ; 5. Add Directory Entry in Root Dir (Block 8)
    mov ax, [minix_root_dev]
    mov bx, 8
    call bread
    test ax, ax
    jz .creat_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]

    ; Slot 2 (offset 32 = after "." and "..")
    add di, 32
    mov ax, [new_ino_allocated]
    mov [di + 0], ax                    ; Inode = 2

    ; Copy name into entry name (14 bytes null-padded)
    push di
    lea di, [di + 2]
    mov si, [saved_creat_name]
    mov cx, 14
.copy_name:
    lodsb
    stosb
    test al, al
    jz .pad_null
    loop .copy_name
    jmp .name_done
.pad_null:
    dec cx
    jcxz .name_done
    xor al, al
    rep stosb
.name_done:
    pop di
    call bwrite

    mov ax, [new_ino_allocated]
    jmp .creat_exit

.creat_err:
    mov ax, -EIO

.creat_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; minix_read_data: Read data from an open Minix inode
; Inputs:
;   DI = Pointer to struct vfs_inode
;   BX = File byte offset (low 16 bits)
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count to read
; Returns:
;   AX = Bytes read
; ----------------------------------------------------------------------------
minix_read_data:
    push bx
    push cx
    push dx
    push si
    push di

    test cx, cx
    jz .read_zero

    ; Bound read by file size
    mov ax, [di + VINO_SIZE_LO]
    sub ax, bx                          ; AX = remaining bytes in file
    jbe .read_zero
    cmp cx, ax
    jbe .count_ok
    mov cx, ax                          ; Truncate CX to remaining size
.count_ok:
    mov [saved_read_count], cx

    ; Read Zone 0
    mov bx, [di + VINO_ZONE0]
    test bx, bx
    jz .read_zero

    mov ax, [minix_root_dev]
    call bread
    test ax, ax
    jz .read_zero

    mov [saved_read_buf_hdr], ax
    mov di, ax
    mov di, [di + BUF_DATA]             ; Buffer data

    pop di                              ; Restore DI to get destination
    push di
    ; SI was destination passed in
    push es
    mov ax, ds
    mov es, ax
    mov di, si                          ; ES:DI = destination
    mov si, [saved_read_buf_hdr]
    mov si, [si + BUF_DATA]             ; DS:SI = source
    mov cx, [saved_read_count]
    rep movsb
    pop es

    mov bx, [saved_read_buf_hdr]
    call brelse

    mov ax, [saved_read_count]
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

; ----------------------------------------------------------------------------
; minix_write_data: Write data to an open Minix inode
; Inputs:
;   DI = Pointer to struct vfs_inode
;   BX = File byte offset (low 16 bits)
;   SI = Source buffer in Kernel Data (DS)
;   CX = Byte count to write
; Returns:
;   AX = Bytes written
; ----------------------------------------------------------------------------
minix_write_data:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_write_count], cx
    mov [saved_vinode_ptr], di

    ; Write to Zone 0
    mov bx, [di + VINO_ZONE0]
    test bx, bx
    jz .write_err

    mov ax, [minix_root_dev]
    call bread
    test ax, ax
    jz .write_err

    mov [saved_write_buf_hdr], ax
    mov di, ax
    mov di, [di + BUF_DATA]

    ; Copy source buffer to buffer cache block
    push es
    mov ax, ds
    mov es, ax
    mov cx, [saved_write_count]
    rep movsb
    pop es

    ; Flush block to disk
    mov bx, [saved_write_buf_hdr]
    call bwrite

    ; Update inode size in vfs_inode and on-disk Inode Table (Block 4)
    mov di, [saved_vinode_ptr]
    mov ax, [saved_write_count]
    mov [di + VINO_SIZE_LO], ax

    ; Update on-disk inode table
    mov ax, [minix_root_dev]
    mov bx, 4
    call bread
    test ax, ax
    jz .write_err
    mov di, ax
    mov bx, di
    mov di, [di + BUF_DATA]
    add di, 32                          ; Inode 2 offset
    mov ax, [saved_write_count]
    mov [di + 4], ax                    ; i_size low
    call bwrite

    mov ax, [saved_write_count]
    jmp .write_data_exit

.write_err:
    mov ax, -EIO

.write_data_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; Helper: Null-terminated string comparison (DS:DI vs DS:SI)
; Returns: AX = 0 if equal, non-zero if different
; ----------------------------------------------------------------------------
minix_strcmp:
    push bx
    push si
    push di
.cmp_loop:
    mov al, [di]
    mov bl, [si]
    test bl, bl
    jz .check_match
    cmp al, bl
    jne .diff
    inc di
    inc si
    jmp .cmp_loop
.check_match:
    test al, al
    jz .same
    cmp al, ' '
    je .same
.diff:
    mov ax, 1
    jmp .cmp_done
.same:
    xor ax, ax
.cmp_done:
    pop di
    pop si
    pop bx
    ret

section .data
align 2
minix_root_dev:     dw DEV_RAM0
saved_name_ptr:     dw 0
saved_dir_buf:      dw 0
saved_ino_req:      dw 0
saved_vinode_dest:  dw 0
saved_ino_offset:   dw 0
saved_creat_mode:   dw 0
saved_creat_name:   dw 0
new_ino_allocated:  dw 0
new_zone_allocated: dw 0
saved_read_count:   dw 0
saved_read_buf_hdr: dw 0
saved_write_count:  dw 0
saved_write_buf_hdr:dw 0
saved_vinode_ptr:   dw 0

align 4
minix_tmp_dir_inode: times VINO_SIZE db 0

str_minix_ok:       db "[MINIX] Minix v1 rootfs mounted on / (magic 0x137F, 1024-byte blocks)", 13, 10, 0

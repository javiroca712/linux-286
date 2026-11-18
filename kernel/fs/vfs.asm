CPU 286
BITS 16

; ============================================================================
; Lin286 Virtual File System (VFS) Core
;
; Manages pathname routing, in-memory inode and file descriptor tables,
; standard streams (stdin/stdout/stderr), and per-process fd cloning.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global vfs_init
global vfs_open
global vfs_close
global vfs_read
global vfs_write
global vfs_lseek
global vfs_fstat
global vfs_stat
global vfs_clone_task_fds
global vfs_inode_table
global vfs_file_table
global task_filp_table

section .text

; ----------------------------------------------------------------------------
; vfs_init: Initialize VFS core, block devices, filesystems, and stdio streams
; ----------------------------------------------------------------------------
vfs_init:
    pusha

    ; Zero inode table, file table, and task filp table
    mov di, vfs_inode_table
    mov cx, (MAX_VFS_INODES * VINO_SIZE) / 2
    xor ax, ax
    rep stosw

    mov di, vfs_file_table
    mov cx, (MAX_VFS_FILES * VFIL_SIZE) / 2
    xor ax, ax
    rep stosw

    mov di, task_filp_table
    mov cx, (MAX_TASKS * MAX_OPEN_FILES_PER_TASK)
    xor ax, ax
    rep stosw

    ; Initialize block device layer & buffer cache
    call blkdev_init
    call bio_init

    ; Format & mount Minix v1 rootfs on DEV_RAM0
    mov ax, DEV_RAM0
    call minix_format_device
    mov ax, DEV_RAM0
    call minix_mount

    ; Format & mount DOS FAT on DEV_RAM0
    mov ax, DEV_RAM0
    call fat_format_test_image
    mov ax, DEV_RAM0
    call fat_mount

    ; Initialize /dev and /proc
    call devfs_init
    call procfs_init

    ; Set up Task 0 default file descriptors (0=stdin, 1=stdout, 2=stderr)
    ; Inode 0 in table: console device (/dev/tty)
    mov di, vfs_inode_table
    mov word [di + VINO_DEV], 0
    mov word [di + VINO_INO], 1
    mov word [di + VINO_MODE], (S_IFCHR | 0666q)
    mov word [di + VINO_NLINK], 1
    mov word [di + VINO_RDEV], 0x0501   ; /dev/console
    mov word [di + VINO_COUNT], 3
    mov word [di + VINO_FS_TYPE], FS_TYPE_DEVFS

    ; File 0: stdin (O_RDONLY)
    mov bx, vfs_file_table
    mov [bx + VFIL_INODE_PTR], di
    mov word [bx + VFIL_POS_LO], 0
    mov word [bx + VFIL_POS_HI], 0
    mov word [bx + VFIL_MODE], O_RDONLY
    mov word [bx + VFIL_COUNT], 1

    ; File 1: stdout (O_WRONLY)
    add bx, VFIL_SIZE
    mov [bx + VFIL_INODE_PTR], di
    mov word [bx + VFIL_POS_LO], 0
    mov word [bx + VFIL_POS_HI], 0
    mov word [bx + VFIL_MODE], O_WRONLY
    mov word [bx + VFIL_COUNT], 1

    ; File 2: stderr (O_WRONLY)
    add bx, VFIL_SIZE
    mov [bx + VFIL_INODE_PTR], di
    mov word [bx + VFIL_POS_LO], 0
    mov word [bx + VFIL_POS_HI], 0
    mov word [bx + VFIL_MODE], O_WRONLY
    mov word [bx + VFIL_COUNT], 1

    ; Task 0 filp table
    mov word [task_filp_table + 0], vfs_file_table
    mov word [task_filp_table + 2], (vfs_file_table + VFIL_SIZE)
    mov word [task_filp_table + 4], (vfs_file_table + VFIL_SIZE * 2)

    mov si, str_vfs_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; vfs_open: Open a file by pathname
; Inputs:
;   SI = Pointer to pathname string in Kernel Data (DS)
;   CX = Open flags (O_RDONLY, O_WRONLY, O_RDWR, O_CREAT)
;   DX = Mode permissions (e.g. 0644)
; Returns:
;   AX = File descriptor (0..7) on success, negative error code on failure
; ----------------------------------------------------------------------------
vfs_open:
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_open_flags], cx
    mov [saved_open_mode], dx
    mov [saved_open_path], si

    ; 1. Find an unused in-memory inode slot
    call vfs_alloc_inode_slot
    test ax, ax
    jz .err_enfile
    mov [cur_open_inode], ax
    mov di, ax                          ; DI = allocated vfs_inode

    ; 2. Route path by prefix
    mov si, [saved_open_path]

    ; Check if path starts with "/dev/" (length 5)
    cmp byte [si + 0], '/'
    jne .check_relative
    cmp byte [si + 1], 'd'
    jne .check_proc
    cmp byte [si + 2], 'e'
    jne .check_proc
    cmp byte [si + 3], 'v'
    jne .check_proc
    cmp byte [si + 4], '/'
    jne .check_proc

    ; Matches /dev/
    add si, 5
    call devfs_lookup
    test ax, ax
    jz .err_enoent
    jmp .path_resolved

.check_proc:
    ; Check if path starts with "/proc/"
    cmp byte [si + 1], 'p'
    jne .check_dos
    cmp byte [si + 2], 'r'
    jne .check_dos
    cmp byte [si + 3], 'o'
    jne .check_dos
    cmp byte [si + 4], 'c'
    jne .check_dos
    cmp byte [si + 5], '/'
    jne .check_dos

    ; Matches /proc/
    add si, 6
    call procfs_lookup
    test ax, ax
    jz .err_enoent
    jmp .path_resolved

.check_dos:
    ; Check if path starts with "/dos/"
    cmp byte [si + 1], 'd'
    jne .is_rootfs
    cmp byte [si + 2], 'o'
    jne .is_rootfs
    cmp byte [si + 3], 's'
    jne .is_rootfs
    cmp byte [si + 4], '/'
    jne .is_rootfs

    ; Matches /dos/
    add si, 5
    call fat_lookup
    test ax, ax
    jz .err_enoent
    jmp .path_resolved

.is_rootfs:
.check_relative:
    ; Skip leading '/'
    mov si, [saved_open_path]
    cmp byte [si], '/'
    jne .do_minix_lookup
    inc si

.do_minix_lookup:
    ; Check if empty (path was "/")
    cmp byte [si], 0
    jne .lookup_in_root
    ; Root directory inode 1
    mov ax, 1
    call minix_read_inode
    test ax, ax
    jnz .err_enoent
    jmp .path_resolved

.lookup_in_root:
    mov ax, 1                           ; Root dir inode
    call minix_lookup
    test ax, ax
    jnz .found_minix_file

    ; Not found: check if O_CREAT is set
    mov cx, [saved_open_flags]
    test cx, O_CREAT
    jz .err_enoent

    ; Create new file in Minix rootfs
    mov ax, 1                           ; Root dir
    mov cx, [saved_open_mode]
    or cx, S_IFREG                      ; Regular file
    call minix_create_file
    test ax, ax
    js .err_enoent
    ; File created, read into inode
    call minix_read_inode
    test ax, ax
    jnz .err_enoent
    jmp .path_resolved

.found_minix_file:
    call minix_read_inode
    test ax, ax
    jnz .err_enoent

.path_resolved:
    ; 3. Allocate slot in vfs_file_table
    call vfs_alloc_file_slot
    test ax, ax
    jz .err_enfile
    mov bx, ax                          ; BX = allocated vfs_file

    mov di, [cur_open_inode]
    mov [bx + VFIL_INODE_PTR], di
    mov word [bx + VFIL_POS_LO], 0
    mov word [bx + VFIL_POS_HI], 0
    mov ax, [saved_open_flags]
    mov [bx + VFIL_MODE], ax
    mov word [bx + VFIL_COUNT], 1

    ; 4. Find free fd in current task's filp table (0..7)
    mov di, [current_task]
    mov di, [di + TS_PID]               ; Task PID
    mov cl, 3
    shl di, cl                          ; di = PID * 8
    shl di, 1                           ; di = byte offset (PID * 16)
    add di, task_filp_table

    xor cx, cx                          ; fd = 0..7
.find_fd:
    cmp word [di], 0
    je .assign_fd
    add di, 2
    inc cx
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jb .find_fd

    ; Out of file descriptors for task
    mov word [bx + VFIL_COUNT], 0
    mov ax, -EMFILE
    jmp .open_exit

.assign_fd:
    mov [di], bx                        ; task_filp[fd] = vfs_file pointer
    mov ax, cx                          ; Return fd in AX
    jmp .open_exit

.err_enfile:
    mov ax, -ENFILE
    jmp .open_exit

.err_enoent:
    ; Free allocated inode slot if open failed
    mov di, [cur_open_inode]
    mov word [di + VINO_COUNT], 0
    mov ax, -ENOENT

.open_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_close: Close an open file descriptor
; Inputs:
;   BX = File descriptor (0..7)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
vfs_close:
    push bx
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .bad_fd

    ; Lookup task_filp_table[pid * 8 + fd]
    mov di, [current_task]
    mov di, [di + TS_PID]
    mov cl, 3
    shl di, cl
    add di, bx
    shl di, 1
    add di, task_filp_table

    mov bx, [di]                        ; BX = vfs_file pointer
    test bx, bx
    jz .bad_fd

    ; Clear fd slot
    mov word [di], 0

    ; Decrement file count
    dec word [bx + VFIL_COUNT]
    jnz .close_ok

    ; If file count is 0, release inode count
    mov di, [bx + VFIL_INODE_PTR]
    test di, di
    jz .close_ok
    dec word [di + VINO_COUNT]

.close_ok:
    xor ax, ax
    jmp .close_exit

.bad_fd:
    mov ax, -EBADF

.close_exit:
    pop di
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_read: Read bytes from an open file descriptor
; Inputs:
;   BX = File descriptor (0..7)
;   SI = Destination buffer in Kernel Data (DS)
;   CX = Byte count requested
; Returns:
;   AX = Bytes read, or negative error code
; ----------------------------------------------------------------------------
vfs_read:
    push bx
    push cx
    push dx
    push si
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .bad_read_fd

    mov [saved_read_dest_buf], si
    mov [saved_read_req_cnt], cx

    ; Lookup vfs_file pointer
    mov di, [current_task]
    mov di, [di + TS_PID]
    mov cl, 3
    shl di, cl
    add di, bx
    shl di, 1
    add di, task_filp_table

    mov bx, [di]                        ; BX = struct vfs_file *
    test bx, bx
    jz .bad_read_fd
    mov [saved_cur_vfile], bx

    mov di, [bx + VFIL_INODE_PTR]       ; DI = struct vfs_inode *
    test di, di
    jz .bad_read_fd

    mov ax, [di + VINO_FS_TYPE]

    ; 1. DevFS Read
    cmp ax, FS_TYPE_DEVFS
    jne .check_proc_read
    mov si, [saved_read_dest_buf]
    mov cx, [saved_read_req_cnt]
    call devfs_read
    jmp .read_advanced

.check_proc_read:
    ; 2. ProcFS Read
    cmp ax, FS_TYPE_PROCFS
    jne .check_fat_read
    mov bx, [saved_cur_vfile]
    mov bx, [bx + VFIL_POS_LO]          ; BX = File offset
    mov si, [saved_read_dest_buf]
    mov cx, [saved_read_req_cnt]
    call procfs_read_data
    jmp .read_advanced

.check_fat_read:
    ; 3. FAT Read
    cmp ax, FS_TYPE_FAT
    jne .check_minix_read
    mov bx, [saved_cur_vfile]
    mov bx, [bx + VFIL_POS_LO]
    mov si, [saved_read_dest_buf]
    mov cx, [saved_read_req_cnt]
    call fat_read_data
    jmp .read_advanced

.check_minix_read:
    ; 4. Minix Read
    cmp ax, FS_TYPE_MINIX
    jne .bad_fs_type
    mov bx, [saved_cur_vfile]
    mov bx, [bx + VFIL_POS_LO]
    mov si, [saved_read_dest_buf]
    mov cx, [saved_read_req_cnt]
    call minix_read_data

.read_advanced:
    test ax, ax
    js .read_ret
    ; Advance f_pos by bytes read
    mov bx, [saved_cur_vfile]
    add [bx + VFIL_POS_LO], ax
    adc word [bx + VFIL_POS_HI], 0
    jmp .read_ret

.bad_fs_type:
    mov ax, -EINVAL
    jmp .read_ret

.bad_read_fd:
    mov ax, -EBADF

.read_ret:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_write: Write bytes to an open file descriptor
; Inputs:
;   BX = File descriptor (0..7)
;   SI = Source buffer in Kernel Data (DS)
;   CX = Byte count to write
; Returns:
;   AX = Bytes written, or negative error code
; ----------------------------------------------------------------------------
vfs_write:
    push bx
    push cx
    push dx
    push si
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .bad_write_fd

    mov [saved_write_src_buf], si
    mov [saved_write_req_cnt], cx

    ; Lookup vfs_file pointer
    mov di, [current_task]
    mov di, [di + TS_PID]
    mov cl, 3
    shl di, cl
    add di, bx
    shl di, 1
    add di, task_filp_table

    mov bx, [di]
    test bx, bx
    jz .bad_write_fd
    mov [saved_cur_vfile_w], bx

    mov di, [bx + VFIL_INODE_PTR]
    test di, di
    jz .bad_write_fd

    mov ax, [di + VINO_FS_TYPE]

    ; 1. DevFS Write
    cmp ax, FS_TYPE_DEVFS
    jne .check_minix_write
    mov si, [saved_write_src_buf]
    mov cx, [saved_write_req_cnt]
    call devfs_write
    jmp .write_advanced

.check_minix_write:
    ; 2. Minix Write
    cmp ax, FS_TYPE_MINIX
    jne .bad_write_fs
    mov bx, [saved_cur_vfile_w]
    mov bx, [bx + VFIL_POS_LO]
    mov si, [saved_write_src_buf]
    mov cx, [saved_write_req_cnt]
    call minix_write_data

.write_advanced:
    test ax, ax
    js .write_ret
    mov bx, [saved_cur_vfile_w]
    add [bx + VFIL_POS_LO], ax
    adc word [bx + VFIL_POS_HI], 0
    jmp .write_ret

.bad_write_fs:
    mov ax, -EACCES
    jmp .write_ret

.bad_write_fd:
    mov ax, -EBADF

.write_ret:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_lseek: Reposition file read/write offset
; Inputs:
;   BX = File descriptor (0..7)
;   CX = Offset (low 16 bits)
;   DX = Whence (SEEK_SET=0, SEEK_CUR=1, SEEK_END=2)
; Returns:
;   AX = New offset low, or negative error code
; ----------------------------------------------------------------------------
vfs_lseek:
    push bx
    push cx
    push dx
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .bad_seek_fd

    ; Lookup vfs_file
    mov di, [current_task]
    mov di, [di + TS_PID]
    mov al, 3
    shl di, 3
    add di, bx
    shl di, 1
    add di, task_filp_table

    mov bx, [di]
    test bx, bx
    jz .bad_seek_fd

    cmp dx, SEEK_SET
    je .seek_set
    cmp dx, SEEK_CUR
    je .seek_cur
    cmp dx, SEEK_END
    je .seek_end
    mov ax, -EINVAL
    jmp .seek_exit

.seek_set:
    mov [bx + VFIL_POS_LO], cx
    mov word [bx + VFIL_POS_HI], 0
    mov ax, cx
    jmp .seek_exit

.seek_cur:
    add [bx + VFIL_POS_LO], cx
    adc word [bx + VFIL_POS_HI], 0
    mov ax, [bx + VFIL_POS_LO]
    jmp .seek_exit

.seek_end:
    mov di, [bx + VFIL_INODE_PTR]
    mov ax, [di + VINO_SIZE_LO]
    add ax, cx
    mov [bx + VFIL_POS_LO], ax
    mov word [bx + VFIL_POS_HI], 0
    jmp .seek_exit

.bad_seek_fd:
    mov ax, -EBADF

.seek_exit:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_fstat: Get file status by descriptor
; Inputs:
;   BX = File descriptor (0..7)
;   DI = Destination struct stat pointer in Kernel Data (DS)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
vfs_fstat:
    push bx
    push cx
    push dx
    push si
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .bad_fstat_fd

    mov si, di                          ; SI = destination struct stat

    mov di, [current_task]
    mov di, [di + TS_PID]
    mov cl, 3
    shl di, cl
    add di, bx
    shl di, 1
    add di, task_filp_table

    mov bx, [di]
    test bx, bx
    jz .bad_fstat_fd

    mov di, [bx + VFIL_INODE_PTR]       ; DI = struct vfs_inode *
    test di, di
    jz .bad_fstat_fd

    ; Copy metadata from vfs_inode (DI) to struct stat (SI)
    mov ax, [di + VINO_DEV]
    mov [si + 0], ax                    ; st_dev
    mov ax, [di + VINO_INO]
    mov [si + 2], ax                    ; st_ino
    mov ax, [di + VINO_MODE]
    mov [si + 4], ax                    ; st_mode
    mov ax, [di + VINO_NLINK]
    mov [si + 6], ax                    ; st_nlink
    mov ax, [di + VINO_UID]
    mov [si + 8], ax                    ; st_uid
    mov ax, [di + VINO_GID]
    mov [si + 10], ax                   ; st_gid
    mov ax, [di + VINO_RDEV]
    mov [si + 12], ax                   ; st_rdev
    mov ax, [di + VINO_SIZE_LO]
    mov [si + 14], ax                   ; st_size low
    mov ax, [di + VINO_SIZE_HI]
    mov [si + 16], ax                   ; st_size high

    xor ax, ax                          ; Success
    jmp .fstat_exit

.bad_fstat_fd:
    mov ax, -EBADF

.fstat_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_stat: Get file status by pathname
; Inputs:
;   SI = Pathname string pointer
;   DI = Destination struct stat pointer
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
vfs_stat:
    push bx
    push cx
    push dx
    push si
    push di

    push di                             ; Save stat buffer
    mov cx, O_RDONLY
    xor dx, dx
    call vfs_open
    pop di
    test ax, ax
    js .stat_err

    mov bx, ax                          ; BX = opened fd
    call vfs_fstat
    push ax
    call vfs_close
    pop ax
    jmp .stat_exit

.stat_err:
.stat_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; vfs_clone_task_fds: Clone open file table from parent task to child task
; Inputs:
;   AX = Parent PID
;   BX = Child PID
; ----------------------------------------------------------------------------
vfs_clone_task_fds:
    pusha

    ; Parent table offset = parent_pid * 16
    mov si, ax
    mov cl, 4
    shl si, cl
    add si, task_filp_table

    ; Child table offset = child_pid * 16
    mov di, bx
    mov cl, 4
    shl di, cl
    add di, task_filp_table

    mov cx, MAX_OPEN_FILES_PER_TASK
.clone_fd_loop:
    mov ax, [si]
    mov [di], ax
    test ax, ax
    jz .skip_inc
    mov bx, ax
    inc word [bx + VFIL_COUNT]          ; Increment file open count
.skip_inc:
    add si, 2
    add di, 2
    loop .clone_fd_loop

    popa
    ret

; ----------------------------------------------------------------------------
; Helper: Allocate free slot in vfs_inode_table
; Returns: AX = pointer to struct vfs_inode, or 0 if full
; ----------------------------------------------------------------------------
vfs_alloc_inode_slot:
    push cx
    push di
    mov cx, MAX_VFS_INODES
    mov di, vfs_inode_table
.find_ino:
    cmp word [di + VINO_COUNT], 0
    je .found_ino
    add di, VINO_SIZE
    loop .find_ino
    xor ax, ax
    jmp .alloc_ino_done
.found_ino:
    mov ax, di
.alloc_ino_done:
    pop di
    pop cx
    ret

; ----------------------------------------------------------------------------
; Helper: Allocate free slot in vfs_file_table
; Returns: AX = pointer to struct vfs_file, or 0 if full
; ----------------------------------------------------------------------------
vfs_alloc_file_slot:
    push cx
    push di
    mov cx, MAX_VFS_FILES
    mov di, vfs_file_table
.find_fil:
    cmp word [di + VFIL_COUNT], 0
    je .found_fil
    add di, VFIL_SIZE
    loop .find_fil
    xor ax, ax
    jmp .alloc_fil_done
.found_fil:
    mov ax, di
.alloc_fil_done:
    pop di
    pop cx
    ret

section .data
align 2
saved_open_flags:       dw 0
saved_open_mode:        dw 0
saved_open_path:        dw 0
cur_open_inode:         dw 0
saved_read_dest_buf:    dw 0
saved_read_req_cnt:     dw 0
saved_cur_vfile:        dw 0
saved_write_src_buf:    dw 0
saved_write_req_cnt:    dw 0
saved_cur_vfile_w:      dw 0

str_vfs_ok:             db "[VFS] Virtual File System core initialized (rootfs, /dos, /dev, /proc)", 13, 10, 0

section .bss
align 4
vfs_inode_table:        resb MAX_VFS_INODES * VINO_SIZE
vfs_file_table:         resb MAX_VFS_FILES * VFIL_SIZE
task_filp_table:        resw (MAX_TASKS * MAX_OPEN_FILES_PER_TASK)

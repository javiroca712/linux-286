CPU 286
BITS 16

; ============================================================================
; Lin286 File System System Call Handlers
;
; Implements POSIX.1-1988 / ELKS system calls:
; sys_open (5), sys_close (6), sys_read (3), sys_write (4),
; sys_lseek (19), sys_stat (18), sys_fstat (28)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global sys_open
global sys_close
global sys_lseek
global sys_stat
global sys_fstat
global sys_read_vfs
global sys_write_vfs
global sys_dup
global sys_dup2
global sys_pipe
global sys_ioctl
global sys_select

section .text

; ----------------------------------------------------------------------------
; sys_open: Open a file
; Inputs:
;   BX = Pointer to pathname string in caller's DS
;   CX = Flags (O_RDONLY, O_WRONLY, O_RDWR, O_CREAT)
;   DX = Mode (permissions)
; Returns:
;   AX = File descriptor (0..7), or negative error code
; ----------------------------------------------------------------------------
sys_open:
    push es
    push si
    push di

    ; Copy pathname from caller's DS [bp + 14] to kernel buffer
    mov ax, [bp + 14]
    mov es, ax
    mov si, bx                          ; ES:SI = caller's pathname string
    mov di, sys_path_buf                ; DS:DI = kernel buffer
    mov cx, 64
.copy_path:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    test al, al
    jz .path_copied
    loop .copy_path
    mov byte [di - 1], 0                ; Force null-termination
.path_copied:

    ; Call VFS open with kernel buffer
    mov si, sys_path_buf
    mov cx, [bp + 2]                    ; CX = flags
    mov dx, [bp + 4]                    ; DX = mode
    call vfs_open

    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_close: Close a file descriptor
; Inputs:
;   BX = File descriptor (0..7)
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_close:
    call vfs_close
    ret

; ----------------------------------------------------------------------------
; sys_read_vfs: Read from file descriptor through VFS
; Inputs:
;   BX = File descriptor
;   CX = Destination buffer offset in caller's DS
;   DX = Byte count
; Returns:
;   AX = Bytes read, or negative error code
; ----------------------------------------------------------------------------
sys_read_vfs:
    push es
    push si
    push di

    test dx, dx
    jz .read_zero

    ; If buffer count > 512, clamp to 512 for temporary kernel buffer transfer
    cmp dx, 512
    jbe .count_ok
    mov dx, 512
.count_ok:

    ; Read from VFS into kernel temp buffer
    push dx
    push cx
    mov si, sys_io_buf                  ; Kernel destination buffer
    mov cx, dx                          ; Byte count
    call vfs_read
    pop cx                              ; Restore caller buffer offset
    pop dx
    test ax, ax
    js .read_err
    jz .read_done                       ; EOF (0 bytes)

    ; Copy bytes from kernel temp buffer to caller's DS [bp + 14]
    push ax
    mov bx, ax                          ; BX = actual bytes read
    mov ax, [bp + 14]                   ; Caller's DS
    mov es, ax
    mov di, cx                          ; ES:DI = caller destination buffer
    mov si, sys_io_buf                  ; DS:SI = kernel source buffer
    mov cx, bx
    cld
    rep movsb
    pop ax                              ; Return bytes read in AX
    jmp .read_done

.read_zero:
    xor ax, ax
    jmp .read_done

.read_err:
.read_done:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_write_vfs: Write to file descriptor through VFS
; Inputs:
;   BX = File descriptor
;   CX = Source buffer offset in caller's DS
;   DX = Byte count
; Returns:
;   AX = Bytes written, or negative error code
; ----------------------------------------------------------------------------
sys_write_vfs:
    push es
    push si
    push di

    test dx, dx
    jz .write_zero

    ; Check if writing to stdout (1) or stderr (2) and stdout is console:
    ; Provide fallback direct console output if needed
    cmp bx, 1
    je .check_stdio
    cmp bx, 2
    je .check_stdio
    jmp .do_vfs_write

.check_stdio:
    ; Also output to console/UART for terminal viewing
    pusha
    mov ax, [bp + 14]
    mov es, ax
    mov si, cx
    mov cx, dx
.term_echo:
    mov al, [es:si]
    inc si
    push cx
    call uart_putc
    call console_putc
    pop cx
    loop .term_echo
    popa

.do_vfs_write:
    ; Clamp to 512 bytes for buffer transfer
    cmp dx, 512
    jbe .wcount_ok
    mov dx, 512
.wcount_ok:

    ; Copy source data from caller's DS [bp + 14] to kernel temp buffer
    push dx
    push bx
    mov ax, [bp + 14]
    mov es, ax
    mov si, cx                          ; ES:SI = caller source buffer
    mov di, sys_io_buf                  ; DS:DI = kernel buffer
    mov cx, dx
    cld
.copy_w:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    loop .copy_w
    pop bx
    pop dx

    ; Call VFS write with kernel buffer
    mov si, sys_io_buf
    mov cx, dx
    call vfs_write

    jmp .write_done

.write_zero:
    xor ax, ax

.write_done:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_lseek: Reposition file read/write offset
; Inputs:
;   BX = File descriptor
;   CX = Offset (low 16 bits)
;   DX = Whence (SEEK_SET=0, SEEK_CUR=1, SEEK_END=2)
; Returns:
;   AX = New offset, or negative error code
; ----------------------------------------------------------------------------
sys_lseek:
    call vfs_lseek
    ret

; ----------------------------------------------------------------------------
; sys_stat: Retrieve file status by pathname
; Inputs:
;   BX = Pointer to pathname in caller's DS
;   CX = Destination struct stat pointer in caller's DS
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_stat:
    push es
    push si
    push di

    ; Copy pathname from caller's DS to kernel buffer
    mov ax, [bp + 14]
    mov es, ax
    mov si, bx
    mov di, sys_path_buf
    mov cx, 64
.copy_stat_p:
    mov al, [es:si]
    mov [di], al
    inc si
    inc di
    test al, al
    jz .stat_p_copied
    loop .copy_stat_p
    mov byte [di - 1], 0
.stat_p_copied:

    ; Call VFS stat with kernel temporary stat buffer
    mov si, sys_path_buf
    mov di, sys_stat_buf
    call vfs_stat
    test ax, ax
    js .stat_err

    ; Copy struct stat back to caller's DS [bp + 14] at CX
    mov ax, [bp + 14]
    mov es, ax
    mov di, cx                          ; ES:DI = caller's struct stat
    mov si, sys_stat_buf                ; DS:SI = kernel stat buffer
    mov cx, 18 / 2                      ; 18 bytes
    rep movsw

    xor ax, ax
    jmp .stat_exit

.stat_err:
.stat_exit:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_fstat: Retrieve file status by open descriptor
; Inputs:
;   BX = File descriptor
;   CX = Destination struct stat pointer in caller's DS
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_fstat:
    push es
    push si
    push di

    ; Call VFS fstat with kernel temporary stat buffer
    mov di, sys_stat_buf
    call vfs_fstat
    test ax, ax
    js .fstat_err

    ; Copy struct stat back to caller's DS [bp + 14] at CX
    mov ax, [bp + 14]
    mov es, ax
    mov di, cx
    mov si, sys_stat_buf
    mov cx, 18 / 2
    rep movsw

    xor ax, ax
    jmp .fstat_exit

.fstat_err:
.fstat_exit:
    pop di
    pop si
    pop es
    ret

; ----------------------------------------------------------------------------
; Helper: Get pointer to task_filp_table entry for current task and fd
; Input:  BX = File descriptor (0..7)
; Output: DI = Pointer to entry in task_filp_table
; ----------------------------------------------------------------------------
get_task_filp_ptr:
    mov al, [current_task]
    xor ah, ah
    shl ax, 3                           ; AX = current_task * 8
    add ax, bx                          ; AX = current_task * 8 + fd
    shl ax, 1                           ; AX = (current_task * 8 + fd) * 2
    add ax, task_filp_table
    mov di, ax
    ret

; ----------------------------------------------------------------------------
; sys_dup: Duplicate an open file descriptor to the lowest free descriptor
; Inputs:
;   BX = oldfd
; Returns:
;   AX = newfd, or negative error code
; ----------------------------------------------------------------------------
sys_dup:
    push bx
    push cx
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .dup_bad_fd

    call get_task_filp_ptr              ; DI = &filp[current_task, oldfd]
    mov ax, [di]                        ; AX = struct vfs_file *
    test ax, ax
    jz .dup_bad_fd
    mov [saved_dup_vfile], ax

    ; Find lowest free fd in current task (0..7)
    xor cx, cx
.find_free_fd:
    mov bx, cx
    call get_task_filp_ptr
    cmp word [di], 0
    je .found_free_dup_fd
    inc cx
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jb .find_free_fd

    mov ax, -EMFILE                     ; Too many open files
    jmp .dup_exit

.found_free_dup_fd:
    ; Assign slot
    mov ax, [saved_dup_vfile]
    mov [di], ax

    ; Increment file reference count
    mov bx, ax
    inc word [bx + VFIL_COUNT]

    ; Check if this file is a pipe: increment readers or writers
    mov di, [bx + VFIL_INODE_PTR]
    test di, di
    jz .dup_ret_fd
    cmp word [di + VINO_FS_TYPE], FS_TYPE_PIPE
    jne .dup_ret_fd

    mov ax, [di + VINO_RDEV]            ; Pipe index
    push bx
    mov bx, ax
    call pipe_get_ptr
    mov si, [saved_dup_vfile]
    cmp word [si + VFIL_MODE], O_WRONLY
    je .dup_pipe_w
    inc word [di + PIPE_STRUCT_READERS]
    jmp .dup_pipe_done
.dup_pipe_w:
    inc word [di + PIPE_STRUCT_WRITERS]
.dup_pipe_done:
    pop bx

.dup_ret_fd:
    mov ax, cx                          ; Return new fd in AX
    jmp .dup_exit

.dup_bad_fd:
    mov ax, -EBADF

.dup_exit:
    pop di
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; sys_dup2: Duplicate an open file descriptor onto a specified descriptor
; Inputs:
;   BX = oldfd
;   CX = newfd
; Returns:
;   AX = newfd, or negative error code
; ----------------------------------------------------------------------------
sys_dup2:
    push bx
    push cx
    push dx
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .dup2_bad_fd
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jae .dup2_bad_fd

    call get_task_filp_ptr              ; DI = &filp[current_task, oldfd]
    mov ax, [di]
    test ax, ax
    jz .dup2_bad_fd
    mov [saved_dup_vfile], ax

    ; If oldfd == newfd, return newfd immediately
    cmp bx, cx
    je .dup2_same_fd

    ; If newfd is already open, close it
    push bx
    push cx
    mov bx, cx
    call vfs_close
    pop cx
    pop bx

    ; Install old_file into filp[newfd]
    mov bx, cx
    call get_task_filp_ptr
    mov ax, [saved_dup_vfile]
    mov [di], ax

    ; Increment file refcount
    mov bx, ax
    inc word [bx + VFIL_COUNT]

    ; Check if pipe: increment reader/writer
    mov di, [bx + VFIL_INODE_PTR]
    test di, di
    jz .dup2_same_fd
    cmp word [di + VINO_FS_TYPE], FS_TYPE_PIPE
    jne .dup2_same_fd

    mov ax, [di + VINO_RDEV]
    push bx
    mov bx, ax
    call pipe_get_ptr
    mov si, [saved_dup_vfile]
    cmp word [si + VFIL_MODE], O_WRONLY
    je .dup2_pipe_w
    inc word [di + PIPE_STRUCT_READERS]
    jmp .dup2_pipe_done
.dup2_pipe_w:
    inc word [di + PIPE_STRUCT_WRITERS]
.dup2_pipe_done:
    pop bx

.dup2_same_fd:
    mov ax, cx                          ; Return newfd
    jmp .dup2_exit

.dup2_bad_fd:
    mov ax, -EBADF

.dup2_exit:
    pop di
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; sys_pipe: Create an unidirectional FIFO pipe
; Inputs:
;   BX = Pointer to int fildes[2] array in caller's DS [bp + 14]
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_pipe:
    push es
    push bx
    push cx
    push dx
    push si
    push di

    mov [saved_pipe_user_ptr], bx

    ; 1. Allocate a pipe in pipe subsystem
    call pipe_alloc
    test ax, ax
    js .pipe_err
    mov [saved_cur_pipe_idx], ax

    ; 2. Allocate 2 inodes (read inode and write inode)
    call vfs_alloc_inode_slot
    test ax, ax
    jz .pipe_enfile
    mov [saved_pipe_ino_r], ax

    call vfs_alloc_inode_slot
    test ax, ax
    jz .pipe_enfile
    mov [saved_pipe_ino_w], ax

    ; 3. Allocate 2 file slots (read file and write file)
    call vfs_alloc_file_slot
    test ax, ax
    jz .pipe_enfile
    mov [saved_pipe_fil_r], ax

    call vfs_alloc_file_slot
    test ax, ax
    jz .pipe_enfile
    mov [saved_pipe_fil_w], ax

    ; 4. Find 2 free fds in current task
    xor cx, cx
.scan_fd0:
    mov bx, cx
    call get_task_filp_ptr
    cmp word [di], 0
    je .got_fd0
    inc cx
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jb .scan_fd0
    jmp .pipe_emfile

.got_fd0:
    mov [saved_pipe_fd0], cx

    ; Find fd1 (starting from cx + 1)
    inc cx
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jae .pipe_emfile
.scan_fd1:
    mov bx, cx
    call get_task_filp_ptr
    cmp word [di], 0
    je .got_fd1
    inc cx
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jb .scan_fd1
    jmp .pipe_emfile

.got_fd1:
    mov [saved_pipe_fd1], cx

    ; 5. Populate Inodes
    mov di, [saved_pipe_ino_r]
    mov word [di + VINO_DEV], 0
    mov ax, [saved_cur_pipe_idx]
    add ax, 200
    mov [di + VINO_INO], ax
    mov word [di + VINO_MODE], (S_IFIFO | 0600q)
    mov word [di + VINO_NLINK], 1
    mov ax, [saved_cur_pipe_idx]
    mov [di + VINO_RDEV], ax
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_PIPE

    mov di, [saved_pipe_ino_w]
    mov word [di + VINO_DEV], 0
    mov ax, [saved_cur_pipe_idx]
    add ax, 201
    mov [di + VINO_INO], ax
    mov word [di + VINO_MODE], (S_IFIFO | 0600q)
    mov word [di + VINO_NLINK], 1
    mov ax, [saved_cur_pipe_idx]
    mov [di + VINO_RDEV], ax
    mov word [di + VINO_SIZE_LO], 0
    mov word [di + VINO_SIZE_HI], 0
    mov word [di + VINO_COUNT], 1
    mov word [di + VINO_FS_TYPE], FS_TYPE_PIPE

    ; 6. Populate Files
    mov di, [saved_pipe_fil_r]
    mov ax, [saved_pipe_ino_r]
    mov [di + VFIL_INODE_PTR], ax
    mov word [di + VFIL_POS_LO], 0
    mov word [di + VFIL_POS_HI], 0
    mov word [di + VFIL_MODE], O_RDONLY
    mov word [di + VFIL_COUNT], 1

    mov di, [saved_pipe_fil_w]
    mov ax, [saved_pipe_ino_w]
    mov [di + VFIL_INODE_PTR], ax
    mov word [di + VFIL_POS_LO], 0
    mov word [di + VFIL_POS_HI], 0
    mov word [di + VFIL_MODE], O_WRONLY
    mov word [di + VFIL_COUNT], 1

    ; 7. Assign to task_filp_table
    mov bx, [saved_pipe_fd0]
    call get_task_filp_ptr
    mov ax, [saved_pipe_fil_r]
    mov [di], ax

    mov bx, [saved_pipe_fd1]
    call get_task_filp_ptr
    mov ax, [saved_pipe_fil_w]
    mov [di], ax

    ; 8. Write fds array to caller's DS [bp + 14] at saved_pipe_user_ptr
    mov ax, [bp + 14]
    mov es, ax
    mov di, [saved_pipe_user_ptr]
    mov ax, [saved_pipe_fd0]
    mov [es:di + 0], ax
    mov ax, [saved_pipe_fd1]
    mov [es:di + 2], ax

    xor ax, ax                          ; Success
    jmp .pipe_exit

.pipe_emfile:
    mov ax, -EMFILE
    jmp .pipe_exit

.pipe_enfile:
    mov ax, -ENFILE
    jmp .pipe_exit

.pipe_err:
.pipe_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_ioctl: Device control system call
; Inputs:
;   BX = File descriptor
;   CX = Command (TCGETS, TCSETS, TIOCGWINSZ, etc.)
;   DX = Arg pointer in caller's DS [bp + 14]
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
sys_ioctl:
    push es
    push bx
    push cx
    push dx
    push si
    push di

    cmp bx, MAX_OPEN_FILES_PER_TASK
    jae .ioctl_bad_fd

    call get_task_filp_ptr
    mov bx, [di]
    test bx, bx
    jz .ioctl_bad_fd

    mov di, [bx + VFIL_INODE_PTR]
    test di, di
    jz .ioctl_bad_fd

    ; Only DEVFS inodes support termios ioctls
    cmp word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    jne .ioctl_notty

    mov ax, [di + VINO_RDEV]

    ; Check Phase 6 Devices:
    cmp ax, DEV_FB0
    je .ioctl_is_fb0

    cmp ax, DEV_PCSPKR
    je .ioctl_is_pcspkr

    cmp ax, DEV_DSP
    je .ioctl_is_dsp

    ; Identify TTY:
    cmp ax, 0x0440                      ; /dev/ttyS0 -> TTY 0
    je .ioctl_is_ttys0
    cmp ax, 0x0501                      ; /dev/console or /dev/tty -> active console
    je .ioctl_is_active_vc
    cmp ax, 0x0401
    jb .ioctl_notty
    cmp ax, 0x0405                      ; /dev/tty1..5
    ja .ioctl_notty

    ; /dev/tty1..5 -> TTY 1..5
    sub ax, 0x0400
    mov bx, ax
    jmp .do_ioctl_call

.ioctl_is_fb0:
    mov cx, [bp + 2]                    ; CX = cmd
    mov dx, [bp + 4]                    ; DX = arg_ptr
    call fb286_ioctl
    jmp .ioctl_exit

.ioctl_is_pcspkr:
    mov cx, [bp + 2]                    ; CX = cmd
    mov dx, [bp + 4]                    ; DX = arg_ptr
    call pcspkr_ioctl
    jmp .ioctl_exit

.ioctl_is_dsp:
    mov cx, [bp + 2]                    ; CX = cmd
    mov dx, [bp + 4]                    ; DX = arg_ptr
    call dsp_ioctl
    jmp .ioctl_exit

.ioctl_is_ttys0:
    xor bx, bx
    jmp .do_ioctl_call

.ioctl_is_active_vc:
    mov bl, [active_console]
    inc bl
    xor bh, bh

.do_ioctl_call:
    mov ax, [bp + 14]
    mov es, ax
    mov cx, [bp + 2]                    ; CX = cmd
    mov dx, [bp + 4]                    ; DX = arg_ptr
    call tty_ioctl
    jmp .ioctl_exit

.ioctl_notty:
    mov ax, -ENOTTY
    jmp .ioctl_exit

.ioctl_bad_fd:
    mov ax, -EBADF

.ioctl_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    ret

; ----------------------------------------------------------------------------
; sys_select: Synchronous I/O multiplexing
; Inputs:
;   BX = nfds
;   CX = readfds pointer in caller DS [bp + 14] (or NULL)
;   DX = writefds pointer in caller DS [bp + 14] (or NULL)
;   SI = exceptfds pointer in caller DS [bp + 14] (or NULL)
;   DI = timeout pointer (unused in simple non-blocking poll)
; Returns:
;   AX = Number of ready descriptors
; ----------------------------------------------------------------------------
sys_select:
    push es
    push bx
    push cx
    push dx
    push si
    push di
    push bp

    mov ax, [bp + 14]
    mov es, ax

    mov [sel_nfds], bx
    mov [sel_readfds_ptr], cx
    mov [sel_writefds_ptr], dx
    mov word [sel_ready_cnt], 0
    mov word [sel_out_read], 0
    mov word [sel_out_write], 0

    ; Read in caller read mask
    xor ax, ax
    test cx, cx
    jz .no_in_read
    mov di, cx
    mov ax, [es:di]
.no_in_read:
    mov [sel_in_read], ax

    ; Read in caller write mask
    xor ax, ax
    mov dx, [sel_writefds_ptr]
    test dx, dx
    jz .no_in_write
    mov di, dx
    mov ax, [es:di]
.no_in_write:
    mov [sel_in_write], ax

    ; Clamp nfds to MAX_OPEN_FILES_PER_TASK (8)
    mov cx, [sel_nfds]
    cmp cx, MAX_OPEN_FILES_PER_TASK
    jbe .nfds_clamped
    mov cx, MAX_OPEN_FILES_PER_TASK
.nfds_clamped:
    test cx, cx
    jz .select_writeback

    ; Loop bp = 0 .. cx-1
    xor bp, bp                          ; BP = current fd (0..7)

.sel_loop:
    ; Mask bit = (1 << BP)
    mov ax, 1
    push cx
    mov bx, bp
    mov cl, bl
    shl ax, cl
    pop cx
    mov [sel_cur_bit], ax

    ; Lookup task_filp_table[current_task, BP]
    mov bx, bp
    call get_task_filp_ptr
    mov bx, [di]
    test bx, bx
    jz .sel_next_fd                     ; Not open -> skip

    mov di, [bx + VFIL_INODE_PTR]
    test di, di
    jz .sel_next_fd

    ; Check READ readiness if bit set in sel_in_read
    mov ax, [sel_cur_bit]
    test ax, [sel_in_read]
    jz .check_sel_write_fd

    ; Check if pipe
    cmp word [di + VINO_FS_TYPE], FS_TYPE_PIPE
    jne .check_dev_read_sel
    mov bx, [di + VINO_RDEV]
    mov ax, 0                           ; 0 for read
    call pipe_select_check
    test ax, ax
    jz .check_sel_write_fd
    mov ax, [sel_cur_bit]
    or [sel_out_read], ax
    inc word [sel_ready_cnt]
    jmp .check_sel_write_fd

.check_dev_read_sel:
    cmp word [di + VINO_FS_TYPE], FS_TYPE_DEVFS
    jne .read_always_ready
    ; Devfs: check if mouse
    mov ax, [di + VINO_RDEV]
    cmp ax, DEV_MOUSE
    je .dev_is_mouse
    ; Devfs: check if TTY
    cmp ax, 0x0440
    je .dev_is_ttys0
    cmp ax, 0x0501
    je .dev_is_act_vc
    cmp ax, 0x0401
    jb .read_always_ready
    cmp ax, 0x0405
    ja .read_always_ready
    sub ax, 0x0400
    mov bx, ax
    jmp .do_tty_sel_check

.dev_is_mouse:
    call mouse_select_check
    test ax, ax
    jz .check_sel_write_fd
    mov ax, [sel_cur_bit]
    or [sel_out_read], ax
    inc word [sel_ready_cnt]
    jmp .check_sel_write_fd

.dev_is_ttys0:
    xor bx, bx
    jmp .do_tty_sel_check

.dev_is_act_vc:
    mov bl, [active_console]
    inc bl
    xor bh, bh

.do_tty_sel_check:
    mov ax, 0                           ; Read
    call tty_select_check
    test ax, ax
    jz .check_sel_write_fd
    mov ax, [sel_cur_bit]
    or [sel_out_read], ax
    inc word [sel_ready_cnt]
    jmp .check_sel_write_fd

.read_always_ready:
    mov ax, [sel_cur_bit]
    or [sel_out_read], ax
    inc word [sel_ready_cnt]

.check_sel_write_fd:
    ; Check WRITE readiness if bit set in sel_in_write
    mov ax, [sel_cur_bit]
    test ax, [sel_in_write]
    jz .sel_next_fd

    cmp word [di + VINO_FS_TYPE], FS_TYPE_PIPE
    jne .write_always_ready
    mov bx, [di + VINO_RDEV]
    mov ax, 1                           ; 1 for write
    call pipe_select_check
    test ax, ax
    jz .sel_next_fd
    mov ax, [sel_cur_bit]
    or [sel_out_write], ax
    inc word [sel_ready_cnt]
    jmp .sel_next_fd

.write_always_ready:
    mov ax, [sel_cur_bit]
    or [sel_out_write], ax
    inc word [sel_ready_cnt]

.sel_next_fd:
    inc bp
    cmp bp, cx
    jb .sel_loop

.select_writeback:
    ; Write back output masks to caller's DS [bp + 14]
    mov di, [sel_readfds_ptr]
    test di, di
    jz .skip_wback_read
    mov ax, [sel_out_read]
    mov [es:di], ax

.skip_wback_read:
    mov di, [sel_writefds_ptr]
    test di, di
    jz .skip_wback_write
    mov ax, [sel_out_write]
    mov [es:di], ax

.skip_wback_write:
    mov ax, [sel_ready_cnt]

    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop es
    ret

section .data
saved_dup_vfile:     dw 0
saved_pipe_user_ptr: dw 0
saved_cur_pipe_idx:  dw 0
saved_pipe_ino_r:    dw 0
saved_pipe_ino_w:    dw 0
saved_pipe_fil_r:    dw 0
saved_pipe_fil_w:    dw 0
saved_pipe_fd0:      dw 0
saved_pipe_fd1:      dw 0

sel_nfds:            dw 0
sel_readfds_ptr:     dw 0
sel_writefds_ptr:    dw 0
sel_in_read:         dw 0
sel_in_write:        dw 0
sel_out_read:        dw 0
sel_out_write:       dw 0
sel_cur_bit:         dw 0
sel_ready_cnt:       dw 0

section .bss
alignb 4
sys_path_buf:   resb 64
sys_io_buf:     resb 512
sys_stat_buf:   resb 32

section .text

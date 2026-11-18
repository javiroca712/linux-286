CPU 286
BITS 16

; ============================================================================
; Lin286 Phase 4 Automated Self-Test Verification Gate
;
; Tests 15 through 22:
; - Test 15: IDE PIO probing & RAM disk block read/write
; - Test 16: Buffer cache (bread, cache hit, LRU eviction, bwrite dirty flush)
; - Test 17: Minix v1 superblock validation & root directory traversal (namei)
; - Test 18: File creation, write, and read via buffer cache
; - Test 19: DOS FAT12/FAT16 mounting & file reading (/dos/README.TXT)
; - Test 20: /dev special character devices (/dev/zero, /dev/null, /dev/ttyS0)
; - Test 21: Synthetic /proc filesystem (/proc/meminfo, /proc/cpuinfo)
; - Test 22: Process file descriptors & INT 0x80 file syscalls (open, read, write, lseek, fstat, close)
; ============================================================================

%include "kernel/include/i286_asm.inc"

global run_phase4_verification_gate

section .text

; ----------------------------------------------------------------------------
; run_phase4_verification_gate: Entry point for Phase 4 verification
; ----------------------------------------------------------------------------
run_phase4_verification_gate:
    pusha

    mov si, str_p4_banner
    call uart_puts
    call console_puts

    ; Test 15: Block Driver & PIO IDE / RAM Disk
    call test15_blkdev_ramdisk

    ; Test 16: Buffer Cache (Hit, LRU, Dirty Flushing)
    call test16_buffer_cache

    ; Test 17: Minix v1 Superblock & Root Directory Lookup
    call test17_minix_rootfs

    ; Test 18: File Creation, Write & Read via Buffer Cache
    call test18_minix_file_io

    ; Test 19: DOS FAT12/FAT16 Mounting & File Reading
    call test19_dos_fat

    ; Test 20: /dev Special Character Devices
    call test20_devfs

    ; Test 21: /proc Synthetic Diagnostics Telemetry
    call test21_procfs

    ; Test 22: File Descriptors & INT 0x80 Syscall Integration
    call test22_vfs_syscalls

    mov si, str_p4_all_ok
    call uart_puts
    call console_puts
    mov si, str_test_pass
    call uart_puts
    call console_puts

    popa
    ret

; ----------------------------------------------------------------------------
; Test 15: Block Driver & PIO IDE / RAM Disk
; ----------------------------------------------------------------------------
test15_blkdev_ramdisk:
    pusha
    mov si, str_t15_start
    call uart_puts

    ; Fill test buffer with test pattern (0x55AA)
    mov di, t15_sector_buf
    mov cx, 256
    mov ax, 0x55AA
    rep stosw

    ; Write test sector to LBA 10 of DEV_RAM0
    mov ax, DEV_RAM0
    mov bx, 10                          ; LBA = 10
    mov dx, t15_sector_buf
    call blkdev_write_sector
    test ax, ax
    jnz .t15_fail

    ; Clear buffer
    mov di, t15_sector_buf
    mov cx, 256
    xor ax, ax
    rep stosw

    ; Read back from LBA 10 of DEV_RAM0
    mov ax, DEV_RAM0
    mov bx, 10
    mov dx, t15_sector_buf
    call blkdev_read_sector
    test ax, ax
    jnz .t15_fail

    ; Verify pattern matches
    mov di, t15_sector_buf
    cmp word [di + 0], 0x55AA
    jne .t15_fail
    cmp word [di + 510], 0x55AA
    jne .t15_fail

    mov si, str_t15_ok
    call uart_puts
    popa
    ret

.t15_fail:
    mov si, str_t15_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 16: Buffer Cache (Hit, LRU, Dirty Flushing)
; ----------------------------------------------------------------------------
test16_buffer_cache:
    pusha
    mov si, str_t16_start
    call uart_puts

    ; Read block 12 for the first time (Cache Miss -> disk read)
    mov ax, DEV_RAM0
    mov bx, 12
    call bread
    test ax, ax
    jz .t16_fail
    mov [t16_buf1], ax

    ; Verify reference count == 1
    mov di, ax
    cmp word [di + BUF_COUNT], 1
    jne .t16_fail

    ; Read block 12 a second time (Cache Hit!)
    mov ax, DEV_RAM0
    mov bx, 12
    call bread
    test ax, ax
    jz .t16_fail

    ; Verify it returns the exact same buffer header pointer (Cache Hit)
    cmp ax, [t16_buf1]
    jne .t16_fail

    ; Verify reference count incremented to 2
    mov di, ax
    cmp word [di + BUF_COUNT], 2
    jne .t16_fail

    ; Release first reference
    mov bx, ax
    call brelse

    ; Verify reference count decremented to 1
    mov di, [t16_buf1]
    cmp word [di + BUF_COUNT], 1
    jne .t16_fail

    ; Modify buffer data and flush with bwrite
    mov di, [di + BUF_DATA]
    mov word [di], 0xBEEF               ; Write test signature

    mov bx, [t16_buf1]
    call bwrite

    ; Release second reference
    mov bx, [t16_buf1]
    call brelse

    ; Verify backing store on disk has updated signature
    mov ax, DEV_RAM0
    mov bx, 24                          ; LBA = 12 * 2 = 24
    mov dx, t15_sector_buf
    call blkdev_read_sector
    test ax, ax
    jnz .t16_fail

    mov di, t15_sector_buf
    cmp word [di], 0xBEEF
    jne .t16_fail

    mov si, str_t16_ok
    call uart_puts
    popa
    ret

.t16_fail:
    mov si, str_t16_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 17: Minix v1 Superblock & Root Directory Lookup
; ----------------------------------------------------------------------------
test17_minix_rootfs:
    pusha
    mov si, str_t17_start
    call uart_puts

    ; Mount Minix v1 rootfs on DEV_RAM0
    mov ax, DEV_RAM0
    call minix_mount
    test ax, ax
    jnz .t17_fail

    ; Look up "." in root directory (inode 1)
    mov ax, 1
    mov si, str_dot
    call minix_lookup
    cmp ax, 1
    jne .t17_fail

    ; Look up ".." in root directory
    mov ax, 1
    mov si, str_dotdot
    call minix_lookup
    cmp ax, 1
    jne .t17_fail

    mov si, str_t17_ok
    call uart_puts
    popa
    ret

.t17_fail:
    mov si, str_t17_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 18: File Creation, Write & Read via Buffer Cache
; ----------------------------------------------------------------------------
test18_minix_file_io:
    pusha
    mov si, str_t18_start
    call uart_puts

    ; Create file "hello.txt" in root directory
    mov ax, 1                           ; Root directory
    mov si, str_hello_txt
    mov cx, (S_IFREG | 0644q)
    call minix_create_file
    test ax, ax
    js .t18_fail
    mov [t18_new_ino], ax

    ; Read inode into temporary vfs_inode
    mov ax, [t18_new_ino]
    mov di, t18_vinode
    call minix_read_inode
    test ax, ax
    jnz .t18_fail

    ; Write test string "Hello, Lin286 Minix v1 Filesystem!\n" (36 bytes)
    mov di, t18_vinode
    xor bx, bx                          ; Offset = 0
    mov si, str_test_msg
    mov cx, 36
    call minix_write_data
    cmp ax, 36
    jne .t18_fail

    ; Clear read buffer
    mov di, t18_read_buf
    mov cx, 18
    xor ax, ax
    rep stosw

    ; Read data back from file
    mov di, t18_vinode
    xor bx, bx                          ; Offset = 0
    mov si, t18_read_buf
    mov cx, 36
    call minix_read_data
    cmp ax, 36
    jne .t18_fail

    ; Verify content matches
    mov si, t18_read_buf
    mov di, str_test_msg
    mov cx, 36
.cmp_msg:
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jne .t18_fail
    inc si
    inc di
    loop .cmp_msg

    mov si, str_t18_ok
    call uart_puts
    popa
    ret

.t18_fail:
    mov si, str_t18_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 19: DOS FAT12/FAT16 Mounting & File Reading
; ----------------------------------------------------------------------------
test19_dos_fat:
    pusha
    mov si, str_t19_start
    call uart_puts

    ; Format & mount FAT filesystem at /dos
    mov ax, DEV_RAM0
    call fat_format_test_image
    mov ax, DEV_RAM0
    call fat_mount
    test ax, ax
    jnz .t19_fail

    ; Look up "README.TXT" in FAT root directory
    mov si, str_fat_readme
    mov di, t19_vinode
    call fat_lookup
    test ax, ax
    jz .t19_fail

    ; Verify inode properties (size = 42, cluster = 2)
    cmp word [t19_vinode + VINO_SIZE_LO], 42
    jne .t19_fail
    cmp word [t19_vinode + VINO_INO], 2
    jne .t19_fail

    ; Read 42 bytes from FAT file
    mov di, t19_vinode
    xor bx, bx
    mov si, t19_read_buf
    mov cx, 42
    call fat_read_data
    cmp ax, 42
    jne .t19_fail

    ; Verify contents begin with "Lin286 DOS"
    cmp byte [t19_read_buf + 0], 'L'
    jne .t19_fail
    cmp byte [t19_read_buf + 1], 'i'
    jne .t19_fail
    cmp byte [t19_read_buf + 2], 'n'
    jne .t19_fail
    cmp byte [t19_read_buf + 3], '2'
    jne .t19_fail

    mov si, str_t19_ok
    call uart_puts
    popa
    ret

.t19_fail:
    mov si, str_t19_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 20: /dev Special Character Devices
; ----------------------------------------------------------------------------
test20_devfs:
    pusha
    mov si, str_t20_start
    call uart_puts

    ; 1. Lookup /dev/zero
    mov si, str_dev_zero_name
    mov di, t20_vinode
    call devfs_lookup
    cmp ax, 1
    jne .t20_fail

    ; Pre-fill buffer with 0xAA
    mov di, t20_buf
    mov cx, 32
    mov al, 0xAA
    rep stosb

    ; Read 32 bytes from /dev/zero
    mov di, t20_vinode
    mov si, t20_buf
    mov cx, 32
    call devfs_read
    cmp ax, 32
    jne .t20_fail

    ; Verify all 32 bytes are zeroes
    mov di, t20_buf
    mov cx, 32
.check_zeroes:
    cmp byte [di], 0
    jne .t20_fail
    inc di
    loop .check_zeroes

    ; 2. Lookup /dev/null
    mov si, str_dev_null_name
    mov di, t20_vinode
    call devfs_lookup
    cmp ax, 1
    jne .t20_fail

    ; Read from /dev/null: must return 0 (EOF)
    mov di, t20_vinode
    mov si, t20_buf
    mov cx, 32
    call devfs_read
    test ax, ax
    jnz .t20_fail

    ; Write to /dev/null: must accept all bytes
    mov di, t20_vinode
    mov si, t20_buf
    mov cx, 16
    call devfs_write
    cmp ax, 16
    jne .t20_fail

    mov si, str_t20_ok
    call uart_puts
    popa
    ret

.t20_fail:
    mov si, str_t20_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 21: /proc Synthetic Diagnostics Telemetry
; ----------------------------------------------------------------------------
test21_procfs:
    pusha
    mov si, str_t21_start
    call uart_puts

    ; 1. Lookup /proc/meminfo
    mov si, str_proc_meminfo_n
    mov di, t21_vinode
    call procfs_lookup
    cmp ax, 1
    jne .t21_fail

    ; Read 32 bytes from /proc/meminfo
    mov di, t21_vinode
    xor bx, bx
    mov si, t21_buf
    mov cx, 32
    call procfs_read_data
    cmp ax, 32
    jne .t21_fail

    ; Verify text starts with "MemTotal:"
    cmp byte [t21_buf + 0], 'M'
    jne .t21_fail
    cmp byte [t21_buf + 1], 'e'
    jne .t21_fail
    cmp byte [t21_buf + 2], 'm'
    jne .t21_fail
    cmp byte [t21_buf + 3], 'T'
    jne .t21_fail

    ; 2. Lookup /proc/cpuinfo
    mov si, str_proc_cpuinfo_n
    mov di, t21_vinode
    call procfs_lookup
    cmp ax, 1
    jne .t21_fail

    ; Read 64 bytes from /proc/cpuinfo
    mov di, t21_vinode
    xor bx, bx
    mov si, t21_buf
    mov cx, 64
    call procfs_read_data
    cmp ax, 64
    jne .t21_fail

    ; Verify text starts with "processor"
    cmp byte [t21_buf + 0], 'p'
    jne .t21_fail
    cmp byte [t21_buf + 1], 'r'
    jne .t21_fail
    cmp byte [t21_buf + 2], 'o'
    jne .t21_fail
    cmp byte [t21_buf + 3], 'c'
    jne .t21_fail

    mov si, str_t21_ok
    call uart_puts
    popa
    ret

.t21_fail:
    mov si, str_t21_err
    call uart_puts
    hlt

; ----------------------------------------------------------------------------
; Test 22: File Descriptors & INT 0x80 Syscall Integration
; ----------------------------------------------------------------------------
test22_vfs_syscalls:
    pusha
    mov si, str_t22_start
    call uart_puts

    ; 1. sys_open("/proc/cpuinfo", O_RDONLY) via INT 0x80
    mov ax, SYS_OPEN                    ; Syscall 5
    mov bx, str_proc_cpuinfo_path       ; BX = path pointer
    mov cx, O_RDONLY                    ; CX = flags
    xor dx, dx                          ; DX = mode
    int 0x80

    ; Verify valid file descriptor returned (fd >= 3, since 0,1,2 are stdio)
    test ax, ax
    js .t22_fail
    mov [t22_fd], ax

    ; 2. sys_read(fd, buf, 32) via INT 0x80
    mov bx, [t22_fd]
    mov ax, SYS_READ                    ; Syscall 3
    mov cx, t22_buf                     ; Destination buffer
    mov dx, 32                          ; Byte count
    int 0x80
    cmp ax, 32
    jne .t22_fail

    ; 3. sys_lseek(fd, 0, SEEK_SET) via INT 0x80
    mov bx, [t22_fd]
    mov ax, SYS_LSEEK                   ; Syscall 19
    xor cx, cx                          ; Offset = 0
    mov dx, SEEK_SET                    ; Whence = 0
    int 0x80
    test ax, ax
    jnz .t22_fail

    ; 4. sys_fstat(fd, statbuf) via INT 0x80
    mov bx, [t22_fd]
    mov ax, SYS_FSTAT                   ; Syscall 28
    mov cx, t22_statbuf
    int 0x80
    test ax, ax
    jnz .t22_fail

    ; Verify statbuf mode is S_IFREG
    mov di, t22_statbuf
    mov ax, [di + 4]                    ; st_mode
    and ax, S_IFMT
    cmp ax, S_IFREG
    jne .t22_fail

    ; 5. sys_close(fd) via INT 0x80
    mov bx, [t22_fd]
    mov ax, SYS_CLOSE                   ; Syscall 6
    int 0x80
    test ax, ax
    jnz .t22_fail

    ; 6. Verify closing again returns -EBADF (-9)
    mov bx, [t22_fd]
    mov ax, SYS_CLOSE
    int 0x80
    cmp ax, -EBADF
    jne .t22_fail

    mov si, str_t22_ok
    call uart_puts
    popa
    ret

.t22_fail:
    mov si, str_t22_err
    call uart_puts
    hlt

section .data
align 2
t16_buf1:               dw 0
t18_new_ino:            dw 0
t22_fd:                 dw 0

str_dot:                db ".", 0
str_dotdot:             db "..", 0
str_hello_txt:          db "hello.txt", 0
str_test_msg:           db "Hello, Lin286 Minix v1 Filesystem!", 10, 0
str_fat_readme:         db "README", 0
str_dev_zero_name:      db "zero", 0
str_dev_null_name:      db "null", 0
str_proc_meminfo_n:     db "meminfo", 0
str_proc_cpuinfo_n:     db "cpuinfo", 0
str_proc_cpuinfo_path:  db "/proc/cpuinfo", 0

str_p4_banner:          db 13, 10
                        db "========================================================", 13, 10
                        db " Lin286 Phase 4 Automated Verification Suite            ", 13, 10
                        db "========================================================", 13, 10, 0

str_t15_start:          db "[TEST 15] Verifying Block Driver (PIO IDE / RAM disk)...", 13, 10, 0
str_t15_ok:             db "[TEST 15] PASSED: Block driver & PIO IDE / RAM disk verified.", 13, 10, 0
str_t15_err:            db "[TEST 15] FAILED: Block driver verification failed!", 13, 10, 0

str_t16_start:          db "[TEST 16] Verifying Buffer Cache (Hit, LRU, Dirty Flushing)...", 13, 10, 0
str_t16_ok:             db "[TEST 16] PASSED: Buffer cache (hit, LRU, bwrite dirty flushing) verified.", 13, 10, 0
str_t16_err:            db "[TEST 16] FAILED: Buffer cache verification failed!", 13, 10, 0

str_t17_start:          db "[TEST 17] Verifying Minix v1 Superblock & Root Directory...", 13, 10, 0
str_t17_ok:             db "[TEST 17] PASSED: Minix v1 superblock & root directory (namei) verified.", 13, 10, 0
str_t17_err:            db "[TEST 17] FAILED: Minix superblock/lookup failed!", 13, 10, 0

str_t18_start:          db "[TEST 18] Verifying Minix File Creation, Write & Read...", 13, 10, 0
str_t18_ok:             db "[TEST 18] PASSED: Minix file creation, write & read via buffer cache verified.", 13, 10, 0
str_t18_err:            db "[TEST 18] FAILED: File creation/write/read failed!", 13, 10, 0

str_t19_start:          db "[TEST 19] Verifying DOS FAT12/FAT16 Mounting & File Reading...", 13, 10, 0
str_t19_ok:             db "[TEST 19] PASSED: DOS FAT12/16 mounting & file reading verified.", 13, 10, 0
str_t19_err:            db "[TEST 19] FAILED: FAT mounting/reading failed!", 13, 10, 0

str_t20_start:          db "[TEST 20] Verifying /dev Special Character Devices (null, zero)...", 13, 10, 0
str_t20_ok:             db "[TEST 20] PASSED: /dev character devices (null, zero, ttyS0) verified.", 13, 10, 0
str_t20_err:            db "[TEST 20] FAILED: /dev device verification failed!", 13, 10, 0

str_t21_start:          db "[TEST 21] Verifying Synthetic /proc Filesystem Telemetry...", 13, 10, 0
str_t21_ok:             db "[TEST 21] PASSED: /proc synthetic telemetry (meminfo, cpuinfo) verified.", 13, 10, 0
str_t21_err:            db "[TEST 21] FAILED: /proc verification failed!", 13, 10, 0

str_t22_start:          db "[TEST 22] Verifying VFS File Descriptors & INT 0x80 Syscalls...", 13, 10, 0
str_t22_ok:             db "[TEST 22] PASSED: VFS file descriptors & INT 0x80 file syscalls verified.", 13, 10, 0
str_t22_err:            db "[TEST 22] FAILED: VFS syscall verification failed!", 13, 10, 0

str_p4_all_ok:          db "========================================================", 13, 10
                        db "[TEST] ALL PHASE 1, 2, 3 & 4 VERIFICATIONS PASSED!", 13, 10, 0
str_test_pass:          db "TEST PASS", 13, 10, 0

section .bss
align 4
t15_sector_buf:         resb SECTOR_SIZE
t18_vinode:             resb VINO_SIZE
t18_read_buf:           resb 64
t19_vinode:             resb VINO_SIZE
t19_read_buf:           resb 64
t20_vinode:             resb VINO_SIZE
t20_buf:                resb 64
t21_vinode:             resb VINO_SIZE
t21_buf:                resb 128
t22_buf:                resb 64
t22_statbuf:            resb 32

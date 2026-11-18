CPU 286
BITS 16

; ============================================================================
; Lin286 MC146818 CMOS RTC & RAM Autodetect Driver
;
; Reads CMOS ports 0x70/0x71 in Protected Mode to detect:
; 1. Conventional Base RAM (regs 0x15/0x16)
; 2. Extended RAM above 1MB (regs 0x17/0x18)
; 3. Floppy drive configuration (reg 0x10)
; 4. BCD/Binary Real-Time Clock date and time
; ============================================================================

%include "kernel/include/i286_asm.inc"

global cmos_init_and_detect
global cmos_read_byte

extern uart_puts
extern uart_putc
extern uart_print_dec
extern uart_print_hex16

section .text

; Read single byte from CMOS register in AL -> result in AL
cmos_read_byte:
    push dx
    out CMOS_ADDR_PORT, al
    jmp $+2                 ; I/O delay
    in al, CMOS_DATA_PORT
    pop dx
    ret

; Convert packed BCD in AL to Binary in AL
bcd_to_bin:
    push bx
    mov bl, al
    shr al, 4
    mov bh, 10
    mul bh                  ; AL = tens * 10
    and bl, 0x0F
    add al, bl
    pop bx
    ret

cmos_init_and_detect:
    pusha

    ; ------------------------------------------------------------------------
    ; 1. Read Base Memory (regs 0x15, 0x16)
    ; ------------------------------------------------------------------------
    mov al, 0x15
    call cmos_read_byte
    mov [cmos_base_kb], al
    mov al, 0x16
    call cmos_read_byte
    mov [cmos_base_kb + 1], al

    ; ------------------------------------------------------------------------
    ; 2. Read Extended Memory (regs 0x17, 0x18)
    ; ------------------------------------------------------------------------
    mov al, 0x17
    call cmos_read_byte
    mov [cmos_ext_kb], al
    mov al, 0x18
    call cmos_read_byte
    mov [cmos_ext_kb + 1], al

    ; ------------------------------------------------------------------------
    ; 3. Read Floppy Configuration (reg 0x10)
    ; ------------------------------------------------------------------------
    mov al, 0x10
    call cmos_read_byte
    mov [cmos_floppy_byte], al

    ; ------------------------------------------------------------------------
    ; 4. Read RTC Time (seconds 0x00, minutes 0x02, hours 0x04)
    ; ------------------------------------------------------------------------
    ; Check if Status Register B has BCD or Binary mode (bit 2)
    mov al, 0x0B
    call cmos_read_byte
    mov [cmos_stat_b], al

    mov al, 0x00            ; Seconds
    call cmos_read_byte
    call check_convert_bcd
    mov [rtc_sec], al

    mov al, 0x02            ; Minutes
    call cmos_read_byte
    call check_convert_bcd
    mov [rtc_min], al

    mov al, 0x04            ; Hours
    call cmos_read_byte
    call check_convert_bcd
    mov [rtc_hour], al

    mov al, 0x07            ; Day
    call cmos_read_byte
    call check_convert_bcd
    mov [rtc_day], al

    mov al, 0x08            ; Month
    call cmos_read_byte
    call check_convert_bcd
    mov [rtc_month], al

    mov al, 0x09            ; Year
    call cmos_read_byte
    call check_convert_bcd
    mov [rtc_year], al

    ; ------------------------------------------------------------------------
    ; Output Telemetry over COM1
    ; ------------------------------------------------------------------------
    mov si, str_cmos_hdr
    call uart_puts

    mov si, str_base_ram
    call uart_puts
    mov ax, [cmos_base_kb]
    call uart_print_dec
    mov si, str_kb_ext
    call uart_puts
    mov ax, [cmos_ext_kb]
    call uart_print_dec
    mov si, str_kb_crlf
    call uart_puts

    ; Floppy description
    mov si, str_floppy_hdr
    call uart_puts
    mov al, [cmos_floppy_byte]
    shr al, 4               ; Drive 0 type in high nibble
    cmp al, 4
    je .fd_144
    cmp al, 2
    je .fd_120
    mov si, str_fd_other
    jmp .fd_print
.fd_144:
    mov si, str_fd_144
    jmp .fd_print
.fd_120:
    mov si, str_fd_120
.fd_print:
    call uart_puts

    ; RTC date/time string
    mov si, str_rtc_hdr
    call uart_puts

    ; Year 20xx
    mov si, str_20
    call uart_puts
    xor ax, ax
    mov al, [rtc_year]
    call print_2digits

    mov al, '-'
    call uart_putc
    xor ax, ax
    mov al, [rtc_month]
    call print_2digits

    mov al, '-'
    call uart_putc
    xor ax, ax
    mov al, [rtc_day]
    call print_2digits

    mov al, ' '
    call uart_putc

    xor ax, ax
    mov al, [rtc_hour]
    call print_2digits
    mov al, ':'
    call uart_putc
    xor ax, ax
    mov al, [rtc_min]
    call print_2digits
    mov al, ':'
    call uart_putc
    xor ax, ax
    mov al, [rtc_sec]
    call print_2digits

    mov si, str_utc_crlf
    call uart_puts

    popa
    ret

check_convert_bcd:
    test byte [cmos_stat_b], 0x04
    jnz .is_binary
    call bcd_to_bin
.is_binary:
    ret

print_2digits:
    cmp al, 10
    jae .no_zero
    push ax
    mov al, '0'
    call uart_putc
    pop ax
.no_zero:
    call uart_print_dec
    ret

section .data
cmos_base_kb:       dw 0
cmos_ext_kb:        dw 0
cmos_floppy_byte:   db 0
cmos_stat_b:        db 0

rtc_sec:            db 0
rtc_min:            db 0
rtc_hour:           db 0
rtc_day:            db 0
rtc_month:          db 0
rtc_year:           db 0

str_cmos_hdr:       db "[CMOS] Autodetect: Hardware Configuration", 13, 10, 0
str_base_ram:       db "[CMOS] Base RAM: ", 0
str_kb_ext:         db " KB, Extended RAM: ", 0
str_kb_crlf:        db " KB", 13, 10, 0
str_floppy_hdr:     db "[CMOS] Floppy 0: ", 0
str_fd_144:         db "1.44 MB 3.5-inch", 13, 10, 0
str_fd_120:         db "1.2 MB 5.25-inch", 13, 10, 0
str_fd_other:       db "Legacy/None", 13, 10, 0
str_rtc_hdr:        db "[CMOS] RTC Wall-Clock: ", 0
str_20:             db "20", 0
str_utc_crlf:       db " UTC", 13, 10, 0

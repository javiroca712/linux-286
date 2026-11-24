CPU 286
BITS 16

; ============================================================================
; Lin286 Stage 2 Setup (A20, CMOS/BIOS Autodetect, GDT/IDT & PM Switch)
;
; Loaded at 0x9000:0x0200 in Real Mode.
; Detects memory, enables A20, initializes early GDT/IDT, executes LMSW (PE=1),
; and jumps to 0x0008:0x0000 (Ring 0 Kernel Entry at physical 0x001000).
; ============================================================================

org 0x0200

setup_entry:
    cli
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFE00          ; Temporary real-mode stack
    sti

    mov [boot_drive], dl    ; DL passed from bootsect

    mov si, msg_setup
    call print_string

    ; ------------------------------------------------------------------------
    ; 1. Query Conventional Memory (INT 12h) -> AX in KB
    ; ------------------------------------------------------------------------
    int 0x12
    mov [conv_mem_kb], ax

    ; ------------------------------------------------------------------------
    ; 2. Query Extended Memory (INT 15h, AH=88h) -> AX in KB above 1MB
    ; ------------------------------------------------------------------------
    mov ah, 0x88
    int 0x15
    jnc .ext_ok
    xor ax, ax              ; If error or none, set 0
.ext_ok:
    mov [ext_mem_kb], ax

    ; ------------------------------------------------------------------------
    ; 3. Enable A20 Gate
    ; ------------------------------------------------------------------------
    call enable_a20
    test ax, ax
    jnz .a20_ok

    mov si, msg_a20_fail
    call print_string
.halt:
    cli
    hlt
    jmp .halt

.a20_ok:
    mov si, msg_a20_ok
    call print_string

    ; ------------------------------------------------------------------------
    ; 4. Copy Kernel Data to physical 0x019000 (0x1900:0x0000) & Zero BSS
    ; ------------------------------------------------------------------------
    mov ax, 0x0100          ; Kernel image loaded at 0x0100:0x0000
    mov ds, ax
    mov si, [0x0004]        ; hdr_text_size (file offset where .data begins)
    mov cx, [0x0006]        ; hdr_data_size
    mov ax, 0x1900          ; Destination: 0x1900:0x0000 (phys 0x019000)
    mov es, ax
    xor di, di
    cld
    test cx, cx
    jz .no_data_copy
    rep movsb
.no_data_copy:

    ; Zero BSS
    mov cx, [0x0008]        ; hdr_bss_size
    xor al, al
    test cx, cx
    jz .no_bss_zero
    rep stosb
.no_bss_zero:

    ; Restore DS = 0x9000
    mov ax, 0x9000
    mov ds, ax

    ; ------------------------------------------------------------------------
    ; 5. Shut off floppy motor cleanly, disable interrupts, load early GDT & IDT
    ; ------------------------------------------------------------------------
    mov dx, 0x03F2
    mov al, 0x0C
    out dx, al
    cli

    ; Load GDTR with physical 24-bit base of gdt_table:
    ; Base = 0x90000 + (gdt_table offset within segment 0x9000)
    mov ax, gdt_table
    mov [gdtr_base_low], ax
    mov byte [gdtr_base_high], 0x09  ; Segment 0x9000 is physical 0x090000

    lgdt [gdtr_desc]
    lidt [idtr_desc]

    ; ------------------------------------------------------------------------
    ; 6. Enter Intel 80286 Protected Mode via LMSW
    ; ------------------------------------------------------------------------
    smsw ax
    or ax, 1                ; Protection Enable (PE) bit
    lmsw ax                 ; 80286 LMSW instruction

    ; Flush prefetch queue and far jump to Ring 0 Kernel Entry (CS=0x0008)
    jmp 0x0008:0x0000

; ============================================================================
; A20 Gate Activation & Verification Subroutines
; ============================================================================

enable_a20:
    ; First, test if already enabled
    call check_a20
    test ax, ax
    jnz .done

    ; Method 1: BIOS INT 15h, AX=2401h
    mov ax, 0x2401
    int 0x15
    call check_a20
    test ax, ax
    jnz .done

    ; Method 2: Keyboard Controller 8042
    call kbd_wait_in
    mov al, 0xD1            ; Command: Write Output Port
    out 0x64, al
    call kbd_wait_in
    mov al, 0xDF            ; A20 gate bit enabled
    out 0x60, al
    call kbd_wait_in

    call check_a20
    test ax, ax
    jnz .done

    ; Method 3: Fast A20 Gate (Port 0x92)
    in al, 0x92
    test al, 0x02
    jnz .check_fast
    or al, 0x02             ; Enable A20 bit
    and al, 0xFE            ; Ensure bit 0 (fast reset) is NEVER set!
    out 0x92, al
.check_fast:
    call check_a20
.done:
    ret

; Test if A20 is enabled by checking for 1MB memory wrap
; Returns AX = 1 if enabled, AX = 0 if wrapped/disabled
check_a20:
    push ds
    push es
    push si
    push di

    xor ax, ax
    mov ds, ax
    mov si, 0x0500          ; DS:SI = 0x0000:0x0500

    not ax                  ; AX = 0xFFFF
    mov es, ax
    mov di, 0x0510          ; ES:DI = 0xFFFF:0x0510 (phys 0x100500)

    mov al, [ds:si]
    mov byte [ds:si], 0x00
    mov ah, [es:di]
    mov byte [es:di], 0xFF

    cmp byte [ds:si], 0xFF
    je .wrapped

    mov ax, 1               ; A20 is enabled!
    jmp .cleanup

.wrapped:
    xor ax, ax              ; A20 is wrapped/disabled

.cleanup:
    mov [ds:si], al
    mov [es:di], ah
    pop di
    pop si
    pop es
    pop ds
    ret

kbd_wait_in:
    in al, 0x64
    test al, 0x02
    jnz kbd_wait_in
    ret

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

; ============================================================================
; Early Global Descriptor Table (GDT) & Pseudo-Descriptors
; ============================================================================

align 8
gdt_table:
    ; Selector 0x0000: Null Descriptor
    dw 0x0000, 0x0000, 0x0000, 0x0000

    ; Selector 0x0008: Kernel Code (CS), Base=0x001000, Limit=0xFFFF, Ring 0 E/R
    ; Access: 0x9A = Present(1), DPL=00, S=1, Code=1, Readable=1
    dw 0xFFFF               ; Limit 15..0
    dw 0x1000               ; Base 15..0 (0x1000)
    db 0x00                 ; Base 23..16 (0x00)
    db 0x9A                 ; Access byte
    dw 0x0000               ; Reserved / VM metadata (Bytes 6..7)

    ; Selector 0x0010: Kernel Data/Stack (DS/SS), Base=0x019000, Limit=0xFFFF, Ring 0 R/W
    ; Access: 0x92 = Present(1), DPL=00, S=1, Code=0, Writable=1
    dw 0xFFFF               ; Limit 15..0
    dw 0x9000               ; Base 15..0 (0x9000)
    db 0x01                 ; Base 23..16 (0x01 -> Phys 0x019000)
    db 0x92                 ; Access byte
    dw 0x0000               ; Reserved / VM metadata

    ; Selector 0x0018: Color Video Text (0xB8000), Limit=0x7FFF (32KB), Ring 0 R/W
    dw 0x7FFF
    dw 0x8000               ; Base 15..0 (0x8000)
    db 0x0B                 ; Base 23..16 (0x0B -> Phys 0x0B8000)
    db 0x92
    dw 0x0000

    ; Selector 0x0020: Mono Video Text (0xB0000), Limit=0x7FFF (32KB), Ring 0 R/W
    dw 0x7FFF
    dw 0x0000               ; Base 15..0 (0x0000)
    db 0x0B                 ; Base 23..16 (0x0B -> Phys 0x0B0000)
    db 0x92
    dw 0x0000

    ; Selector 0x0028: Scratch Copy Window A, Base=0x000000, Limit=0xFFFF, Ring 0 R/W
    dw 0xFFFF, 0x0000, 0x0092, 0x0000

    ; Selector 0x0030: Scratch Copy Window B, Base=0x000000, Limit=0xFFFF, Ring 0 R/W
    dw 0xFFFF, 0x0000, 0x0092, 0x0000

    ; Selector 0x0038: Hardware 286 TSS, Base=0x019000, Limit=43, Ring 0 Available TSS
    ; Access: 0x81 = Present(1), DPL=00, S=0, Type=0001 (Available 286 TSS)
    dw 43                   ; Limit (44 bytes - 1)
    dw 0x9000               ; Base 15..0 (TSS placed at base of kernel data)
    db 0x01                 ; Base 23..16 (Phys 0x019000)
    db 0x81                 ; Access byte
    dw 0x0000

    ; Selector 0x0040: Verification Descriptor with Present = 0 (for deliberate #NP test)
    ; Access: 0x12 = Present(0), DPL=00, S=1, Data R/W
    dw 0x0FFF
    dw 0x0000
    db 0x02                 ; Phys 0x020000
    db 0x12                 ; Present = 0!
    dw 0x0000

gdt_table_end:

align 4
gdtr_desc:
    dw (gdt_table_end - gdt_table - 1)
gdtr_base_low:
    dw 0x0000
gdtr_base_high:
    db 0x00
    db 0x00

idtr_desc:
    dw 0x0000               ; Early null IDTR (cli holds until kernel installs full IDT)
    dw 0x0000
    db 0x00
    db 0x00

boot_drive:     db 0x00
conv_mem_kb:    dw 0x0000
ext_mem_kb:     dw 0x0000

msg_setup:      db "Lin286 Setup...", 13, 10, 0
msg_a20_ok:     db "A20 Gate Enabled.", 13, 10, 0
msg_a20_fail:   db "FATAL: Failed to enable A20 Gate!", 13, 10, 0

CPU 286
BITS 16

; ============================================================================
; Lin286 Native Protected-Mode Framebuffer Driver (/dev/fb0)
;
; Provides zero-overhead Ring 3 display server integration for VGA/EGA/CGA/HGC:
;  1. FBIOGET_INFO: Query active video mode geometry and 24-bit physical aperture.
;  2. FBIOSET_MODE: Hardware register table mode switching in Ring 0 without BIOS.
;  3. FBIOMAP_LDT:  Map 64 KB Video Aperture (0x0A0000 / 0x0B0000) into caller's
;                   LDT descriptor at index 3 (LDT_UFB_SEL = 0x001F, DPL=3, MMIO).
;  4. FBIOSET_IOPL3: Set FLAGS.IOPL = 3 on caller's stack frame for direct Ring 3
;                    VGA bitplane register OUT/IN instructions without #GP.
;  5. FBIOSET_PALETTE: Program VGA DAC palette registers (0x3C8 / 0x3C9).
; ============================================================================

%include "kernel/include/i286_asm.inc"

global fb286_init
global fb286_ioctl
global fb286_read
global fb286_write
global fb286_map_ldt
global fb286_set_iopl3
global fb286_set_mode
global fb286_get_info
global fb286_current_mode
global fb286_is_graphics

section .text

; ----------------------------------------------------------------------------
; fb286_init: Initialize framebuffer driver state
; ----------------------------------------------------------------------------
fb286_init:
    push si
    ; Default mode is 80x25 text mode (0x0003) on 0xB8000
    mov word [fb286_current_mode], FB_MODE_TEXT_80x25
    mov word [fb286_width], 80
    mov word [fb286_height], 25
    mov byte [fb286_bpp], 4
    mov byte [fb286_planes], 1
    mov word [fb286_stride], 160
    mov word [fb286_phys_base_lo], 0x8000
    mov byte [fb286_phys_base_hi], 0x0B         ; Physical 0x0B8000
    mov word [fb286_aperture_size], 0x7FFF
    mov byte [fb286_is_graphics], 0

    mov si, str_fb286_ok
    call uart_puts
    pop si
    ret

; ----------------------------------------------------------------------------
; fb286_ioctl: Framebuffer device control
; Inputs:
;   BX = File descriptor (or calling context)
;   CX = Command (FBIOGET_INFO, FBIOSET_MODE, FBIOMAP_LDT, FBIOSET_IOPL3, etc.)
;   DX = Arg pointer in caller's DS [bp + 14]
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
fb286_ioctl:
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; Dispatch ioctl command
    cmp cx, FBIOGET_INFO
    je .cmd_get_info

    cmp cx, FBIOSET_MODE
    je .cmd_set_mode

    cmp cx, FBIOMAP_LDT
    je .cmd_map_ldt

    cmp cx, FBIOSET_IOPL3
    je .cmd_set_iopl3

    cmp cx, FBIOSET_PALETTE
    je .cmd_set_palette

    ; Unrecognized command
    mov ax, -EINVAL
    jmp .ioctl_exit

; --- FBIOGET_INFO: Copy struct fb286_info to caller ---
.cmd_get_info:
    test dx, dx
    jz .bad_arg

    mov ax, [bp + 14]                   ; Caller's DS
    mov es, ax
    mov di, dx                          ; ES:DI = destination in caller space

    ; Copy 18 bytes of struct fb286_info
    mov ax, [fb286_current_mode]
    mov [es:di + FBINFO_MODE], ax

    mov ax, [fb286_width]
    mov [es:di + FBINFO_WIDTH], ax

    mov ax, [fb286_height]
    mov [es:di + FBINFO_HEIGHT], ax

    mov al, [fb286_bpp]
    mov [es:di + FBINFO_BPP], al

    mov al, [fb286_planes]
    mov [es:di + FBINFO_PLANES], al

    mov ax, [fb286_stride]
    mov [es:di + FBINFO_STRIDE], ax

    mov ax, [fb286_phys_base_lo]
    mov [es:di + FBINFO_PHYS_BASE_LO], ax

    mov al, [fb286_phys_base_hi]
    mov byte [es:di + FBINFO_PHYS_BASE_HI], al
    mov byte [es:di + FBINFO_PHYS_BASE_HI + 1], 0

    mov ax, [fb286_aperture_size]
    mov [es:di + FBINFO_APERTURE_SIZE], ax

    mov word [es:di + FBINFO_LDT_SELECTOR], LDT_UFB_SEL ; 0x001F

    xor ax, ax
    jmp .ioctl_exit

; --- FBIOSET_MODE: Switch video mode ---
.cmd_set_mode:
    mov ax, dx                          ; AX = requested mode
    call fb286_set_mode
    jmp .ioctl_exit

; --- FBIOMAP_LDT: Map 64KB VRAM into caller's LDT (0x001F) ---
.cmd_map_ldt:
    call fb286_map_ldt
    ; If DX != 0, write selector into arg struct
    test dx, dx
    jz .map_done
    mov bx, [bp + 14]
    mov es, bx
    mov di, dx
    mov word [es:di + FBINFO_LDT_SELECTOR], LDT_UFB_SEL
.map_done:
    xor ax, ax
    jmp .ioctl_exit

; --- FBIOSET_IOPL3: Set FLAGS.IOPL = 3 on caller stack frame ---
.cmd_set_iopl3:
    mov ax, dx                          ; 1 = enable, 0 = disable
    call fb286_set_iopl3
    xor ax, ax
    jmp .ioctl_exit

; --- FBIOSET_PALETTE: Program DAC Palette ---
.cmd_set_palette:
    ; DX points to palette table: [start_index(dw), count(dw), rgb_bytes...]
    test dx, dx
    jz .bad_arg
    mov ax, [bp + 14]
    mov es, ax
    mov si, dx

    mov bx, [es:si]                     ; start index
    mov cx, [es:si + 2]                 ; count
    add si, 4

.palette_loop:
    test cx, cx
    jz .palette_done
    mov dx, 0x3C8
    mov al, bl
    out dx, al                          ; Set DAC write index
    inc bx

    mov dx, 0x3C9
    mov al, [es:si]                     ; Red
    out dx, al
    mov al, [es:si + 1]                 ; Green
    out dx, al
    mov al, [es:si + 2]                 ; Blue
    out dx, al
    add si, 3
    dec cx
    jmp .palette_loop

.palette_done:
    xor ax, ax
    jmp .ioctl_exit

.bad_arg:
    mov ax, -EINVAL

.ioctl_exit:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; fb286_set_mode: Switch hardware video mode in Ring 0
; Input:
;   AX = Video mode (FB_MODE_*)
; Returns:
;   AX = 0 on success, -EINVAL on unsupported mode
; ----------------------------------------------------------------------------
fb286_set_mode:
    push bx
    push dx
    push si

    cmp ax, FB_MODE_VGA_640x480x16      ; 0x0012
    je .set_vga_640x480

    cmp ax, FB_MODE_VGA_320x200x256     ; 0x0013
    je .set_vga_320x200

    cmp ax, FB_MODE_TEXT_80x25          ; 0x0003
    je .set_text_80x25

    mov ax, -EINVAL
    jmp .set_mode_exit

.set_vga_640x480:
    mov word [fb286_current_mode], FB_MODE_VGA_640x480x16
    mov word [fb286_width], 640
    mov word [fb286_height], 480
    mov byte [fb286_bpp], 4
    mov byte [fb286_planes], 4
    mov word [fb286_stride], 80
    mov word [fb286_phys_base_lo], 0x0000
    mov byte [fb286_phys_base_hi], 0x0A         ; Physical 0x0A0000
    mov word [fb286_aperture_size], 0xFFFF      ; 64 KB aperture
    mov byte [fb286_is_graphics], 1

    ; Program standard VGA 640x480x16 hardware registers
    call fb286_program_vga_planar
    xor ax, ax
    jmp .set_mode_exit

.set_vga_320x200:
    mov word [fb286_current_mode], FB_MODE_VGA_320x200x256
    mov word [fb286_width], 320
    mov word [fb286_height], 200
    mov byte [fb286_bpp], 8
    mov byte [fb286_planes], 1
    mov word [fb286_stride], 320
    mov word [fb286_phys_base_lo], 0x0000
    mov byte [fb286_phys_base_hi], 0x0A         ; Physical 0x0A0000
    mov word [fb286_aperture_size], 0xFFFF      ; 64 KB aperture
    mov byte [fb286_is_graphics], 1

    ; Program standard VGA 320x200 Mode 13h hardware registers
    call fb286_program_vga_mode13
    xor ax, ax
    jmp .set_mode_exit

.set_text_80x25:
    mov word [fb286_current_mode], FB_MODE_TEXT_80x25
    mov word [fb286_width], 80
    mov word [fb286_height], 25
    mov byte [fb286_bpp], 4
    mov byte [fb286_planes], 1
    mov word [fb286_stride], 160
    mov word [fb286_phys_base_lo], 0x8000
    mov byte [fb286_phys_base_hi], 0x0B         ; Physical 0x0B8000
    mov word [fb286_aperture_size], 0x7FFF
    mov byte [fb286_is_graphics], 0

    ; Program standard VGA 80x25 text mode registers
    call fb286_program_vga_text
    xor ax, ax

.set_mode_exit:
    pop si
    pop dx
    pop bx
    ret

; ----------------------------------------------------------------------------
; fb286_map_ldt: Map 64KB Video Aperture into active task's LDT (0x001F)
; ----------------------------------------------------------------------------
fb286_map_ldt:
    pusha

    ; Determine active task PID
    call ldt_get_current_pid            ; AL = PID

    ; LDT Entry 3: LDT_UFB_SEL = 0x001F (Index 3, TI=1, RPL=3)
    mov ah, 3                           ; Entry 3
    mov dl, [fb286_phys_base_hi]        ; Base 23..16 (e.g. 0x0A)
    mov si, [fb286_phys_base_lo]        ; Base 15..0  (e.g. 0x0000)
    mov bx, [fb286_aperture_size]       ; Limit (0xFFFF = 64 KB)
    mov cl, (DESC_PRESENT | DESC_DPL_3 | DESC_SEG | DESC_WRITABLE) ; 0xF2
    mov ch, VM_FLAG_MMIO                ; Software VM flag: MMIO aperture (0x20)
    xor dh, dh
    call ldt_set_entry

    popa
    ret

; ----------------------------------------------------------------------------
; fb286_set_iopl3: Set or clear IOPL=3 in caller's saved FLAGS
; Input:
;   AX = 1 (grant IOPL=3), 0 (restrict to IOPL=0)
; ----------------------------------------------------------------------------
fb286_set_iopl3:
    ; Caller's saved FLAGS image on kernel stack is at [bp + 20]
    test ax, ax
    jz .clear_iopl

    ; Set bits 12-13 (FLAGS_IOPL_3 = 0x3000)
    or word [bp + 20], 0x3000
    ret

.clear_iopl:
    ; Clear bits 12-13
    and word [bp + 20], ~0x3000
    ret

; ----------------------------------------------------------------------------
; fb286_read / fb286_write: Far copy to/from VRAM using GDT_COPY_A_SEL
; ----------------------------------------------------------------------------
fb286_read:
    xor ax, ax
    ret

fb286_write:
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es

    ; Setup GDT_COPY_A_SEL to point to VRAM base
    mov dl, [fb286_phys_base_hi]
    mov bx, [fb286_phys_base_lo]
    mov [gdt_table + 0x28 + 2], bx
    mov [gdt_table + 0x28 + 4], dl

    ; Copy from caller buffer DS:SI to ES:DI (where ES = GDT_COPY_A_SEL)
    mov ax, GDT_COPY_A_SEL
    mov es, ax
    xor di, di                          ; Start of aperture

    mov cx, dx                          ; Byte count in DX
    cld
    rep movsb

    pop es
    pop ds
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    mov ax, dx                          ; Return bytes written
    ret

; ----------------------------------------------------------------------------
; Hardware Register Programmers for Standard VGA
; ----------------------------------------------------------------------------
fb286_program_vga_planar:
    push dx
    push ax

    ; Sequencer reset
    mov dx, 0x3C4
    mov ax, 0x0100                      ; Synchronous reset
    out dx, ax

    ; Misc Output: 0x3C2 = 0xE3 (640x480, 25.175 MHz clock, 60 Hz)
    mov dx, 0x3C2
    mov al, 0xE3
    out dx, al

    ; Sequencer: Clocking Mode & Plane Enable
    mov dx, 0x3C4
    mov ax, 0x0101                      ; 8 dots per clock
    out dx, ax
    mov ax, 0x0F02                      ; Enable all 4 bitplanes for write
    out dx, ax
    mov ax, 0x0003                      ; Char map select
    out dx, ax
    mov ax, 0x0604                      ; Memory mode: Chain-4 OFF, Extended mem ON
    out dx, ax
    mov ax, 0x0300                      ; End reset
    out dx, ax

    ; Unlock CRTC registers (Port 0x3D4, index 0x11, clear bit 7)
    mov dx, 0x3D4
    mov al, 0x11
    out dx, al
    inc dx
    in al, dx
    and al, 0x7F
    out dx, al
    dec dx

    ; Graphics Controller (Port 0x3CE)
    mov dx, 0x3CE
    mov ax, 0x0000                      ; Set/Reset = 0
    out dx, ax
    mov ax, 0x0001                      ; Enable Set/Reset = 0
    out dx, ax
    mov ax, 0x0002                      ; Color Compare = 0
    out dx, ax
    mov ax, 0x0003                      ; Data Rotate = 0
    out dx, ax
    mov ax, 0x0004                      ; Read Map Select = Plane 0
    out dx, ax
    mov ax, 0x0005                      ; Mode = Write mode 0, Read mode 0
    out dx, ax
    mov ax, 0x0506                      ; Misc: 64KB at 0xA0000, Graphics mode
    out dx, ax
    mov ax, 0x0F07                      ; Color Don't Care = All planes
    out dx, ax
    mov ax, 0xFF08                      ; Bit Mask = 0xFF (all pixels enabled)
    out dx, ax

    pop ax
    pop dx
    ret

fb286_program_vga_mode13:
    push dx
    push ax

    ; Misc Output: 0x3C2 = 0x63 (320x200, 25.175 MHz clock, 70 Hz)
    mov dx, 0x3C2
    mov al, 0x63
    out dx, al

    ; Sequencer Mode 13h (Chain-4 enabled)
    mov dx, 0x3C4
    mov ax, 0x0E04                      ; Chain-4 ON, Extended mem ON
    out dx, ax

    ; Graphics Controller
    mov dx, 0x3CE
    mov ax, 0x4005                      ; 256-color shift mode
    out dx, ax
    mov ax, 0x0506                      ; 64KB at 0xA0000
    out dx, ax

    pop ax
    pop dx
    ret

fb286_program_vga_text:
    push dx
    push ax

    ; Misc Output: 0x3C2 = 0x67 (720x400 / 80x25 text, 28.322 MHz clock)
    mov dx, 0x3C2
    mov al, 0x67
    out dx, al

    ; Sequencer Text Mode
    mov dx, 0x3C4
    mov ax, 0x0304                      ; Extended memory, odd/even text mode
    out dx, ax

    ; Graphics Controller
    mov dx, 0x3CE
    mov ax, 0x1005                      ; Odd/even text mode
    out dx, ax
    mov ax, 0x0E06                      ; Text aperture at 0xB8000 (32 KB)
    out dx, ax

    pop ax
    pop dx
    ret

section .data
align 2
fb286_current_mode:  dw FB_MODE_TEXT_80x25
fb286_width:         dw 80
fb286_height:        dw 25
fb286_bpp:           db 4
fb286_planes:        db 1
fb286_stride:        dw 160
fb286_phys_base_lo:  dw 0x8000
fb286_phys_base_hi:  db 0x0B
fb286_aperture_size: dw 0x7FFF
fb286_is_graphics:   db 0

str_fb286_ok: db "[FB286] Native Protected-Mode Framebuffer (/dev/fb0) driver initialized", 13, 10, 0

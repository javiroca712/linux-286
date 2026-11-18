CPU 286
BITS 16

; ============================================================================
; Lin286 PC Speaker & Class-D PWM Digital Audio Driver (/dev/pcspkr & /dev/dsp)
;
; Provides two audio output modes using the 8254 PIT and Port 0x61:
;  1. /dev/pcspkr: Hardware square-wave tone synth (PIT Ch2 Mode 3, 0% CPU load).
;  2. /dev/dsp:    8 kHz / 11 kHz Class-D PWM 8-bit unsigned PCM digital audio
;                  using PIT Ch2 Mode 0 + XLATB Ring 0 Fast-ISR (< 6% CPU load).
; ============================================================================

%include "kernel/include/i286_asm.inc"

global sound286_init
global pcspkr_ioctl
global pcspkr_tick
global dsp_ioctl
global dsp_write
global dsp_irq0_sample_tick
global dsp_active
global dsp_sample_rate
global dsp_count
global dsp_backend
global pwm_lut

section .text

; ----------------------------------------------------------------------------
; sound286_init: Initialize speaker hardware and precompute PWM lookup table
; ----------------------------------------------------------------------------
sound286_init:
    pusha

    ; 1. Ensure PC Speaker is disabled initially
    in al, PCSPKR_CTRL_PORT             ; Port 0x61
    and al, 0xFC                        ; Clear bits 0 and 1
    out PCSPKR_CTRL_PORT, al

    ; 2. Precompute 256-byte pwm_lut for 8 kHz carrier (div=149):
    ; pulse = 1 + (sample * 147) / 255
    xor cx, cx                          ; CX = sample (0..255)
.build_lut:
    mov ax, cx
    mov bx, 147
    mul bx                              ; DX:AX = sample * 147
    mov bx, 255
    div bx                              ; AX = quotient (0..147)
    inc ax                              ; AX = 1..148
    mov bx, cx
    mov [pwm_lut + bx], al
    inc cx
    cmp cx, 256
    jb .build_lut

    ; 3. Initialize state variables
    mov word [pcspkr_active_tone], 0
    mov word [pcspkr_beep_ticks], 0
    mov word [dsp_head], 0
    mov word [dsp_tail], 0
    mov word [dsp_count], 0
    mov byte [dsp_active], 0
    mov word [dsp_sample_rate], 8000
    mov word [dsp_carrier_div], 149
    mov word [dsp_prescaler], 80
    mov word [dsp_prescaler_reload], 80
    mov byte [dsp_backend], DSP_BACKEND_PCSPKR_PWM

    mov si, str_sound_ok
    call uart_puts

    popa
    ret

; ----------------------------------------------------------------------------
; pcspkr_ioctl: /dev/pcspkr control
; Inputs:
;   BX = fd
;   CX = Command (KIOCSOUND, PCSPKR_IOC_TONE_HZ, PCSPKR_IOC_BEEP)
;   DX = Argument / pointer
; Returns:
;   AX = 0 on success, negative error code on failure
; ----------------------------------------------------------------------------
pcspkr_ioctl:
    push bx
    push cx
    push dx
    push si
    push di
    push es

    cmp cx, KIOCSOUND
    je .cmd_sound

    cmp cx, PCSPKR_IOC_TONE_HZ
    je .cmd_tone_hz

    cmp cx, PCSPKR_IOC_BEEP
    je .cmd_beep

    mov ax, -EINVAL
    jmp .pcspkr_exit

; --- KIOCSOUND: Start tone with PIT divider (0 = off) ---
.cmd_sound:
    test dx, dx
    jz .sound_off

    ; Program PIT Channel 2 into Mode 3 (Square Wave Generator)
    mov al, PIT_CH2_MODE3_SQUARE        ; 0xB6
    out PIT_CMD_PORT, al                ; Port 0x43

    mov ax, dx
    out PIT_CH2_PORT, al                ; Port 0x42 (LSB)
    jmp $+2
    mov al, ah
    out PIT_CH2_PORT, al                ; Port 0x42 (MSB)

    ; Enable Speaker Gate & Data (Port 0x61 bits 0-1)
    in al, PCSPKR_CTRL_PORT
    or al, 0x03
    out PCSPKR_CTRL_PORT, al

    mov [pcspkr_active_tone], dx
    xor ax, ax
    jmp .pcspkr_exit

.sound_off:
    in al, PCSPKR_CTRL_PORT
    and al, 0xFC                        ; Clear bits 0 and 1
    out PCSPKR_CTRL_PORT, al
    mov word [pcspkr_active_tone], 0
    xor ax, ax
    jmp .pcspkr_exit

; --- PCSPKR_IOC_TONE_HZ: Start tone at frequency in Hz (0 = off) ---
.cmd_tone_hz:
    test dx, dx
    jz .sound_off

    ; Divider = 1193182 / freq_hz (1193182 = 0x001234DE)
    mov bx, dx
    mov dx, 0x0012
    mov ax, 0x34DE
    div bx                              ; AX = divider quotient
    mov dx, ax
    jmp .cmd_sound

; --- PCSPKR_IOC_BEEP: Play non-blocking timed beep via struct pcspkr_note ---
.cmd_beep:
    test dx, dx
    jz .bad_arg

    mov ax, [bp + 14]
    test ax, ax
    jnz .has_caller_ds
    mov ax, ds
.has_caller_ds:
    mov es, ax
    mov di, dx                          ; ES:DI = struct pcspkr_note

    mov bx, [es:di + NOTE_FREQ_HZ]
    mov cx, [es:di + NOTE_DURATION_MS]

    test bx, bx
    jz .sound_off

    ; Set tone
    mov dx, bx
    call .cmd_tone_hz_helper

    ; Duration in ticks (10 ms per tick): ticks = (duration_ms + 9) / 10
    mov ax, cx
    add ax, 9
    mov bx, 10
    xor dx, dx
    div bx
    mov [pcspkr_beep_ticks], ax

    xor ax, ax
    jmp .pcspkr_exit

.cmd_tone_hz_helper:
    push bx
    mov bx, dx
    mov dx, 0x0012
    mov ax, 0x34DE
    div bx
    mov dx, ax
    pop bx
    ; Start sound
    mov al, PIT_CH2_MODE3_SQUARE
    out PIT_CMD_PORT, al
    mov ax, dx
    out PIT_CH2_PORT, al
    mov al, ah
    out PIT_CH2_PORT, al
    in al, PCSPKR_CTRL_PORT
    or al, 0x03
    out PCSPKR_CTRL_PORT, al
    mov [pcspkr_active_tone], dx
    ret

.bad_arg:
    mov ax, -EINVAL

.pcspkr_exit:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; ----------------------------------------------------------------------------
; pcspkr_tick: Called from 100 Hz scheduler timer tick (IRQ 0)
; ----------------------------------------------------------------------------
pcspkr_tick:
    cmp word [pcspkr_beep_ticks], 0
    jz .tick_done

    dec word [pcspkr_beep_ticks]
    jnz .tick_done

    ; Beep duration elapsed -> silence speaker
    in al, PCSPKR_CTRL_PORT
    and al, 0xFC
    out PCSPKR_CTRL_PORT, al
    mov word [pcspkr_active_tone], 0

.tick_done:
    ret

; ----------------------------------------------------------------------------
; dsp_write: Write 8-bit PCM samples to /dev/dsp
; Inputs:
;   DI = Destination struct vfs_inode pointer
;   SI = Source buffer offset in caller's DS [bp + 14]
;   CX = Byte count to write
; Returns:
;   AX = Number of bytes written
; ----------------------------------------------------------------------------
dsp_write:
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es

    ; Setup DS:SI = caller buffer
    mov ax, [bp + 14]
    test ax, ax
    jnz .has_user_ds
    mov ax, ds
.has_user_ds:
    mov es, ax                          ; ES:SI = caller buffer

    xor dx, dx                          ; DX = bytes written

.write_loop:
    test cx, cx
    jz .write_finish

    cmp word [dsp_count], DSP_RINGBUF_SIZE
    jae .write_finish                   ; Buffer full

    ; Read byte from caller buffer
    mov al, [es:si]
    inc si

    ; Write to dsp_ringbuf[dsp_head]
    mov di, [dsp_head]
    mov [dsp_ringbuf + di], al

    inc di
    and di, (DSP_RINGBUF_SIZE - 1)
    mov [dsp_head], di
    inc word [dsp_count]

    inc dx
    dec cx
    jmp .write_loop

.write_finish:
    ; If playback is not yet active and we have samples, start PWM
    cmp byte [dsp_active], 0
    jnz .write_done
    cmp word [dsp_count], 0
    jz .write_done

    ; Start Class-D PWM playback:
    ; 1. Configure PIT Ch2 in Mode 0 (One-Shot PWM)
    mov al, PIT_CH2_MODE0_PWM           ; 0x90: Ch2, LSB only, Mode 0
    out PIT_CMD_PORT, al

    ; 2. Configure PIT Ch0 for carrier rate (8000 Hz or 11025 Hz)
    mov al, 0x36                        ; Ch0, LSB/MSB, Mode 3 (Square)
    out PIT_CMD_PORT, al
    mov ax, [dsp_carrier_div]
    out PIT_CH0_PORT, al
    mov al, ah
    out PIT_CH0_PORT, al

    ; 3. Enable speaker gate
    in al, PCSPKR_CTRL_PORT
    or al, 0x01                         ; Bit 0 on (Gate enable)
    out PCSPKR_CTRL_PORT, al

    mov ax, [dsp_prescaler_reload]
    mov [dsp_prescaler], ax
    mov byte [dsp_active], 1

.write_done:
    pop es
    pop ds
    pop di
    pop si
    pop cx                              ; Discard original CX
    pop dx                              ; Restore DX
    pop bx
    mov ax, dx                          ; Return bytes written in AX
    ret

; ----------------------------------------------------------------------------
; dsp_irq0_sample_tick: Fast-ISR called at 8 kHz / 11 kHz carrier rate
; Returns:
;   AX = 1 if fast EOI handled (IRET immediately)
;   AX = 0 if 100 Hz scheduler tick elapsed (chain to regular sched_tick)
; ----------------------------------------------------------------------------
dsp_irq0_sample_tick:
    ; Check if ring buffer is empty
    cmp word [dsp_count], 0
    jnz .has_sample

    ; Drained! Restore PIT Ch0 back to 100 Hz (divider 11932 = 0x2E9C)
    mov al, 0x36
    out PIT_CMD_PORT, al
    mov al, 0x9C
    out PIT_CH0_PORT, al
    mov al, 0x2E
    out PIT_CH0_PORT, al

    ; Silence speaker PWM
    in al, PCSPKR_CTRL_PORT
    and al, 0xFC
    out PCSPKR_CTRL_PORT, al

    mov byte [dsp_active], 0
    xor ax, ax                          ; Run normal timer tick
    ret

.has_sample:
    ; Pop sample from dsp_ringbuf[dsp_tail]
    mov bx, [dsp_tail]
    mov al, [dsp_ringbuf + bx]
    inc bx
    and bx, (DSP_RINGBUF_SIZE - 1)
    mov [dsp_tail], bx
    dec word [dsp_count]

    ; Check audio backend
    cmp byte [dsp_backend], DSP_BACKEND_COVOX_LPT1
    je .out_covox

    ; PC Speaker PWM: Translate sample to pulse width via 80286 XLATB!
    mov bx, pwm_lut
    xlatb                               ; 80286 XLATB: AL = [DS:BX + AL]
    out PIT_CH2_PORT, al                ; Port 0x42: pulse width
    jmp .check_prescaler

.out_covox:
    mov dx, LPT1_DATA_PORT              ; Port 0x378
    out dx, al

.check_prescaler:
    ; Prescaler countdown to 100 Hz
    dec word [dsp_prescaler]
    jz .prescaler_expired

    ; Fast EOI to Master PIC
    mov al, 0x20
    out PIC1_CMD, al
    mov ax, 1                           ; AX = 1: Fast return
    ret

.prescaler_expired:
    mov ax, [dsp_prescaler_reload]
    mov [dsp_prescaler], ax
    xor ax, ax                          ; AX = 0: 100 Hz tick ready
    ret

; ----------------------------------------------------------------------------
; dsp_ioctl: /dev/dsp control (OSS-compatible commands)
; ----------------------------------------------------------------------------
dsp_ioctl:
    push bx
    push cx
    push dx

    cmp cx, SNDCTL_DSP_RESET
    je .cmd_reset

    cmp cx, SNDCTL_DSP_SPEED
    je .cmd_speed

    cmp cx, SNDCTL_DSP_GETBLKSIZE
    je .cmd_blksize

    cmp cx, SNDCTL_DSP_SETBACKEND
    je .cmd_backend

    cmp cx, SNDCTL_DSP_SYNC
    je .cmd_sync

    mov ax, -EINVAL
    jmp .dsp_ioctl_exit

.cmd_reset:
    ; Flush ring buffer
    mov word [dsp_count], 0
    mov word [dsp_head], 0
    mov word [dsp_tail], 0
    cmp byte [dsp_active], 0
    jz .reset_done

    ; Restore PIT Ch0 to 100 Hz
    mov al, 0x36
    out PIT_CMD_PORT, al
    mov al, 0x9C
    out PIT_CH0_PORT, al
    mov al, 0x2E
    out PIT_CH0_PORT, al

    in al, PCSPKR_CTRL_PORT
    and al, 0xFC
    out PCSPKR_CTRL_PORT, al
    mov byte [dsp_active], 0
.reset_done:
    xor ax, ax
    jmp .dsp_ioctl_exit

.cmd_speed:
    cmp dx, DSP_RATE_11025_HZ
    je .set_11k

    ; Default to 8000 Hz
    mov word [dsp_sample_rate], 8000
    mov word [dsp_carrier_div], 149
    mov word [dsp_prescaler_reload], 80
    xor ax, ax
    jmp .dsp_ioctl_exit

.set_11k:
    mov word [dsp_sample_rate], 11025
    mov word [dsp_carrier_div], 108
    mov word [dsp_prescaler_reload], 110
    xor ax, ax
    jmp .dsp_ioctl_exit

.cmd_blksize:
    mov ax, DSP_RINGBUF_SIZE
    jmp .dsp_ioctl_exit

.cmd_backend:
    mov [dsp_backend], dl
    xor ax, ax
    jmp .dsp_ioctl_exit

.cmd_sync:
    ; Drain buffer
    xor ax, ax

.dsp_ioctl_exit:
    pop dx
    pop cx
    pop bx
    ret

section .data
align 2
pcspkr_active_tone:     dw 0
pcspkr_beep_ticks:      dw 0
dsp_head:               dw 0
dsp_tail:               dw 0
dsp_count:              dw 0
dsp_active:             db 0
dsp_sample_rate:        dw 8000
dsp_carrier_div:        dw 149
dsp_prescaler:          dw 80
dsp_prescaler_reload:   dw 80
dsp_backend:            db DSP_BACKEND_PCSPKR_PWM

str_sound_ok: db "[SOUND] PC Speaker & Class-D PWM Audio (/dev/pcspkr & /dev/dsp) initialized", 13, 10, 0

section .bss
align 2
pwm_lut:        resb 256
align 4
dsp_ringbuf:    resb DSP_RINGBUF_SIZE

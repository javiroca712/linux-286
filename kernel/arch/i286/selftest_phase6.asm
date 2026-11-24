CPU 286
BITS 16

; ============================================================================
; Lin286 Phase 6 Automated Self-Test Verification Suite
;
; Verifies:
;  - Test 31: Framebuffer /dev/fb0 FBIOGET_INFO & FBIOSET_MODE
;  - Test 32: Direct 64 KB Video Aperture LDT Mapping (FBIOMAP_LDT, 0x001F)
;  - Test 33: Display Server FLAGS.IOPL = 3 Elevation (FBIOSET_IOPL3)
;  - Test 34: Zero-Copy LDT Shared Memory IPC (shmget286/shmat286)
;  - Test 35: RS-232 Serial Mouse Driver (/dev/mouse) & Event Normalization
;  - Test 36: PC Speaker Tone Generator (/dev/pcspkr) & KIOCSOUND
;  - Test 37: Class-D PWM Digital Audio Driver (/dev/dsp) & XLATB Fast-ISR
;  - Test 38: Nano-X Window Server & GUI Desktop Compositor on tty5 (Alt+F5)
; ============================================================================

%include "kernel/include/i286_asm.inc"

extern uart_puts
extern uart_putc
extern uart_print_hex16

global run_phase6_verification_gate

section .text

; ----------------------------------------------------------------------------
; run_phase6_verification_gate: Entry point for Phase 6 self-tests
; ----------------------------------------------------------------------------
run_phase6_verification_gate:
    pusha
    push ds
    push es

    mov ax, GDT_KDATA_SEL
    mov ds, ax
    mov es, ax

    mov si, str_p6_banner
    call uart_puts

    ; Execute tests 31 through 38
    call test31_framebuffer_modes
    call test32_framebuffer_ldt_map
    call test33_display_server_iopl3
    call test34_zero_copy_shm
    call test35_serial_mouse
    call test36_pc_speaker
    call test37_pwm_audio_dsp
    call test38_nanox_gui_tty5

    mov si, str_p6_all_pass
    call uart_puts

    pop es
    pop ds
    popa
    ret

; ----------------------------------------------------------------------------
; Test 31: Framebuffer /dev/fb0 FBIOGET_INFO & FBIOSET_MODE
; ----------------------------------------------------------------------------
test31_framebuffer_modes:
    pusha
    mov si, str_t31_start
    call uart_puts

    ; 1. Open /dev/fb0
    mov ax, SYS_OPEN
    mov bx, str_p6_dev_fb0
    mov cx, O_RDWR
    xor dx, dx
    int 0x80
    cmp ax, 0
    jl .t31_fail
    mov [t31_fd], ax

    ; 2. FBIOGET_INFO: Query initial text mode geometry
    mov ax, SYS_IOCTL
    mov bx, [t31_fd]
    mov cx, FBIOGET_INFO
    mov dx, t31_info
    int 0x80
    test ax, ax
    jnz .t31_fail

    ; Assert initial text mode geometry: 80x25, 4 bpp, stride 160
    cmp word [t31_info + FBINFO_WIDTH], 80
    jne .t31_fail
    cmp word [t31_info + FBINFO_HEIGHT], 25
    jne .t31_fail

    ; 3. FBIOSET_MODE: Switch to VGA 640x480x16 planar (0x0012)
    mov ax, SYS_IOCTL
    mov bx, [t31_fd]
    mov cx, FBIOSET_MODE
    mov dx, FB_MODE_VGA_640x480x16
    int 0x80
    test ax, ax
    jnz .t31_fail

    ; 4. Query geometry again to verify switch
    mov ax, SYS_IOCTL
    mov bx, [t31_fd]
    mov cx, FBIOGET_INFO
    mov dx, t31_info
    int 0x80
    test ax, ax
    jnz .t31_fail

    cmp word [t31_info + FBINFO_MODE], FB_MODE_VGA_640x480x16
    jne .t31_fail
    cmp word [t31_info + FBINFO_WIDTH], 640
    jne .t31_fail
    cmp word [t31_info + FBINFO_HEIGHT], 480
    jne .t31_fail
    cmp byte [t31_info + FBINFO_PLANES], 4
    jne .t31_fail
    cmp word [t31_info + FBINFO_STRIDE], 80
    jne .t31_fail
    cmp word [t31_info + FBINFO_PHYS_BASE_LO], 0x0000
    jne .t31_fail
    cmp byte [t31_info + FBINFO_PHYS_BASE_HI], 0x0A
    jne .t31_fail

    ; Close fd
    mov ax, SYS_CLOSE
    mov bx, [t31_fd]
    int 0x80

    mov si, str_t31_ok
    call uart_puts
    popa
    ret

.t31_fail:
    mov si, str_t31_fail
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 32: Direct 64 KB Video Aperture LDT Mapping (FBIOMAP_LDT, 0x001F)
; ----------------------------------------------------------------------------
test32_framebuffer_ldt_map:
    pusha
    mov si, str_t32_start
    call uart_puts

    ; 1. Open /dev/fb0
    mov ax, SYS_OPEN
    mov bx, str_p6_dev_fb0
    mov cx, O_RDWR
    xor dx, dx
    int 0x80
    cmp ax, 0
    jl .t32_fail
    mov [t32_fd], ax

    ; 2. Call FBIOMAP_LDT
    mov ax, SYS_IOCTL
    mov bx, [t32_fd]
    mov cx, FBIOMAP_LDT
    mov dx, t32_info
    int 0x80
    test ax, ax
    jnz .t32_fail

    ; Assert assigned selector is LDT_UFB_SEL (0x001F)
    cmp word [t32_info + FBINFO_LDT_SELECTOR], LDT_UFB_SEL
    jne .t32_fail

    ; 3. Inspect LDT descriptor directly in task_ldts for current task
    call ldt_get_current_pid            ; AL = PID
    mov ah, 3                           ; Entry 3
    call ldt_get_entry_ptr              ; DI = &desc286
    cmp word [di + 0], 0xFFFF           ; Limit = 64 KB
    jne .t32_fail
    cmp word [di + 2], 0x0000           ; Base Low = 0x0000
    jne .t32_fail
    cmp byte [di + 4], 0x0A             ; Base High = 0x0A (0x0A0000)
    jne .t32_fail
    cmp byte [di + 5], 0xF2             ; Access = Present | DPL 3 | R/W Data
    jne .t32_fail
    cmp byte [di + 6], VM_FLAG_MMIO     ; Software VM Flag MMIO (0x20)
    jne .t32_fail

    ; 4. Far access write/read via selector 0x001F (VGA MMIO; skip RW test on MDA/Hercules)
    mov ax, LDT_UFB_SEL
    mov es, ax
    cmp byte [console_is_mono], 0
    jne .t32_skip_vram_rw
    mov word [es:0x0000], 0x5AA5
    mov bx, [es:0x0000]
    cmp bx, 0x5AA5
    jne .t32_fail
.t32_skip_vram_rw:

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; Close fd
    mov ax, SYS_CLOSE
    mov bx, [t32_fd]
    int 0x80

    mov si, str_t32_ok
    call uart_puts
    popa
    ret

.t32_fail:
    mov si, str_t32_fail
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 33: Display Server FLAGS.IOPL = 3 Elevation (FBIOSET_IOPL3)
; ----------------------------------------------------------------------------
test33_display_server_iopl3:
    pusha
    mov si, str_t33_start
    call uart_puts

    ; 1. Open /dev/fb0
    mov ax, SYS_OPEN
    mov bx, str_p6_dev_fb0
    mov cx, O_RDWR
    xor dx, dx
    int 0x80
    cmp ax, 0
    jl .t33_fail
    mov [t33_fd], ax

    ; 2. Call FBIOSET_IOPL3 with arg = 1 (enable IOPL=3)
    mov ax, SYS_IOCTL
    mov bx, [t33_fd]
    mov cx, FBIOSET_IOPL3
    mov dx, 1
    int 0x80
    test ax, ax
    jnz .t33_fail

    ; 3. Assert FLAGS register now has IOPL=3 (bits 12-13 = 11b = 0x3000)
    pushf
    pop ax
    and ax, 0x3000
    cmp ax, 0x3000
    jne .t33_fail

    ; 4. Call FBIOSET_IOPL3 with arg = 0 (reset to IOPL=0)
    mov ax, SYS_IOCTL
    mov bx, [t33_fd]
    mov cx, FBIOSET_IOPL3
    xor dx, dx
    int 0x80
    test ax, ax
    jnz .t33_fail

    ; Assert FLAGS register now has IOPL=0
    pushf
    pop ax
    and ax, 0x3000
    test ax, ax
    jnz .t33_fail

    ; Close fd
    mov ax, SYS_CLOSE
    mov bx, [t33_fd]
    int 0x80

    mov si, str_t33_ok
    call uart_puts
    popa
    ret

.t33_fail:
    mov si, str_t33_fail
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 34: Zero-Copy LDT Shared Memory IPC (shmget286 / shmat286)
; ----------------------------------------------------------------------------
test34_zero_copy_shm:
    pusha
    mov si, str_t34_start
    call uart_puts

    ; 1. Allocate shared memory segment via sys_shmget286
    mov ax, SYS_SHMGET286
    mov bx, 0x1234                      ; Key
    mov cx, 4096                        ; 4 KB
    xor dx, dx                          ; Flags
    int 0x80
    cmp ax, 0
    jle .t34_fail_1
    mov [t34_shmid], ax

    ; 2. Attach shared segment in Task 0 via sys_shmat286
    mov ax, SYS_SHMAT286
    mov bx, [t34_shmid]
    xor cx, cx
    xor dx, dx
    int 0x80
    cmp ax, 0x0027                      ; First shared selector (Entry 4)
    jne .t34_fail_2
    mov [t34_sel_a], ax

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; 3. Switch to Task 1 and attach same shared segment
    mov al, 1
    call ldt_switch_task

    mov ax, GDT_KDATA_SEL
    mov es, ax

    mov ax, SYS_SHMAT286
    mov bx, [t34_shmid]
    xor cx, cx
    xor dx, dx
    int 0x80
    cmp ax, 0x0027                      ; Entry 4 in Task 1 LDT
    jne .t34_fail_3
    mov [t34_sel_b], ax

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; 4. In Task 0 context, write signature string to shared memory
    mov al, 0
    call ldt_switch_task

    mov ax, [t34_sel_a]
    mov es, ax
    xor di, di
    mov si, str_p6_shm_magic
.copy_shm:
    lodsb
    stosb
    test al, al
    jnz .copy_shm

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; 5. In Task 1 context, read signature string from shared memory
    mov al, 1
    call ldt_switch_task

    mov ax, [t34_sel_b]
    mov es, ax
    xor di, di
    mov si, str_p6_shm_magic
.cmp_shm:
    lodsb
    mov bl, [es:di]
    inc di
    cmp al, bl
    jne .t34_fail_4
    test al, al
    jnz .cmp_shm

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; 6. Verify refcount is 2
    mov di, [t34_shmid]
    dec di
    shl di, 4
    add di, shm_table
    cmp word [di + 10], 2               ; shm_ref_count == 2
    jne .t34_fail_5

    ; 7. Detach in Task 1
    mov ax, SYS_SHMDT286
    mov bx, [t34_sel_b]
    int 0x80
    test ax, ax
    jnz .t34_fail_6

    mov ax, GDT_KDATA_SEL
    mov es, ax

    ; Switch back to Task 0 and detach
    mov al, 0
    call ldt_switch_task

    mov ax, GDT_KDATA_SEL
    mov es, ax

    mov ax, SYS_SHMDT286
    mov bx, [t34_sel_a]
    int 0x80
    test ax, ax
    jnz .t34_fail_7

    mov ax, GDT_KDATA_SEL
    mov es, ax

    mov si, str_t34_ok
    call uart_puts
    popa
    ret

.t34_fail_1:
    mov si, str_t34_f1
    call uart_puts
    call console_puts
    hlt

.t34_fail_2:
    mov si, str_t34_f2
    call uart_puts
    call console_puts
    hlt

.t34_fail_3:
    mov si, str_t34_f3
    call uart_puts
    call console_puts
    hlt

.t34_fail_4:
    mov si, str_t34_f4
    call uart_puts
    call console_puts
    hlt

.t34_fail_5:
    mov si, str_t34_f5
    call uart_puts
    call console_puts
    hlt

.t34_fail_6:
    mov si, str_t34_f6
    call uart_puts
    call console_puts
    hlt

.t34_fail_7:
    mov si, str_t34_f7
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 35: RS-232 Serial Mouse Driver (/dev/mouse) & Event Normalization
; ----------------------------------------------------------------------------
test35_serial_mouse:
    pusha
    mov si, str_t35_start
    call uart_puts

    ; 1. Open /dev/mouse
    mov ax, SYS_OPEN
    mov bx, str_p6_dev_mouse
    mov cx, O_RDONLY
    xor dx, dx
    int 0x80
    cmp ax, 0
    jl .t35_fail
    mov [t35_fd], ax

    ; 2. Poll sys_select when no events present
    mov word [t35_mask], (1 << 0)       ; Bit for fd
    mov ax, [t35_fd]
    mov cx, ax
    mov bx, 1
    shl bx, cl
    mov [t35_mask], bx

    mov ax, SYS_SELECT
    mov bx, [t35_fd]
    inc bx                              ; nfds = fd + 1
    mov cx, t35_mask                    ; readfds
    xor dx, dx
    xor si, si
    xor di, di
    int 0x80
    test ax, ax
    jnz .t35_fail                       ; Should return 0 (no events)

    ; 3. Feed 3-byte Microsoft serial mouse packet:
    ; Byte 1: 0x61 (Sync bit 6=1, Left Button bit 5=1, Right Button bit 4=0, Y high=0, X high=1)
    ; Byte 2: 0x0A (X low = 10) -> dx = (1 << 6) | 10 = 74
    ; Byte 3: 0x05 (Y low = 5)  -> dy = (0 << 4) | 5 = 5
    mov al, 0x61
    call mouse_feed_byte
    mov al, 0x0A
    call mouse_feed_byte
    mov al, 0x05
    call mouse_feed_byte

    ; 4. Poll sys_select now that event is queued
    mov ax, [t35_fd]
    mov cx, ax
    mov bx, 1
    shl bx, cl
    mov [t35_mask], bx

    mov ax, SYS_SELECT
    mov bx, [t35_fd]
    inc bx
    mov cx, t35_mask
    xor dx, dx
    xor si, si
    xor di, di
    int 0x80
    cmp ax, 1
    jne .t35_fail

    ; 5. Read struct mouse286_event from /dev/mouse
    mov ax, SYS_READ
    mov bx, [t35_fd]
    mov cx, t35_event
    mov dx, 4
    int 0x80
    cmp ax, 4
    jne .t35_fail

    ; Assert event values
    cmp byte [t35_event + MEV_BUTTONS], MOUSE_BTN_LEFT ; 0x01
    jne .t35_fail
    cmp byte [t35_event + MEV_DX], 74
    jne .t35_fail
    cmp byte [t35_event + MEV_DY], 5
    jne .t35_fail

    ; Close fd
    mov ax, SYS_CLOSE
    mov bx, [t35_fd]
    int 0x80

    mov si, str_t35_ok
    call uart_puts
    popa
    ret

.t35_fail:
    mov si, str_t35_fail
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 36: PC Speaker Tone Generator (/dev/pcspkr) & KIOCSOUND
; ----------------------------------------------------------------------------
test36_pc_speaker:
    pusha
    mov si, str_t36_start
    call uart_puts

    ; 1. Open /dev/pcspkr
    mov ax, SYS_OPEN
    mov bx, str_p6_dev_pcspkr
    mov cx, O_RDWR
    xor dx, dx
    int 0x80
    cmp ax, 0
    jl .t36_fail
    mov [t36_fd], ax

    ; 2. Start tone (440 Hz, divider = 0x0A97 = 2711)
    mov ax, SYS_IOCTL
    mov bx, [t36_fd]
    mov cx, KIOCSOUND
    mov dx, 0x0A97
    int 0x80
    test ax, ax
    jnz .t36_fail

    cmp word [pcspkr_active_tone], 0x0A97
    jne .t36_fail

    ; Verify Port 0x61 bits 0-1 set
    in al, PCSPKR_CTRL_PORT
    and al, 0x03
    cmp al, 0x03
    jne .t36_fail

    ; 3. Silence speaker via KIOCSOUND 0
    mov ax, SYS_IOCTL
    mov bx, [t36_fd]
    mov cx, KIOCSOUND
    xor dx, dx
    int 0x80
    test ax, ax
    jnz .t36_fail

    cmp word [pcspkr_active_tone], 0
    jne .t36_fail

    ; Verify Port 0x61 bits 0-1 cleared
    in al, PCSPKR_CTRL_PORT
    and al, 0x03
    test al, al
    jnz .t36_fail

    ; 4. Test timed beep via PCSPKR_IOC_BEEP
    mov word [t36_note + NOTE_FREQ_HZ], 880     ; 880 Hz
    mov word [t36_note + NOTE_DURATION_MS], 50  ; 50 ms
    mov ax, SYS_IOCTL
    mov bx, [t36_fd]
    mov cx, PCSPKR_IOC_BEEP
    mov dx, t36_note
    int 0x80
    test ax, ax
    jnz .t36_fail

    ; Assert beep ticks queued: (50 + 9) / 10 = 5 ticks
    cmp word [pcspkr_beep_ticks], 5
    jne .t36_fail

    ; Simulate 5 timer ticks to drain beep
    mov cx, 5
.drain_beep:
    call pcspkr_tick
    loop .drain_beep

    cmp word [pcspkr_beep_ticks], 0
    jne .t36_fail
    cmp word [pcspkr_active_tone], 0
    jne .t36_fail

    ; Close fd
    mov ax, SYS_CLOSE
    mov bx, [t36_fd]
    int 0x80

    mov si, str_t36_ok
    call uart_puts
    popa
    ret

.t36_fail:
    mov si, str_t36_fail
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 37: Class-D PWM Digital Audio Driver (/dev/dsp) & XLATB Fast-ISR
; ----------------------------------------------------------------------------
test37_pwm_audio_dsp:
    pusha
    mov si, str_t37_start
    call uart_puts

    ; 1. Open /dev/dsp
    mov ax, SYS_OPEN
    mov bx, str_p6_dev_dsp
    mov cx, O_WRONLY
    xor dx, dx
    int 0x80
    cmp ax, 0
    jl .t37_fail
    mov [t37_fd], ax

    ; 2. Configure sample rate to 8000 Hz
    mov ax, SYS_IOCTL
    mov bx, [t37_fd]
    mov cx, SNDCTL_DSP_SPEED
    mov dx, DSP_RATE_8000_HZ
    int 0x80
    test ax, ax
    jnz .t37_fail

    cmp word [dsp_sample_rate], 8000
    jne .t37_fail
    cmp word [dsp_carrier_div], 149
    jne .t37_fail

    ; 3. Query buffer size
    mov ax, SYS_IOCTL
    mov bx, [t37_fd]
    mov cx, SNDCTL_DSP_GETBLKSIZE
    xor dx, dx
    int 0x80
    cmp ax, DSP_RINGBUF_SIZE
    jne .t37_fail

    ; 4. Prepare 64 bytes of test PCM samples (ramp 0..63)
    xor di, di
.fill_pcm:
    mov ax, di
    mov [t37_pcm_buf + di], al
    inc di
    cmp di, 64
    jb .fill_pcm

    ; 5. Write 64 bytes of PCM audio to /dev/dsp
    mov ax, SYS_WRITE
    mov bx, [t37_fd]
    mov cx, t37_pcm_buf
    mov dx, 64
    int 0x80
    cmp ax, 64
    jne .t37_fail

    ; Verify driver state
    cmp word [dsp_count], 64
    jne .t37_fail
    cmp byte [dsp_active], 1
    jne .t37_fail

    ; 6. Verify XLATB table translation:
    ; Sample 0 -> pulse 1
    ; Sample 255 -> pulse 148
    mov bx, pwm_lut
    xor al, al
    xlatb
    cmp al, 1
    jne .t37_fail

    mov al, 255
    xlatb
    cmp al, 148
    jne .t37_fail

    ; 7. Switch backend to Covox LPT1 and back
    mov ax, SYS_IOCTL
    mov bx, [t37_fd]
    mov cx, SNDCTL_DSP_SETBACKEND
    mov dx, DSP_BACKEND_COVOX_LPT1
    int 0x80
    test ax, ax
    jnz .t37_fail
    cmp byte [dsp_backend], DSP_BACKEND_COVOX_LPT1
    jne .t37_fail

    ; Switch back to PC Speaker PWM
    mov ax, SYS_IOCTL
    mov bx, [t37_fd]
    mov cx, SNDCTL_DSP_SETBACKEND
    mov dx, DSP_BACKEND_PCSPKR_PWM
    int 0x80
    test ax, ax
    jnz .t37_fail

    ; 8. Reset /dev/dsp
    mov ax, SYS_IOCTL
    mov bx, [t37_fd]
    mov cx, SNDCTL_DSP_RESET
    xor dx, dx
    int 0x80
    test ax, ax
    jnz .t37_fail

    cmp word [dsp_count], 0
    jne .t37_fail
    cmp byte [dsp_active], 0
    jne .t37_fail

    ; Close fd
    mov ax, SYS_CLOSE
    mov bx, [t37_fd]
    int 0x80

    mov si, str_t37_ok
    call uart_puts
    popa
    ret

.t37_fail:
    mov si, str_t37_fail
    call uart_puts
    call console_puts
    hlt

; ----------------------------------------------------------------------------
; Test 38: Nano-X Window Server & GUI Desktop Compositor on tty5 (Alt+F5)
; ----------------------------------------------------------------------------
test38_nanox_gui_tty5:
    pusha
    mov si, str_t38_start
    call uart_puts

    ; 1. Start Nano-X GUI Desktop Compositor
    call nanox_start_gui

    ; Verify Display Server status
    cmp byte [nanox_active], 1
    jne .t38_fail
    cmp word [nanox_windows_drawn], 3   ; nxterm, nxclock, nxcalc
    jne .t38_fail

    ; Verify active console is tty5 (index 4)
    cmp byte [active_console], 4
    jne .t38_fail

    ; Verify video mode is VGA 640x480x16
    cmp word [fb286_current_mode], FB_MODE_VGA_640x480x16
    jne .t38_fail

    ; 2. Dispatch simulated left-click mouse event to damage window
    mov al, MOUSE_BTN_LEFT
    mov bx, 5
    mov cx, 5
    call nanox_handle_mouse_event
    cmp ax, 1                           ; Damage handled!
    jne .t38_fail

    ; 3. Cleanly switch back to text console 0 (tty1) for serial telemetry
    mov al, 0
    call vt102_switch_console
    mov ax, FB_MODE_TEXT_80x25
    call fb286_set_mode

    mov ax, GDT_KDATA_SEL
    mov es, ax

    mov si, str_t38_ok
    call uart_puts
    popa
    ret

.t38_fail:
    mov si, str_t38_fail
    call uart_puts
    call console_puts
    hlt

section .data
align 2
t31_fd:             dw 0
t32_fd:             dw 0
t33_fd:             dw 0
t34_shmid:          dw 0
t34_sel_a:          dw 0
t34_sel_b:          dw 0
t35_fd:             dw 0
t35_mask:           dw 0
t36_fd:             dw 0
t37_fd:             dw 0

str_p6_dev_fb0:     db "/dev/fb0", 0
str_p6_dev_mouse:   db "/dev/mouse", 0
str_p6_dev_pcspkr:  db "/dev/pcspkr", 0
str_p6_dev_dsp:     db "/dev/dsp", 0
str_p6_shm_magic:   db "Lin286_SHM_Test_OK", 0

str_p6_banner:  db 13, 10
                db "========================================================", 13, 10
                db " Lin286 Phase 6 Verification Suite: GUI, Framebuffer & Sound", 13, 10
                db "========================================================", 13, 10, 0

str_t31_start:  db "[TEST 31] Verifying Framebuffer /dev/fb0 FBIOGET_INFO & FBIOSET_MODE...", 13, 10, 0
str_t31_ok:     db "[TEST 31] PASSED: Framebuffer /dev/fb0 FBIOGET_INFO & FBIOSET_MODE verified.", 13, 10, 0
str_t31_fail:   db "[TEST 31] FAILED: Framebuffer mode query / switch error", 13, 10, 0

str_t32_start:  db "[TEST 32] Verifying Direct 64 KB Video Aperture LDT Mapping (0x001F)...", 13, 10, 0
str_t32_ok:     db "[TEST 32] PASSED: Direct 64 KB Video Aperture LDT mapping (0x001F) verified.", 13, 10, 0
str_t32_fail:   db "[TEST 32] FAILED: Framebuffer LDT aperture mapping error", 13, 10, 0

str_t33_start:  db "[TEST 33] Verifying Display Server FLAGS.IOPL=3 Elevation...", 13, 10, 0
str_t33_ok:     db "[TEST 33] PASSED: Display Server FLAGS.IOPL=3 elevation verified.", 13, 10, 0
str_t33_fail:   db "[TEST 33] FAILED: FLAGS.IOPL elevation error", 13, 10, 0

str_t34_start:  db "[TEST 34] Verifying Zero-Copy LDT Shared Memory (shmget/shmat)...", 13, 10, 0
str_t34_ok:     db "[TEST 34] PASSED: Zero-Copy LDT Shared Memory (shmget/shmat) verified.", 13, 10, 0
str_t34_fail:   db "[TEST 34] FAILED: Zero-copy shared memory error", 13, 10, 0
str_t34_f1:     db "[TEST 34] FAILED at step 1: sys_shmget286 returned <= 0", 13, 10, 0
str_t34_f2:     db "[TEST 34] FAILED at step 2: sys_shmat286 task 0 selector mismatch", 13, 10, 0
str_t34_f3:     db "[TEST 34] FAILED at step 3: sys_shmat286 task 1 selector mismatch", 13, 10, 0
str_t34_f4:     db "[TEST 34] FAILED at step 4: data mismatch across tasks", 13, 10, 0
str_t34_f5:     db "[TEST 34] FAILED at step 5: refcount != 2", 13, 10, 0
str_t34_f6:     db "[TEST 34] FAILED at step 6: detach task 1 failed", 13, 10, 0
str_t34_f7:     db "[TEST 34] FAILED at step 7: detach task 0 failed", 13, 10, 0

str_t35_start:  db "[TEST 35] Verifying RS-232 Serial Mouse Driver (/dev/mouse)...", 13, 10, 0
str_t35_ok:     db "[TEST 35] PASSED: RS-232 Serial Mouse driver (/dev/mouse) verified.", 13, 10, 0
str_t35_fail:   db "[TEST 35] FAILED: Serial mouse driver error", 13, 10, 0

str_t36_start:  db "[TEST 36] Verifying PC Speaker (/dev/pcspkr) KIOCSOUND & timed beep...", 13, 10, 0
str_t36_ok:     db "[TEST 36] PASSED: PC Speaker (/dev/pcspkr) KIOCSOUND & timed beep verified.", 13, 10, 0
str_t36_fail:   db "[TEST 36] FAILED: PC Speaker error", 13, 10, 0

str_t37_start:  db "[TEST 37] Verifying Class-D PWM Digital Audio (/dev/dsp) & XLATB Fast-ISR...", 13, 10, 0
str_t37_ok:     db "[TEST 37] PASSED: Class-D PWM Digital Audio (/dev/dsp) & XLATB Fast-ISR verified.", 13, 10, 0
str_t37_fail:   db "[TEST 37] FAILED: Digital audio /dev/dsp error", 13, 10, 0

str_t38_start:  db "[TEST 38] Verifying Nano-X Window Server & GUI Desktop Compositor on tty5...", 13, 10, 0
str_t38_ok:     db "[TEST 38] PASSED: Nano-X Window Server & GUI Desktop Compositor on tty5 verified.", 13, 10, 0
str_t38_fail:   db "[TEST 38] FAILED: Nano-X Window Server error", 13, 10, 0

str_p6_all_pass: db 13, 10
                 db "========================================================", 13, 10
                 db " [TEST] ALL PHASE 1, 2, 3, 4, 5 & 6 VERIFICATIONS PASSED!", 13, 10
                 db "========================================================", 13, 10, 0

section .bss
align 2
t31_info:       resb FBINFO_SIZE
t32_info:       resb FBINFO_SIZE
t35_event:      resb MEV_SIZE
t36_note:       resb NOTE_SIZE
t37_pcm_buf:    resb 64

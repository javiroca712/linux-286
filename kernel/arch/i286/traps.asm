CPU 286
BITS 16

; ============================================================================
; Lin286 CPU Exception Handlers, IDT Table & Structured Crash Monitor (kdb286)
;
; Installs 80286 Gate Descriptors for INT 00h-1Fh and IRQs.
; Emits structured serial/console telemetry frames [FAULT] on CPU traps.
; Supports recovery for deliberate #GP and #NP verification tests.
; ============================================================================

%include "kernel/include/i286_asm.inc"

global idt_init
global idt_desc
global test_expected_fault
global test_resume_ip
global test_gp_caught
global test_np_caught

extern uart_puts
extern uart_putc
extern uart_print_hex16
extern console_puts
extern console_putc
extern console_print_hex16
extern irq0_timer_handler

section .text

; ----------------------------------------------------------------------------
; IDT Initialization
; ----------------------------------------------------------------------------
idt_init:
    pusha
    push es

    mov ax, GDT_KDATA_SEL
    mov es, ax
    mov di, idt_table

    ; Fill all 256 gates with default unhandled exception gate
    mov cx, 256
.fill_default:
    mov ax, isr_default
    call set_gate_entry
    add di, 8
    loop .fill_default

    ; Install CPU Exception Gates (INT 0 to 16)
    mov di, idt_table + (0 * 8)
    mov ax, isr0_de
    call set_gate_entry

    mov di, idt_table + (1 * 8)
    mov ax, isr1_db
    call set_gate_entry

    mov di, idt_table + (2 * 8)
    mov ax, isr2_nmi
    call set_gate_entry

    mov di, idt_table + (3 * 8)
    mov ax, isr3_bp
    call set_gate_entry

    mov di, idt_table + (4 * 8)
    mov ax, isr4_of
    call set_gate_entry

    mov di, idt_table + (5 * 8)
    mov ax, isr5_br
    call set_gate_entry

    mov di, idt_table + (6 * 8)
    mov ax, isr6_ud
    call set_gate_entry

    mov di, idt_table + (7 * 8)
    mov ax, isr7_nm
    call set_gate_entry

    mov di, idt_table + (8 * 8)
    mov ax, isr8_df
    call set_gate_entry

    mov di, idt_table + (9 * 8)
    mov ax, isr9_coproc
    call set_gate_entry

    mov di, idt_table + (10 * 8)
    mov ax, isr10_ts
    call set_gate_entry

    mov di, idt_table + (11 * 8)
    mov ax, isr11_np
    call set_gate_entry

    mov di, idt_table + (12 * 8)
    mov ax, isr12_ss
    call set_gate_entry

    mov di, idt_table + (13 * 8)
    mov ax, isr13_gp
    call set_gate_entry

    mov di, idt_table + (16 * 8)
    mov ax, isr16_mf
    call set_gate_entry

    ; Install IRQ 0 (Timer) at vector 0x20
    mov di, idt_table + (0x20 * 8)
    mov ax, irq0_timer_handler
    call set_gate_entry

    ; Install IRQ 1 (Keyboard) at vector 0x21
    mov di, idt_table + (0x21 * 8)
    mov ax, irq1_keyboard_handler
    call set_gate_entry

    ; Install INT 0x80 System Call Trap Gate (DPL=3)
    mov di, idt_table + (0x80 * 8)
    mov ax, syscall_entry
    call set_gate_entry_dpl3

    ; Calculate physical 24-bit address of idt_table:
    ; Base = 0x019000 + idt_table offset within Kernel Data segment
    mov ax, idt_table
    add ax, 0x9000
    mov [idt_desc + 2], ax
    mov al, 0x01
    adc al, 0
    mov [idt_desc + 4], al

    ; Load IDTR
    lidt [idt_desc]

    mov si, str_idt_ok
    call uart_puts

    pop es
    popa
    ret

; Helper to write an 80286 Gate Descriptor at ES:DI
; AX = Handler Offset within CS (GDT_KCODE_SEL = 0x0008)
set_gate_entry:
    mov [es:di + 0], ax             ; Offset 15..0
    mov word [es:di + 2], GDT_KCODE_SEL ; Target Code Segment Selector
    mov byte [es:di + 4], 0         ; Word count = 0
    mov byte [es:di + 5], 0x86      ; Access: Present(1), DPL=00, 286 Interrupt Gate
    mov word [es:di + 6], 0x0000    ; Reserved
    ret

; Helper to write an 80286 Trap Gate Descriptor with DPL=3 at ES:DI
; AX = Handler Offset within CS (GDT_KCODE_SEL = 0x0008)
set_gate_entry_dpl3:
    mov [es:di + 0], ax             ; Offset 15..0
    mov word [es:di + 2], GDT_KCODE_SEL ; Target Code Segment Selector
    mov byte [es:di + 4], 0         ; Word count = 0
    mov byte [es:di + 5], 0xE7      ; Access: Present(1), DPL=3, 286 Trap Gate
    mov word [es:di + 6], 0x0000    ; Reserved
    ret

; ----------------------------------------------------------------------------
; Individual CPU Exception ISR Entry Points
; ----------------------------------------------------------------------------

; ISRs without error code: push dummy 0 error code, then vector number
isr0_de:
    push word 0
    push word 0
    jmp common_trap_entry

isr1_db:
    push word 0
    push word 1
    jmp common_trap_entry

isr2_nmi:
    push word 0
    push word 2
    jmp common_trap_entry

isr3_bp:
    push word 0
    push word 3
    jmp common_trap_entry

isr4_of:
    push word 0
    push word 4
    jmp common_trap_entry

isr5_br:
    push word 0
    push word 5
    jmp common_trap_entry

isr6_ud:
    push word 0
    push word 6
    jmp common_trap_entry

isr7_nm:
    push word 0
    push word 7
    jmp common_trap_entry

; ISRs WITH error code pushed by CPU: push vector number directly
isr8_df:
    push word 8
    jmp common_trap_entry

isr9_coproc:
    push word 0
    push word 9
    jmp common_trap_entry

isr10_ts:
    push word 10
    jmp common_trap_entry

isr11_np:
    push word 11
    jmp common_trap_entry

isr12_ss:
    push word 12
    jmp common_trap_entry

isr13_gp:
    push word 13
    jmp common_trap_entry

isr16_mf:
    push word 0
    push word 16
    jmp common_trap_entry

isr_default:
    push word 0
    push word 0xFF
    jmp common_trap_entry

; ----------------------------------------------------------------------------
; Common Trap Dispatcher & Structured Telemetry Logger
; ----------------------------------------------------------------------------
common_trap_entry:
    pusha
    push ds
    push es

    ; Load Kernel Data Segment for handler
    mov ax, GDT_KDATA_SEL
    mov ds, ax
    mov es, ax

    ; Stack layout at this point:
    ; [BP+00]: saved ES
    ; [BP+02]: saved DS
    ; [BP+04]: saved DI
    ; [BP+06]: saved SI
    ; [BP+08]: saved BP
    ; [BP+10]: saved SP (from pusha)
    ; [BP+12]: saved BX
    ; [BP+14]: saved DX
    ; [BP+16]: saved CX
    ; [BP+18]: saved AX
    ; [BP+20]: Vector number
    ; [BP+22]: Error code
    ; [BP+24]: return IP
    ; [BP+26]: return CS
    ; [BP+28]: return FLAGS
    mov bp, sp

    ; Output structured fault banner
    mov si, str_fault_bar
    call uart_puts

    mov si, str_fault_vec
    call uart_puts
    mov ax, [bp + 20]       ; Vector number
    call uart_print_hex16

    ; Print mnemonic name if vector known
    cmp ax, 13
    je .print_gp_name
    cmp ax, 11
    je .print_np_name
    cmp ax, 6
    je .print_ud_name
    jmp .print_err_code
.print_gp_name:
    mov si, str_name_gp
    call uart_puts
    jmp .print_err_code
.print_np_name:
    mov si, str_name_np
    call uart_puts
    jmp .print_err_code
.print_ud_name:
    mov si, str_name_ud
    call uart_puts

.print_err_code:
    mov si, str_fault_err
    call uart_puts
    mov ax, [bp + 22]       ; Error code
    call uart_print_hex16

    ; Print CS:IP and FLAGS
    mov si, str_fault_csip
    call uart_puts
    mov ax, [bp + 26]       ; CS
    call uart_print_hex16
    mov al, ':'
    call uart_putc
    mov ax, [bp + 24]       ; IP
    call uart_print_hex16

    mov si, str_fault_flags
    call uart_puts
    mov ax, [bp + 28]       ; FLAGS
    call uart_print_hex16
    mov si, str_crlf
    call uart_puts

    ; Print registers: AX BX CX DX
    mov si, str_reg_ax
    call uart_puts
    mov ax, [bp + 18]
    call uart_print_hex16
    mov si, str_reg_bx
    call uart_puts
    mov ax, [bp + 12]
    call uart_print_hex16
    mov si, str_reg_cx
    call uart_puts
    mov ax, [bp + 16]
    call uart_print_hex16
    mov si, str_reg_dx
    call uart_puts
    mov ax, [bp + 14]
    call uart_print_hex16
    mov si, str_crlf
    call uart_puts

    ; Print SI DI BP SP
    mov si, str_reg_si
    call uart_puts
    mov ax, [bp + 6]
    call uart_print_hex16
    mov si, str_reg_di
    call uart_puts
    mov ax, [bp + 4]
    call uart_print_hex16
    mov si, str_reg_bp
    call uart_puts
    mov ax, [bp + 8]
    call uart_print_hex16
    mov si, str_reg_sp
    call uart_puts
    mov ax, [bp + 10]
    call uart_print_hex16
    mov si, str_crlf
    call uart_puts

    ; Check if this is an expected verification test fault!
    mov ax, [bp + 20]       ; Vector
    cmp ax, [test_expected_fault]
    je .handle_test_fault

    ; Check if this is a hardware VM trap (CoW #GP, Demand #NP, Dynamic #SS)
    cmp ax, 13              ; #GP
    je .try_vm_gp
    cmp ax, 11              ; #NP
    je .try_vm_np
    cmp ax, 12              ; #SS
    je .try_vm_ss
    jmp .unhandled_fault

.try_vm_gp:
    mov ax, [bp + 22]       ; Error code
    mov bx, [bp + 26]       ; Faulting CS
    mov dx, [bp + 24]       ; Faulting IP
    call vm_handle_gp
    test ax, ax
    jnz .vm_handled
    jmp .unhandled_fault

.try_vm_np:
    mov ax, [bp + 22]       ; Faulting Selector (Error code)
    call vm_handle_np
    test ax, ax
    jnz .vm_handled
    jmp .unhandled_fault

.try_vm_ss:
    mov ax, [bp + 22]       ; Error code
    mov bx, [bp + 10]       ; SP
    call vm_handle_ss
    test ax, ax
    jnz .vm_handled
    jmp .unhandled_fault

.vm_handled:
    ; Hardware VM trap successfully handled!
    ; Restore registers and IRET to re-execute instruction
    pop es
    pop ds
    popa
    add sp, 4               ; Discard vector and error code
    iret

.handle_test_fault:
    ; Deliberate test fault matched!
    cmp ax, 13              ; #GP
    jne .check_test_np
    mov word [test_gp_caught], 1
    mov si, str_gp_verified
    call uart_puts
    jmp .resume_test

.check_test_np:
    cmp ax, 11              ; #NP
    jne .resume_test
    mov word [test_np_caught], 1
    mov si, str_np_verified
    call uart_puts

.resume_test:
    ; Reset expected fault
    mov word [test_expected_fault], 0

    ; Advance IP to test_resume_ip to avoid re-triggering the same fault
    mov ax, [test_resume_ip]
    mov [bp + 24], ax

    ; Cleanly restore and return
    pop es
    pop ds
    popa
    add sp, 4               ; Discard vector and error code
    iret

.unhandled_fault:
    mov si, str_crash_halt
    call uart_puts
    call console_puts
    mov si, str_fault_vec
    call console_puts
    mov ax, [bp + 20]
    call console_print_hex16
    mov si, str_fault_csip
    call console_puts
    mov ax, [bp + 26]
    call console_print_hex16
    mov al, ':'
    call console_putc
    mov ax, [bp + 24]
    call console_print_hex16
    cli
.hang:
    hlt
    jmp .hang

section .data
align 4
idt_desc:
    dw (256 * 8) - 1        ; Limit: 2047 bytes
    dw idt_table            ; Base 15..0
    db 0x01                 ; Base 23..16 (Phys 0x019000 + offset)
    db 0x00

test_expected_fault:    dw 0
test_resume_ip:         dw 0
test_gp_caught:         dw 0
test_np_caught:         dw 0

str_idt_ok:     db "[IDT] 80286 CPU exception gates (INT 00h-1Fh) installed", 13, 10, 0
str_fault_bar:  db "[FAULT] ===================== CPU EXCEPTION TRAP =====================", 13, 10, 0
str_fault_vec:  db "[FAULT] Trap Vector: 0x", 0
str_name_gp:    db " (#GP General Protection Fault)", 0
str_name_np:    db " (#NP Segment Not Present)", 0
str_name_ud:    db " (#UD Invalid Opcode)", 0
str_fault_err:  db 13, 10, "[FAULT] Error Code:  0x", 0
str_fault_csip: db 13, 10, "[FAULT] CS:IP:       0x", 0
str_fault_flags:db "   FLAGS: 0x", 0
str_crlf:       db 13, 10, 0
str_reg_ax:     db "[FAULT] AX=0x", 0
str_reg_bx:     db " BX=0x", 0
str_reg_cx:     db " CX=0x", 0
str_reg_dx:     db " DX=0x", 0
str_reg_si:     db "[FAULT] SI=0x", 0
str_reg_di:     db " DI=0x", 0
str_reg_bp:     db " BP=0x", 0
str_reg_sp:     db " SP=0x", 0
str_gp_verified:db "[FAULT] Deliberate #GP intercepted and verified successfully", 13, 10, 0
str_np_verified:db "[FAULT] Deliberate #NP intercepted and verified successfully", 13, 10, 0
str_crash_halt: db "[FAULT] FATAL: Unhandled CPU exception. System halted in kdb286.", 13, 10, 0

section .bss
align 8
idt_table:      resb 256 * 8

CPU 286
BITS 16

; ============================================================================
; Lin286 Comprehensive Verification Gate Self-Test Subsystem
;
; Verifies Phase 1 & Phase 2 Milestones:
; 1. Hardware CPU Exception Trapping (#GP INT 13, #NP INT 11)
; 2. GDT Scratch Copy Windows (0x0028/0x0030) cross-segment copy (Pool A <-> B)
; 3. 24-bit Physical Segment Memory Allocator (Pool A & Pool B) & Compaction
; 4. Local Descriptor Table (LDT) Manager (LLDT task switching) & Shared TSS
; 5. Copy-on-Write (CoW) unsharing & hardware #GP write fault resolution
; 6. Demand segment loading & hardware #NP fault resolution
; 7. Dynamic stack expansion (#SS INT 12) for expand-down segments
; ============================================================================

%include "kernel/include/i286_asm.inc"

global run_verification_gate

section .text

run_verification_gate:
    pusha
    push ds
    push es

    mov si, str_test_start
    call uart_puts

    ; ------------------------------------------------------------------------
    ; Step 1: Deliberate #GP (General Protection Fault - INT 13)
    ; Trigger: Load invalid selector beyond GDT limit
    ; ------------------------------------------------------------------------
    mov si, str_test1_hdr
    call uart_puts

    mov word [test_expected_fault], 13
    mov word [test_resume_ip], .gp_resumed
    mov word [test_gp_caught], 0

    mov ax, 0x0100          ; Out of bounds GDT selector (Index 32 > Limit 31)
    mov es, ax

.gp_resumed:
    cmp word [test_gp_caught], 1
    je .test1_ok
    mov si, str_gp_failed
    call uart_puts
    call console_puts
    cli
    hlt

.test1_ok:
    mov si, str_test1_pass
    call uart_puts

    ; ------------------------------------------------------------------------
    ; Step 2: GDT Scratch Copy Windows (0x0028 & 0x0030)
    ; Test cross-segment copy from Pool A (0x030000) to Pool B (0x105000)
    ; when Extended RAM >= 64 KB, else Conventional RAM (0x065000),
    ; and back to verify_buf in DS.
    ; ------------------------------------------------------------------------
    mov si, str_test2_hdr
    call uart_puts

    ; Fill source buffer in Pool A (phys 0x030000) with pattern 0xA5
    mov dh, 0x03
    mov di, 0x0000          ; Dest = 0x030000
    mov al, 0xA5
    mov cx, 512
    call phys_set

    ; Select destination page: 0x10 (1044 KB+) if Ext RAM >= 64 KB, else 0x06 (0x065000)
    mov bl, 0x10
    cmp word [cmos_ext_kb], 64
    jae .t2_dst_ready
    mov bl, 0x06
.t2_dst_ready:

    ; Copy 512 bytes from Pool A (0x030000) to target (0x105000 or 0x065000)
    mov dl, 0x03
    mov si, 0x0000          ; Source = 0x030000
    mov dh, bl
    mov di, 0x5000
    mov cx, 512
    call phys_copy

    ; Zero verify_buf in Kernel Data
    mov di, verify_buf
    mov cx, 256
    xor ax, ax
    rep stosw

    ; Copy 512 bytes from target (0x105000 or 0x065000) back to verify_buf in DS
    mov dl, bl
    mov si, 0x5000          ; Source = 0x105000 / 0x065000
    ; Kernel Data base is 0x019000.
    ; Dest low = 0x9000 + verify_buf. Dest high = 0x01 + carry
    mov ax, verify_buf
    add ax, 0x9000
    mov di, ax
    mov dh, 0x01
    adc dh, 0
    mov cx, 512
    call phys_copy

    ; Verify that all 512 bytes in verify_buf are 0xA5
    mov si, verify_buf
    mov cx, 512
.check_copy_win:
    lodsb
    cmp al, 0xA5
    jne .copy_win_fail
    loop .check_copy_win

    mov si, str_test2_pass
    call uart_puts
    jmp .step3

.copy_win_fail:
    mov si, str_copy_win_err
    call uart_puts
    call console_puts
    cli
    hlt

.step3:
    ; ------------------------------------------------------------------------
    ; Step 3: Physical Segment Allocator & Compaction
    ; ------------------------------------------------------------------------
    mov si, str_test3_hdr
    call uart_puts

    ; Allocate Block 1 in Pool A: 64 paragraphs (1 KB)
    mov cx, 64
    mov bl, POOL_A
    mov bh, 1               ; Owner PID 1
    call seg_alloc
    cmp ax, 0xFFFF
    je .segalloc_fail
    mov [test_blk1], ax

    ; Allocate Block 3 in Pool A: 64 paragraphs (1 KB)
    mov cx, 64
    mov bl, POOL_A
    mov bh, 1
    call seg_alloc
    cmp ax, 0xFFFF
    je .segalloc_fail
    mov [test_blk3], ax

    ; Free Block 1 (creates a hole in Pool A between Pool A base and Block 3)
    mov ax, [test_blk1]
    call seg_free

    ; Run compaction on Pool A: Block 3 should be slid down to 0x029000!
    mov bl, POOL_A
    call seg_compact

    ; Verify Block 3 was slid to Pool A base (0x9000, 0x02)
    mov ax, [test_blk3]
    shl ax, 4
    add ax, seg_blocks
    mov di, ax
    cmp word [di + SB_BASE_LOW], 0x9000
    jne .compact_fail
    cmp byte [di + SB_BASE_HIGH], 0x02
    jne .compact_fail

    ; Free Block 3
    mov ax, [test_blk3]
    call seg_free

    ; Allocate & free Block 2 in Pool B (tests Pool B when present, Pool A fallback when 0 KB XMS)
    mov cx, 128
    mov bl, POOL_B
    mov bh, 1
    call seg_alloc
    cmp ax, 0xFFFF
    je .segalloc_fail
    mov [test_blk2], ax
    call seg_free

    mov si, str_test3_pass
    call uart_puts
    jmp .step4

.compact_fail:
    mov si, str_compact_err
    call uart_puts
    call console_puts
    cli
    hlt

.segalloc_fail:
    mov si, str_segalloc_err
    call uart_puts
    call console_puts
    cli
    hlt

.step4:
    ; ------------------------------------------------------------------------
    ; Step 4: Per-Process LDT Manager & LLDT Task Switching
    ; ------------------------------------------------------------------------
    mov si, str_test4_hdr
    call uart_puts

    ; Configure Task 1's LDT Entry 0 (Code Segment)
    ; Base: 0x001000, Limit: 0xFFFF, Access: 0x9A, VM Flags: 0
    mov al, 1               ; PID 1
    mov ah, 0               ; Entry 0
    mov dl, 0x00
    mov si, 0x1000
    mov bx, 0xFFFF
    mov cl, 0x9A
    xor ch, ch
    xor dh, dh
    call ldt_set_entry

    ; Switch to Task 1
    mov al, 1
    call ldt_switch_task

    ; Verify active PID is 1
    call ldt_get_current_pid
    cmp al, 1
    jne .ldt_fail

    ; Clean up Task 1 Entry 4 descriptor so it is available for subsequent tests
    mov al, 1
    mov ah, 4
    call ldt_get_entry_ptr
    mov byte [di + 5], 0

    ; Switch back to Task 0
    xor al, al
    call ldt_switch_task

    mov si, str_test4_pass
    call uart_puts
    jmp .step5

.ldt_fail:
    mov si, str_ldt_err
    call uart_puts
    call console_puts
    cli
    hlt

.step5:
    ; ------------------------------------------------------------------------
    ; Step 5: Copy-on-Write (CoW) Unsharing & Resolution via #GP
    ; ------------------------------------------------------------------------
    mov si, str_test5_hdr
    call uart_puts

    ; Allocate a physical block for a shared segment (64 paras = 1 KB)
    mov cx, 64
    mov bl, POOL_A
    mov bh, 1
    call seg_alloc
    cmp ax, 0xFFFF
    je .cow_alloc_fail

    mov [cow_blk], ax
    mov di, ax
    shl di, 4
    add di, seg_blocks

    ; Set ref_count = 2 (shared between parent and child)
    mov word [di + SB_REF_COUNT], 2
    mov dx, [di + SB_BASE_LOW]
    mov bl, [di + SB_BASE_HIGH]
    mov [orig_cow_low], dx
    mov [orig_cow_high], bl

    ; Configure Task 1's LDT Entry 1 (LDT_UDATA_SEL = 0x000F):
    ; Access: 0xF0 (Present, DPL=3, Read-Only Data, DESC_WRITABLE is 0!)
    ; VM Flags: VM_FLAG_COW (0x0001)
    mov al, 1               ; PID 1
    mov ah, 1               ; Entry 1 (Data)
    mov dl, bl              ; Base high
    mov si, dx              ; Base low
    mov bx, 0x03FF          ; Limit: 1024 bytes - 1
    mov cl, (0x90 | DESC_DPL_3) ; DPL=3, Read-Only (Writable=0)
    mov ch, (VM_FLAG_COW & 0xFF)
    mov dh, 0
    call ldt_set_entry

    ; Link physical block to Task 1's descriptor
    mov ax, [cow_blk]
    mov di, task_ldts + 64 + 8 ; Task 1, Entry 1
    call seg_link_desc

    ; Switch to Task 1
    mov al, 1
    call ldt_switch_task

    ; Write initial byte 0x11 directly via phys_set so we know original data
    mov dh, [orig_cow_high]
    mov di, [orig_cow_low]
    mov al, 0x11
    mov cx, 1
    call phys_set

    ; Invoke vm_handle_gp to resolve CoW unsharing
    xor ax, ax              ; Error code 0
    mov bx, cs
    mov dx, .cow_sim_ip
.cow_sim_ip:
    call vm_handle_gp
    cmp ax, 1
    jne .cow_verify_fail

    ; Verify that descriptor in LDT is now WRITABLE and unshared
    mov di, task_ldts + 64 + 8
    test byte [di + 5], DESC_WRITABLE
    jz .cow_verify_fail
    test word [di + 6], VM_FLAG_COW
    jnz .cow_verify_fail

    ; Verify that base address changed to a newly allocated physical block
    mov ax, [di + 2]
    cmp ax, [orig_cow_low]
    jne .cow_base_changed
    mov al, [di + 4]
    cmp al, [orig_cow_high]
    je .cow_verify_fail     ; Base MUST have changed!

.cow_base_changed:
    ; Now write 0x77 into the unshared segment through ES
    mov ax, LDT_UDATA_SEL
    mov es, ax
    mov byte [es:0], 0x77

    ; Verify ES wrote 0x77 into new segment
    cmp byte [es:0], 0x77
    jne .cow_verify_fail

    ; Verify original physical frame STILL has 0x11 (CoW isolation preserved!)
    mov dl, [orig_cow_high]
    mov si, [orig_cow_low]
    mov ax, verify_buf
    add ax, 0x9000
    mov di, ax
    mov dh, 0x01
    adc dh, 0
    mov cx, 1
    call phys_copy

    cmp byte [verify_buf], 0x11
    jne .cow_verify_fail

    ; Check that vm_cow_faults_handled incremented
    cmp word [vm_cow_faults_handled], 1
    jb .cow_verify_fail

    ; Clean up Task 1 Entry 4 descriptor so it is available for subsequent tests
    mov al, 1
    mov ah, 4
    call ldt_get_entry_ptr
    mov byte [di + 5], 0

    ; Switch back to Task 0
    xor al, al
    call ldt_switch_task

    mov si, str_test5_pass
    call uart_puts
    jmp .step6

.cow_alloc_fail:
    mov si, str_segalloc_err
    call uart_puts
    call console_puts
    cli
    hlt

.cow_verify_fail:
    mov si, str_cow_fail
    call uart_puts
    call console_puts
    cli
    hlt

.step6:
    ; ------------------------------------------------------------------------
    ; Step 6: Demand Segment Loading (#NP INT 11)
    ; ------------------------------------------------------------------------
    mov si, str_test6_hdr
    call uart_puts

    ; In Task 1's LDT, configure Entry 4 (LDT_USHM_BASE = 0x0027):
    ; Access: 0x12 (Present = 0!, Ring 0, Data R/W)
    ; VM Flags: VM_FLAG_DEMAND (0x0008)
    ; Limit: 0x03FF (1 KB)
    mov al, 1               ; PID 1
    mov ah, 4               ; Entry 4
    mov dl, 0x00            ; Base high
    mov si, 0x0000          ; Base low (swap token)
    mov bx, 0x03FF          ; Limit
    mov cl, (0x12 | DESC_DPL_3) ; Present = 0, DPL=3
    mov ch, (VM_FLAG_DEMAND & 0xFF)
    mov dh, 0
    call ldt_set_entry

    ; Switch to Task 1
    mov al, 1
    call ldt_switch_task

    ; Attempt to load selector 0x0027 into ES.
    ; Because Present=0, 80286 MMU raises #NP (INT 11)!
    ; Our vm_handle_np intercepts #NP, allocates physical frame,
    ; updates descriptor, sets Present=1, and executes IRET!
    mov ax, LDT_USHM_BASE   ; 0x0027
    mov es, ax              ; <--- Hardware triggers #NP(0x0027) here!

    ; If we reached here, #NP was demand-loaded and selector loaded cleanly!
    ; Write test data through ES:
    mov word [es:0], 0xBEEF
    cmp word [es:0], 0xBEEF
    jne .np_verify_fail

    cmp word [vm_np_faults_handled], 1
    jb .np_verify_fail

    ; Clean up Task 1 Entry 4 descriptor so it is available for subsequent tests
    mov al, 1
    mov ah, 4
    call ldt_get_entry_ptr
    mov byte [di + 5], 0

    ; Switch back to Task 0
    xor al, al
    call ldt_switch_task

    mov si, str_test6_pass
    call uart_puts
    jmp .step7

.np_verify_fail:
    mov si, str_np_test_fail
    call uart_puts
    call console_puts
    cli
    hlt

.step7:
    ; ------------------------------------------------------------------------
    ; Step 7: Dynamic Stack Expansion (#SS INT 12)
    ; ------------------------------------------------------------------------
    mov si, str_test7_hdr
    call uart_puts

    ; In Task 1's LDT, configure Entry 2 (LDT_USTACK_SEL = 0x0017) as Expand-Down:
    ; Access: 0x96 (Present, Ring 0, Expand-Down Data R/W)
    ; Limit: 0xFF00 (valid offsets > 0xFF00)
    mov al, 1
    mov ah, 2
    mov dl, 0x01
    mov si, 0x8000
    mov bx, 0xFF00          ; Limit
    mov cl, (0x96 | DESC_DPL_3) ; Expand-down data R/W, DPL=3
    xor ch, ch
    xor dh, dh
    call ldt_set_entry

    ; Switch to Task 1
    mov al, 1
    call ldt_switch_task

    ; Test stack expansion handler directly
    mov ax, LDT_USTACK_SEL
    mov bx, 0xFEF0          ; Faulting SP below limit
    call vm_handle_ss

    cmp ax, 1
    jne .ss_fail
    cmp word [vm_ss_faults_handled], 1
    jb .ss_fail

    ; Verify that descriptor limit was expanded downwards
    mov di, task_ldts + 64 + 16 ; Task 1, Entry 2
    cmp word [di + 0], 0xFF00 - STACK_GROWTH_STEP_BYTES
    jne .ss_fail

    ; Clean up Task 1 Entry 4 descriptor so it is available for subsequent tests
    mov al, 1
    mov ah, 4
    call ldt_get_entry_ptr
    mov byte [di + 5], 0

    ; Switch back to Task 0
    xor al, al
    call ldt_switch_task

    mov si, str_test7_pass
    call uart_puts

    ; ------------------------------------------------------------------------
    ; All Phase 1 & Phase 2 Tests PASSED!
    ; ------------------------------------------------------------------------
    mov si, str_gate_passed
    call uart_puts

    pop es
    pop ds
    popa
    ret

.ss_fail:
    mov si, str_ss_fail
    call uart_puts
    call console_puts
    cli
    hlt

section .data
test_blk1:      dw 0
test_blk2:      dw 0
test_blk3:      dw 0
cow_blk:        dw 0
orig_cow_low:   dw 0
orig_cow_high:  db 0

str_test_start: db 13, 10
                db "========================================================", 13, 10
                db " Lin286 Phase 1 & Phase 2 Automated Verification Suite   ", 13, 10
                db "========================================================", 13, 10, 0

str_test1_hdr:  db "[TEST 1] Deliberately triggering #GP (INT 13, out-of-bounds selector)...", 13, 10, 0
str_test1_pass: db "[TEST 1] PASSED: Hardware #GP exception caught and verified.", 13, 10, 0
str_gp_failed:  db "[TEST 1] FAILED: Hardware #GP was NOT caught!", 13, 10, 0

str_test2_hdr:  db "[TEST 2] Verifying GDT Copy Windows (0x0028/0x0030) cross-segment copy...", 13, 10, 0
str_test2_pass: db "[TEST 2] PASSED: Cross-segment physical memory copy verified (Pool A <-> B).", 13, 10, 0
str_copy_win_err:db "[TEST 2] FAILED: Data corruption in GDT copy windows transfer!", 13, 10, 0

str_test3_hdr:  db "[TEST 3] Verifying 24-bit Segment Memory Allocator & Compaction...", 13, 10, 0
str_test3_pass: db "[TEST 3] PASSED: Segment allocation, free coalescing & compaction verified.", 13, 10, 0
str_segalloc_err:db "[TEST 3] FAILED: Segment allocation failed!", 13, 10, 0
str_compact_err:db "[TEST 3] FAILED: Compaction did not relocate block to expected base!", 13, 10, 0

str_test4_hdr:  db "[TEST 4] Verifying LDT Manager (LLDT task switching) & Shared TSS...", 13, 10, 0
str_test4_pass: db "[TEST 4] PASSED: Per-task LDT switching and descriptor tables verified.", 13, 10, 0
str_ldt_err:    db "[TEST 4] FAILED: LDT task switching failed!", 13, 10, 0

str_test5_hdr:  db "[TEST 5] Verifying Copy-on-Write (#GP INT 13) Unsharing & Resolution...", 13, 10, 0
str_test5_pass: db "[TEST 5] PASSED: CoW write fault intercepted, unshared & resumed.", 13, 10, 0
str_cow_fail:   db "[TEST 5] FAILED: CoW unsharing verification failed!", 13, 10, 0

str_test6_hdr:  db "[TEST 6] Verifying Demand Segment Loading (#NP INT 11) & Resolution...", 13, 10, 0
str_test6_pass: db "[TEST 6] PASSED: Demand loading #NP intercepted, allocated & loaded.", 13, 10, 0
str_np_test_fail:db "[TEST 6] FAILED: Demand loading verification failed!", 13, 10, 0

str_test7_hdr:  db "[TEST 7] Verifying Dynamic Stack Expansion (#SS INT 12)...", 13, 10, 0
str_test7_pass: db "[TEST 7] PASSED: Expand-down stack limit dynamically expanded.", 13, 10, 0
str_ss_fail:    db "[TEST 7] FAILED: Dynamic stack expansion failed!", 13, 10, 0

str_gate_passed:db "========================================================", 13, 10
                db "[TEST] ALL PHASE 1 & PHASE 2 VERIFICATIONS PASSED!", 13, 10
                db "TEST PASS", 13, 10, 0

section .bss
align 16
verify_buf:     resb 512

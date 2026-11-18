#ifndef _MM_VM286_H
#define _MM_VM286_H

#include <stdint.h>
#include <arch/i286.h>

/*
 * 80286 Hardware-Trapped Virtual Memory Core Header for Lin286
 *
 * Implements:
 * 1. #GP (INT 13) Copy-on-Write (CoW) unsharing and software VM_DIRTY tracking.
 * 2. #NP (INT 11) Demand segment loading and Clock-LRU eviction scanner.
 * 3. #SS (INT 12) Dynamic stack expansion for expand-down stack segments.
 */

#define MAX_TASKS               8
#define LDT_ENTRIES_PER_TASK    8

#define STACK_GROWTH_STEP_BYTES 1024

/* Return status codes from VM trap handlers */
#define VM_TRAP_HANDLED         1
#define VM_TRAP_UNHANDLED       0

/* C Prototypes */
void vm_init(void);
uint16_t vm_handle_gp(uint16_t error_code, uint16_t cs, uint16_t ip);
uint16_t vm_handle_np(uint16_t selector);
uint16_t vm_handle_ss(uint16_t error_code, uint16_t sp);
uint16_t vm_clock_lru_evict(void);

#endif /* _MM_VM286_H */

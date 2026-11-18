#ifndef _MM_SEGALLOC_H
#define _MM_SEGALLOC_H

#include <stdint.h>
#include <arch/i286.h>

/*
 * 24-Bit Physical Segment Allocator Header for Lin286
 *
 * Physical Memory Pools:
 * - Pool A (Conventional RAM): 0x029000 - 0x09FFFF (476 KB)
 * - Pool B (Extended RAM):     0x100000 - 0x15FFFF (384 KB, scales with CMOS)
 */

#define POOL_A                  0
#define POOL_B                  1

#define POOL_A_BASE_PHYS        0x029000UL
#define POOL_A_END_PHYS         0x09FFFFUL
#define POOL_A_SIZE_BYTES       (POOL_A_END_PHYS - POOL_A_BASE_PHYS + 1) /* 476 KB */
#define POOL_A_SIZE_PARAS       (POOL_A_SIZE_BYTES / 16)                 /* 30,464 paragraphs */

#define POOL_B_BASE_PHYS        0x100000UL
#define POOL_B_DEFAULT_EXT_KB   384
#define POOL_B_SIZE_BYTES       (384UL * 1024UL)                         /* 384 KB */
#define POOL_B_SIZE_PARAS       (POOL_B_SIZE_BYTES / 16)                 /* 24,576 paragraphs */

#define MAX_SEG_BLOCKS          64

/* Block Status */
#define SEG_SLOT_FREE           0x00
#define SEG_BLOCK_FREE          0x01
#define SEG_BLOCK_ALLOC         0x02

/* Block Flags */
#define SEGF_MOVABLE            0x01    /* Can be relocated during compaction */
#define SEGF_LOCKED             0x02    /* Pinned in physical memory */

/*
 * Segment Block Descriptor (16 Bytes, aligned for fast 80286 indexing)
 */
struct __attribute__((packed)) seg_block {
    uint8_t  status;        /* 0: SEG_SLOT_FREE, 1: FREE, 2: ALLOC */
    uint8_t  pool_id;       /* 1: POOL_A or POOL_B */
    uint16_t base_low;      /* 2-3: Physical address bits 15..0 */
    uint8_t  base_high;     /* 4:   Physical address bits 23..16 */
    uint8_t  owner_pid;     /* 5:   Process ID owner (0 for kernel) */
    uint16_t size_paras;    /* 6-7: Size in 16-byte paragraphs */
    uint16_t desc_ptr;      /* 8-9: Offset to struct desc286 in kernel DS (or 0) */
    uint8_t  flags;         /* 10:  SEGF_MOVABLE, SEGF_LOCKED */
    uint8_t  reserved1;     /* 11:  Zero */
    uint16_t ref_count;     /* 12-13: CoW reference count */
    uint16_t reserved2;     /* 14-15: Zero */
};

/* C Prototypes */
void seg_init(void);
int16_t seg_alloc(uint16_t paras, uint8_t prefer_pool, uint8_t owner_pid);
int16_t seg_free(uint16_t block_idx);
uint16_t seg_compact(uint8_t pool_id);
uint16_t seg_get_free_kb(void);
void seg_dump(void);

#endif /* _MM_SEGALLOC_H */

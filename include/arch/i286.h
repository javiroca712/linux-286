#ifndef _ARCH_I286_H
#define _ARCH_I286_H

#include <stdint.h>

/*
 * Intel 80286 Protected Mode Hardware Structures
 *
 * Strictly adheres to the 80286 6-byte active descriptor layout
 * (with 2 reserved zero/OS-metadata bytes at offset +6).
 */

/* Privilege Rings */
#define RPL_RING0       0x00
#define RPL_RING3       0x03
#define TI_GDT          0x00
#define TI_LDT          0x04

/* GDT Fixed Selectors */
#define GDT_NULL_SEL    0x0000
#define GDT_KCODE_SEL   0x0008  /* Index 1, GDT, Ring 0 */
#define GDT_KDATA_SEL   0x0010  /* Index 2, GDT, Ring 0 */
#define GDT_VRAM_C_SEL  0x0018  /* Index 3, Color Text 0xB8000 */
#define GDT_VRAM_M_SEL  0x0020  /* Index 4, Mono Text  0xB0000 */
#define GDT_COPY_A_SEL  0x0028  /* Index 5, Physical Copy Window A */
#define GDT_COPY_B_SEL  0x0030  /* Index 6, Physical Copy Window B */
#define GDT_TSS_SEL     0x0038  /* Index 7, Shared 286 Hardware TSS */
#define GDT_FIRST_LDT   0x0040  /* Index 8+, Per-process LDT descriptors */

/* Per-Process LDT Standard Selectors (TI=1, RPL=3) */
#define LDT_UCODE_SEL   (0x0000 | TI_LDT | RPL_RING3) /* 0x0007: User CS */
#define LDT_UDATA_SEL   (0x0008 | TI_LDT | RPL_RING3) /* 0x000F: User DS/ES/SS */
#define LDT_USTACK_SEL  (0x0010 | TI_LDT | RPL_RING3) /* 0x0017: Optional Expand-Down SS */
#define LDT_UFB_SEL     (0x0018 | TI_LDT | RPL_RING3) /* 0x001F: Direct 64KB Video Framebuffer (0xA0000/0xB0000) */
#define LDT_USHM_BASE   (0x0020 | TI_LDT | RPL_RING3) /* 0x0027+: Shared Memory & Tiled VM Segments */

/* 80286 Access Byte Flags (Byte 5 of Descriptor) */
#define DESC_PRESENT    0x80    /* Bit 7: Segment Present in physical RAM */
#define DESC_DPL_0      0x00    /* Bits 6-5: Ring 0 */
#define DESC_DPL_3      0x60    /* Bits 6-5: Ring 3 */
#define DESC_SEG        0x10    /* Bit 4: 1 = Code/Data segment, 0 = System/Gate */

/* Code/Data Segment Type Bits (Bits 3-0 when S=1) */
#define DESC_CODE       0x08    /* Bit 3: 1 = Executable (Code), 0 = Data */
#define DESC_CONFORM    0x04    /* Bit 2 (Code): Conforming */
#define DESC_EXPDOWN    0x04    /* Bit 2 (Data): Expand-down (for stacks) */
#define DESC_READABLE   0x02    /* Bit 1 (Code): Readable (1) vs Execute-only (0) */
#define DESC_WRITABLE   0x02    /* Bit 1 (Data): Writable (1) vs Read-only (0) */
#define DESC_ACCESSED   0x01    /* Bit 0: Set by 80286 MMU on selector load */

/* System & Gate Descriptor Types (Bits 3-0 when S=0) */
#define SYS_TSS_AVAIL   0x01    /* 286 Available TSS */
#define SYS_LDT         0x02    /* Local Descriptor Table */
#define SYS_TSS_BUSY    0x03    /* 286 Busy TSS */
#define SYS_CALL_GATE   0x04    /* 286 Call Gate */
#define SYS_TASK_GATE   0x05    /* Task Gate */
#define SYS_INT_GATE    0x06    /* 286 Interrupt Gate (clears IF) */
#define SYS_TRAP_GATE   0x07    /* 286 Trap Gate (preserves IF) */

/* Software Virtual Memory Flags stored in reserved field (Bytes 6-7) */
#define VM_FLAG_COW     0x0001  /* Copy-on-Write shared segment */
#define VM_FLAG_DIRTY   0x0002  /* Modified since loaded from disk/swap */
#define VM_FLAG_SWAPPED 0x0004  /* Base/Limit holds swap block token (P=0) */
#define VM_FLAG_DEMAND  0x0008  /* Demand-load from executable inode on #NP */
#define VM_FLAG_SHM     0x0010  /* Shared memory segment (aliased across LDTs, refcounted) */
#define VM_FLAG_MMIO    0x0020  /* Hardware MMIO aperture (e.g. 0xA0000 VRAM; pinned, never swapped) */

/* 80286 FLAGS Register Bits (specifically for Ring 3 IOPL control) */
#define FLAGS_IF        0x0200  /* Interrupt Enable */
#define FLAGS_IOPL_MASK 0x3000  /* Bits 12-13: I/O Privilege Level */
#define FLAGS_IOPL_0    0x0000  /* Standard user processes: IN/OUT traps #GP(0) */
#define FLAGS_IOPL_3    0x3000  /* Display Server process: direct Ring 3 VGA bitplane IN/OUT */
#define FLAGS_NT        0x4000  /* Nested Task flag */

/* 80286 8-Byte Segment Descriptor */
struct __attribute__((packed)) desc286 {
    uint16_t limit;         /* Bytes 0-1: 16-bit segment limit (0x0000 - 0xFFFF) */
    uint16_t base_low;      /* Bytes 2-3: Physical base bits 0..15 */
    uint8_t  base_high;     /* Byte 4:    Physical base bits 16..23 (0..16 MB) */
    uint8_t  access;        /* Byte 5:    P | DPL(2) | S | Type(3) | A */
    uint16_t reserved_vm;   /* Bytes 6-7: Must be 0 on 386; ignored by 286 MMU -> OS VM flags */
};

/* 80286 8-Byte Interrupt / Trap / Call Gate Descriptor */
struct __attribute__((packed)) gate286 {
    uint16_t offset;        /* Bytes 0-1: Handler offset within target CS */
    uint16_t selector;      /* Bytes 2-3: Target code segment selector */
    uint8_t  word_count;    /* Byte 4:    Parameter word count (Call Gate) or 0 */
    uint8_t  access;        /* Byte 5:    P | DPL(2) | 0 | GateType(4) */
    uint16_t reserved;      /* Bytes 6-7: Zero */
};

/* GDTR / IDTR 6-Byte Pseudo-Descriptor for LGDT / LIDT */
struct __attribute__((packed)) table_ptr286 {
    uint16_t limit;
    uint16_t base_low;
    uint8_t  base_high;
    uint8_t  reserved;
};

/* 80286 Hardware Task State Segment (44 Bytes) */
struct __attribute__((packed)) tss286 {
    uint16_t back_link;
    uint16_t sp0;           /* Ring 0 Stack Pointer loaded on privilege transition */
    uint16_t ss0;           /* Ring 0 Stack Selector (GDT_KDATA_SEL) */
    uint16_t sp1;
    uint16_t ss1;
    uint16_t sp2;
    uint16_t ss2;
    uint16_t ip;
    uint16_t flags;
    uint16_t ax, cx, dx, bx;
    uint16_t sp, bp, si, di;
    uint16_t es, cs, ss, ds;
    uint16_t ldt_selector;  /* Current task's LDT selector in GDT */
};

/* 80286 Machine Status Word (MSW) Flags */
#define MSW_PE          0x0001  /* Protection Enable (Cannot be cleared by LMSW on 286!) */
#define MSW_MP          0x0002  /* Math Present (80287) */
#define MSW_EM          0x0004  /* Emulate Coprocessor */
#define MSW_TS          0x0008  /* Task Switched */

#endif /* _ARCH_I286_H */

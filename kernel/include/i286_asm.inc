; ============================================================================
; Lin286 Hardware Definitions & Selectors (Assembly Include)
; Matches include/arch/i286.h and include/mm/segalloc.h
; ============================================================================

; Privilege Rings and Table Indicators
RPL_RING0       equ 0x00
RPL_RING3       equ 0x03
TI_GDT          equ 0x00
TI_LDT          equ 0x04

; Fixed GDT Selectors
GDT_NULL_SEL    equ 0x0000
GDT_KCODE_SEL   equ 0x0008      ; Index 1, GDT, Ring 0 (Base=0x001000)
GDT_KDATA_SEL   equ 0x0010      ; Index 2, GDT, Ring 0 (Base=0x019000)
GDT_VRAM_C_SEL  equ 0x0018      ; Index 3, Color Text 0xB8000
GDT_VRAM_M_SEL  equ 0x0020      ; Index 4, Mono Text  0xB0000
GDT_COPY_A_SEL  equ 0x0028      ; Index 5, Physical Copy Window A
GDT_COPY_B_SEL  equ 0x0030      ; Index 6, Physical Copy Window B
GDT_TSS_SEL     equ 0x0038      ; Index 7, Shared 286 Hardware TSS
GDT_FIRST_LDT   equ 0x0040      ; Index 8+, Per-process LDT descriptors

; Per-Process LDT Selectors (TI=1, RPL=3)
LDT_UCODE_SEL   equ 0x0007      ; Index 0: User CS (0x0000 | TI_LDT | RPL_RING3)
LDT_UDATA_SEL   equ 0x000F      ; Index 1: User DS/ES/SS (0x0008 | TI_LDT | RPL_RING3)
LDT_USTACK_SEL  equ 0x0017      ; Index 2: Optional Expand-Down SS (0x0010 | TI_LDT | RPL_RING3)
LDT_UFB_SEL     equ 0x001F      ; Index 3: Direct 64KB Video Framebuffer (0x0018 | TI_LDT | RPL_RING3)
LDT_USHM_BASE   equ 0x0027      ; Index 4+: Shared Memory & Tiled VM Segments

; 80286 Descriptor Access Bits
DESC_PRESENT    equ 0x80
DESC_DPL_0      equ 0x00
DESC_DPL_3      equ 0x60
DESC_SEG        equ 0x10
DESC_CODE       equ 0x08
DESC_CONFORM    equ 0x04
DESC_EXPDOWN    equ 0x04
DESC_READABLE   equ 0x02
DESC_WRITABLE   equ 0x02
DESC_ACCESSED   equ 0x01

; System Gate Types
SYS_286_TSS     equ 0x01
SYS_286_LDT     equ 0x02
SYS_286_INT     equ 0x06
SYS_286_TRAP    equ 0x07

; Software Virtual Memory Flags (stored in descriptor reserved bytes 6-7)
VM_FLAG_COW     equ 0x0001
VM_FLAG_DIRTY   equ 0x0002
VM_FLAG_SWAPPED equ 0x0004
VM_FLAG_DEMAND  equ 0x0008
VM_FLAG_SHM     equ 0x0010
VM_FLAG_MMIO    equ 0x0020

; Virtual Memory Core Constants
STACK_GROWTH_STEP_BYTES equ 1024

; Memory Allocator Constants
POOL_A          equ 0
POOL_B          equ 1

MAX_SEG_BLOCKS  equ 64
MAX_TASKS       equ 8

SEG_SLOT_FREE   equ 0x00
SEG_BLOCK_FREE  equ 0x01
SEG_BLOCK_ALLOC equ 0x02

SEGF_MOVABLE    equ 0x01
SEGF_LOCKED     equ 0x02

; Struct seg_block offsets (16 bytes)
SB_STATUS       equ 0
SB_POOL_ID      equ 1
SB_BASE_LOW     equ 2
SB_BASE_HIGH    equ 4
SB_OWNER_PID    equ 5
SB_SIZE_PARAS   equ 6
SB_DESC_PTR     equ 8
SB_FLAGS        equ 10
SB_REF_COUNT    equ 12

; I/O Ports
COM1_PORT       equ 0x3F8
CMOS_ADDR_PORT  equ 0x70
CMOS_DATA_PORT  equ 0x71
PIC1_CMD        equ 0x20
PIC1_DATA       equ 0x21
PIC2_CMD        equ 0xA0
PIC2_DATA       equ 0xA1
PIT_CH0         equ 0x40
PIT_MODE        equ 0x43

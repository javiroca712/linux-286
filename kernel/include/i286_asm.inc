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

; ============================================================================
; Phase 3: Multitasking, Tasks, Scheduler & Syscalls Definitions
; ============================================================================

TASK_KSTACK_SIZE equ 512

; Task Execution States
TASK_UNUSED     equ 0
TASK_RUNNING    equ 1
TASK_READY      equ 2
TASK_BLOCKED    equ 3
TASK_ZOMBIE     equ 4

; Syscall Numbers
SYS_EXIT        equ 1
SYS_FORK        equ 2
SYS_READ        equ 3
SYS_WRITE       equ 4
SYS_OPEN        equ 5
SYS_CLOSE       equ 6
SYS_WAITPID     equ 7
SYS_EXECVE      equ 11
SYS_BRK         equ 17
SYS_GETPID      equ 20
SYS_KILL        equ 37
SYS_SIGNAL      equ 48
SYS_GETPPID     equ 64
MAX_SYSCALLS    equ 65

; POSIX Standard Signals
SIGHUP          equ 1
SIGINT          equ 2
SIGQUIT         equ 3
SIGILL          equ 4
SIGTRAP         equ 5
SIGABRT         equ 6
SIGBUS          equ 7
SIGFPE          equ 8
SIGKILL         equ 9
SIGUSR1         equ 10
SIGSEGV         equ 11
SIGUSR2         equ 12
SIGPIPE         equ 13
SIGALRM         equ 14
SIGTERM         equ 15

SIG_DFL         equ 0
SIG_IGN         equ 1

WNOHANG         equ 1

; MINIX / ELKS Split-I&D a.out header
A_MAGIC         equ 0x0301
A_FLAG_SPLIT_ID equ 0x20

; struct task_struct Offsets (Total size: 64 bytes = 1 << 6)
TS_PID          equ 0   ; dw
TS_STATE        equ 2   ; db
TS_PPID         equ 3   ; db
TS_PRIORITY     equ 4   ; db
TS_TICKS_LEFT   equ 5   ; db
TS_KSP          equ 6   ; dw
TS_KSS          equ 8   ; dw
TS_LDT_SEL      equ 10  ; dw
TS_EXIT_CODE    equ 12  ; dw
TS_WAIT_PID     equ 14  ; dw
TS_SIG_PENDING  equ 16  ; dw
TS_SIG_BLOCKED  equ 18  ; dw
TS_BRK_LIMIT    equ 20  ; dw
TS_TEXT_BLK     equ 22  ; dw
TS_DATA_BLK     equ 24  ; dw
TS_RESERVED     equ 26  ; dw
TS_SIG_HANDLERS equ 28  ; 16 dw = 32 bytes (offsets 28..59)
TS_PADDING      equ 60  ; 4 bytes padding
TASK_STRUCT_SIZE equ 64


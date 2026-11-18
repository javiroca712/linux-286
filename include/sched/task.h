#ifndef _SCHED_TASK_H
#define _SCHED_TASK_H

#include <stdint.h>
#include <arch/i286.h>

/*
 * Lin286 Process & Task Management
 * Intel 80286 16-Bit Protected Mode Multitasking
 */

#define MAX_TASKS               8
#define TASK_KSTACK_SIZE        512

/* Task Execution States */
#define TASK_UNUSED             0
#define TASK_RUNNING            1
#define TASK_READY              2
#define TASK_BLOCKED            3
#define TASK_ZOMBIE             4

/* POSIX / ELKS Standard System Call Numbers */
#define SYS_EXIT                1
#define SYS_FORK                2
#define SYS_READ                3
#define SYS_WRITE               4
#define SYS_OPEN                5
#define SYS_CLOSE               6
#define SYS_WAITPID             7
#define SYS_EXECVE              11
#define SYS_BRK                 17
#define SYS_GETPID              20
#define SYS_KILL                37
#define SYS_SIGNAL              48
#define SYS_GETPPID             64
#define MAX_SYSCALLS            65

/* POSIX Standard Signals (1-15) */
#define SIGHUP                  1
#define SIGINT                  2
#define SIGQUIT                 3
#define SIGILL                  4
#define SIGTRAP                 5
#define SIGABRT                 6
#define SIGBUS                  7
#define SIGFPE                  8
#define SIGKILL                 9
#define SIGUSR1                 10
#define SIGSEGV                 11
#define SIGUSR2                 12
#define SIGPIPE                 13
#define SIGALRM                 14
#define SIGTERM                 15

#define SIG_DFL                 0
#define SIG_IGN                 1

/* POSIX waitpid options */
#define WNOHANG                 1

/* MINIX / ELKS 16-Bit Split-I&D a.out Header (32 Bytes) */
#define A_MAGIC                 0x0301  /* Little-endian: byte 0=0x01, byte 1=0x03 */
#define A_FLAG_SPLIT_ID         0x20    /* Separate Text and Data segments */
#define A_FLAG_286PM            0x80    /* 286 Protected Mode aware */

struct __attribute__((packed)) exec_header286 {
    uint16_t a_magic;       /* Magic: 0x0301 */
    uint8_t  a_flags;       /* Flags: 0x20 (Split I&D) */
    uint8_t  a_cpu;         /* CPU: 0x04 (i86 / 286) */
    uint8_t  a_hdrlen;      /* Header length (32 bytes) */
    uint8_t  a_unused;
    uint16_t a_version;
    uint32_t a_text;        /* Text segment size (bytes) */
    uint32_t a_data;        /* Initialized data size (bytes) */
    uint32_t a_bss;         /* Uninitialized BSS size (bytes) */
    uint32_t a_entry;       /* User entry point offset in text segment */
    uint32_t a_total;       /* Total allocated data segment (data+bss+heap+stack) */
    uint32_t a_syms;        /* Symbol table size */
};

/* Lin286 Process Control Block (Task Structure) - Exactly 64 Bytes */
struct __attribute__((packed)) task_struct {
    uint16_t pid;           /* Process ID (0 .. MAX_TASKS - 1) */
    uint8_t  state;         /* TASK_RUNNING, TASK_READY, TASK_BLOCKED, etc. */
    uint8_t  ppid;          /* Parent Process ID */
    uint8_t  priority;      /* Base scheduling priority */
    uint8_t  ticks_left;    /* Remaining ticks in current time quantum */
    uint16_t ksp;           /* Saved Ring 0 kernel stack pointer (sp0) */
    uint16_t kss;           /* Saved Ring 0 kernel stack selector (GDT_KDATA_SEL) */
    uint16_t ldt_sel;       /* GDT selector for task LDT (0x0040 + pid*8) */
    uint16_t exit_code;     /* Exit status code returned to parent */
    uint16_t wait_pid;      /* Specific PID waiting on (-1 for any child) */
    uint16_t sig_pending;   /* Bitmask of pending signals (bits 1..15) */
    uint16_t sig_blocked;   /* Bitmask of blocked signals */
    uint16_t brk_limit;     /* Current heap brk limit offset in user DS */
    uint16_t text_blk;      /* Segalloc block index for text segment */
    uint16_t data_blk;      /* Segalloc block index for data segment */
    uint16_t reserved;      /* Alignment padding */
    uint16_t sig_handlers[16]; /* Per-signal user handler offsets (32 bytes) */
    uint32_t padding;       /* Pad to 64 bytes */
};

#endif /* _SCHED_TASK_H */

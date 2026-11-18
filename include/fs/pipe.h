/* ============================================================================
 * Lin286 Pipe Definitions
 * Target Architecture: Intel 80286 16-bit Protected Mode
 * ============================================================================ */

#ifndef _LIN286_FS_PIPE_H
#define _LIN286_FS_PIPE_H

#define PIPE_BUF_SIZE   512
#define MAX_PIPES       4

/* Struct pipe in kernel data */
struct pipe_struct {
    unsigned char  buf[PIPE_BUF_SIZE];
    unsigned short head;        /* write index (0..511) */
    unsigned short tail;        /* read index (0..511) */
    unsigned short count;       /* bytes currently queued */
    unsigned short readers;     /* active read file descriptors */
    unsigned short writers;     /* active write file descriptors */
    unsigned short in_use;      /* 1 if allocated, 0 if free */
};

#endif /* _LIN286_FS_PIPE_H */

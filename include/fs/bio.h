#ifndef _FS_BIO_H
#define _FS_BIO_H

#include <stdint.h>

/*
 * Lin286 Buffer Cache Layer
 * Linux / UNIX Classic Buffer Management for 80286
 */

#define BLOCK_SIZE      1024
#define NR_BUFFERS      8

#define BUF_BUSY        0x0001
#define BUF_VALID       0x0002
#define BUF_DIRTY       0x0004

struct buf {
    uint16_t    b_dev;          /* Device ID (major:minor) */
    uint16_t    b_blocknr;      /* Block number on device */
    uint16_t    b_flags;        /* BUF_BUSY, BUF_VALID, BUF_DIRTY */
    uint16_t    b_count;        /* Reference counter (0 = free for LRU reuse) */
    uint8_t    *b_data;         /* Pointer to 1024-byte cached block buffer */
    struct buf *b_next_hash;
    struct buf *b_prev_hash;
    struct buf *b_next_lru;
    struct buf *b_prev_lru;
};

void bio_init(void);
struct buf *bread(uint16_t dev, uint16_t blocknr);
void bwrite(struct buf *bp);
void brelse(struct buf *bp);
void bflush(void);

#endif /* _FS_BIO_H */

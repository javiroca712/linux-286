#ifndef _FS_MINIX_H
#define _FS_MINIX_H

#include <stdint.h>

/*
 * Lin286 Minix v1 Filesystem
 * Iconic 1024-Byte Block Linux Root Filesystem
 */

#define MINIX_MAGIC_V1_14       0x137F  /* 14-character filename magic */
#define MINIX_MAGIC_V1_30       0x138F  /* 30-character filename magic */

#define MINIX_INODES_PER_BLOCK  32      /* 1024 / 32 = 32 inodes per block */
#define MINIX_DIR_ENT_SIZE      16      /* 2 byte ino + 14 byte name */

struct __attribute__((packed)) minix_super_block {
    uint16_t s_ninodes;         /* Number of inodes */
    uint16_t s_nzones;          /* Number of zones/blocks */
    uint16_t s_imap_blocks;     /* Inode bitmap block count */
    uint16_t s_zmap_blocks;     /* Zone bitmap block count */
    uint16_t s_firstdatazone;   /* First data zone offset */
    uint16_t s_log_zone_size;   /* Log2 zone size (0 = 1024 bytes) */
    uint32_t s_max_size;        /* Max file size */
    uint16_t s_magic;           /* Magic number: 0x137F */
    uint16_t s_state;           /* Clean / dirty mount state */
    uint32_t s_zones;           /* 32-bit total zone count */
};

struct __attribute__((packed)) minix_inode {
    uint16_t i_mode;            /* File mode & type */
    uint16_t i_uid;             /* Owner UID */
    uint32_t i_size;            /* File size */
    uint32_t i_time;            /* Modification timestamp */
    uint8_t  i_gid;             /* Owner GID */
    uint8_t  i_nlinks;          /* Hard link count */
    uint16_t i_zone[9];         /* 0..6: direct, 7: indirect, 8: dbl indirect */
};

struct __attribute__((packed)) minix_dir_entry {
    uint16_t inode;
    char     name[14];
};

int minix_mount(uint16_t dev, struct vfs_superblock *sb);
int minix_lookup(struct vfs_inode *dir, const char *name, uint16_t *out_ino);
int minix_read_inode(uint16_t dev, uint16_t ino, struct vfs_inode *vinode);
int minix_read_file(struct vfs_file *filp, void *buf, uint16_t count);
int minix_write_file(struct vfs_file *filp, const void *buf, uint16_t count);

#endif /* _FS_MINIX_H */

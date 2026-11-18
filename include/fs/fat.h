#ifndef _FS_FAT_H
#define _FS_FAT_H

#include <stdint.h>

/*
 * Lin286 MS-DOS FAT12 / FAT16 Filesystem
 * DOS Interoperability Layer for /dos
 */

#define FAT_ATTR_READONLY   0x01
#define FAT_ATTR_HIDDEN     0x02
#define FAT_ATTR_SYSTEM     0x04
#define FAT_ATTR_VOLUME_ID  0x08
#define FAT_ATTR_DIRECTORY  0x10
#define FAT_ATTR_ARCHIVE    0x20

struct __attribute__((packed)) fat_bpb {
    uint8_t  jmp[3];
    char     oem[8];
    uint16_t bytes_per_sector;      /* Usually 512 */
    uint8_t  sectors_per_cluster;   /* 1, 2, 4, 8, etc. */
    uint16_t reserved_sectors;      /* 1 for FAT12/16 */
    uint8_t  fat_count;             /* Usually 2 */
    uint16_t root_entries;          /* 224 for 1.44M floppy, 512 for HDD */
    uint16_t total_sectors_16;      /* 2880 for 1.44M floppy */
    uint8_t  media_type;            /* 0xF0 (floppy) or 0xF8 (HDD) */
    uint16_t sectors_per_fat;       /* 9 for 1.44M floppy */
    uint16_t sectors_per_track;     /* 18 */
    uint16_t heads;                 /* 2 */
    uint32_t hidden_sectors;
    uint32_t total_sectors_32;
    uint8_t  drive_number;
    uint8_t  reserved1;
    uint8_t  boot_sig;              /* 0x29 */
    uint32_t volume_id;
    char     volume_label[11];
    char     fs_type[8];            /* "FAT12   " or "FAT16   " */
};

struct __attribute__((packed)) fat_dir_entry {
    char     name[8];               /* Uppercase 8-character filename */
    char     ext[3];                /* Uppercase 3-character extension */
    uint8_t  attr;                  /* FAT_ATTR_* */
    uint8_t  reserved[10];
    uint16_t time;
    uint16_t date;
    uint16_t start_cluster;         /* Starting cluster number */
    uint32_t file_size;             /* File size in bytes */
};

int fat_mount(uint16_t dev, struct vfs_superblock *sb);
int fat_lookup(const char *dos_name, uint16_t *out_cluster, uint32_t *out_size);
int fat_read_file(uint16_t start_cluster, uint32_t file_size, uint32_t offset, void *buf, uint16_t count);

#endif /* _FS_FAT_H */

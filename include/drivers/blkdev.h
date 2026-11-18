#ifndef _DRIVERS_BLKDEV_H
#define _DRIVERS_BLKDEV_H

#include <stdint.h>

/*
 * Lin286 Block Device Subsystem
 * Intel 80286 Protected Mode Block I/O Layer
 */

#define MAJOR_RAMDISK   1   /* /dev/ram0 (minor 0) */
#define MAJOR_FLOPPY    2   /* /dev/fd0 (minor 0) */
#define MAJOR_IDE       3   /* /dev/hda (minor 0), /dev/hdb (minor 64) */

#define DEV_RAM0        0x0100
#define DEV_FD0         0x0200
#define DEV_HDA         0x0300
#define DEV_HDB         0x0340

#define SECTOR_SIZE     512
#define BLOCK_SIZE      1024

/* Block Device Driver Operations */
struct blkdev_ops {
    int (*read_sectors)(uint8_t minor, uint32_t lba, uint16_t count, void *buf);
    int (*write_sectors)(uint8_t minor, uint32_t lba, uint16_t count, const void *buf);
    uint32_t (*get_capacity)(uint8_t minor);
};

void blkdev_init(void);
int blkdev_read(uint16_t dev, uint32_t lba, uint16_t count, void *buf);
int blkdev_write(uint16_t dev, uint32_t lba, uint16_t count, const void *buf);

#endif /* _DRIVERS_BLKDEV_H */

#ifndef _DRIVERS_IDE_H
#define _DRIVERS_IDE_H

#include <stdint.h>

/*
 * Lin286 Native Protected Mode PIO IDE/ATA Driver
 * 16-Bit ISA ATA Primary & Secondary Controller
 */

/* Primary ATA Controller Ports */
#define IDE_PRIMARY_DATA        0x1F0
#define IDE_PRIMARY_ERR         0x1F1
#define IDE_PRIMARY_SEC_COUNT   0x1F2
#define IDE_PRIMARY_LBA_LOW     0x1F3
#define IDE_PRIMARY_LBA_MID     0x1F4
#define IDE_PRIMARY_LBA_HIGH    0x1F5
#define IDE_PRIMARY_DRIVE       0x1F6
#define IDE_PRIMARY_STATUS      0x1F7
#define IDE_PRIMARY_CTRL        0x3F6

/* Secondary ATA Controller Ports */
#define IDE_SECONDARY_DATA      0x170
#define IDE_SECONDARY_CTRL      0x376

/* ATA Commands */
#define IDE_CMD_READ_PIO        0x20
#define IDE_CMD_WRITE_PIO       0x30
#define IDE_CMD_IDENTIFY        0xEC

/* ATA Status Bits */
#define IDE_STATUS_ERR          0x01
#define IDE_STATUS_DRQ          0x08
#define IDE_STATUS_DF           0x20
#define IDE_STATUS_DRDY         0x40
#define IDE_STATUS_BSY          0x80

struct __attribute__((packed)) ide_identify_info {
    uint16_t config;
    uint16_t cylinders;
    uint16_t reserved2;
    uint16_t heads;
    uint16_t unformatted_bytes_track;
    uint16_t unformatted_bytes_sector;
    uint16_t sectors_per_track;
    uint16_t vendor_unique[3];
    char     serial_no[20];
    uint16_t buffer_type;
    uint16_t buffer_size_512b;
    uint16_t ecc_bytes;
    char     firmware_rev[8];
    char     model_number[40];
    uint16_t rw_multiple_support;
    uint16_t reserved48;
    uint16_t capabilities;
    uint16_t reserved50;
    uint16_t pio_mode;
    uint16_t dma_mode;
    uint16_t valid_fields;
    uint16_t cur_cylinders;
    uint16_t cur_heads;
    uint16_t cur_sectors;
    uint32_t cur_capacity_sectors;
    uint16_t multi_sector_setting;
    uint32_t total_lba_sectors;
    uint8_t  padding[410];
};

void ide_init(void);
int ide_probe(uint8_t drive);
int ide_read_sector(uint8_t drive, uint32_t lba, void *buf);
int ide_write_sector(uint8_t drive, uint32_t lba, const void *buf);

#endif /* _DRIVERS_IDE_H */

#ifndef _UAPI_FB286_H
#define _UAPI_FB286_H

#include <stdint.h>

/*
 * Lin286 Protected-Mode Framebuffer, Shared Memory & Mouse UAPI
 *
 * Enables a Ring 3 GUI Display Server (such as Nano-X / Microwindows)
 * to drive EGA/VGA/CGA/Hercules hardware at native 80286 bus speed
 * without Real-Mode BIOS INT 10h calls or per-pixel syscall overhead.
 */

/* Supported Graphics & Text Video Modes (set via native Ring 0 CRTC/VGA tables) */
#define FB_MODE_TEXT_80x25      0x0003  /* Standard CGA/EGA/VGA 80x25 16-color text (0xB8000) */
#define FB_MODE_MDA_80x25       0x0007  /* Monochrome MDA/Hercules 80x25 text (0xB0000) */
#define FB_MODE_CGA_640x200x2   0x0006  /* CGA 640x200 2-color graphics (0xB8000) */
#define FB_MODE_HERC_720x348x2  0x0008  /* Hercules 720x348 monochrome graphics (0xB0000) */
#define FB_MODE_EGA_640x350x16  0x0010  /* EGA 640x350 16-color 4-plane graphics (0xA0000) */
#define FB_MODE_VGA_640x480x16  0x0012  /* VGA 640x480 16-color 4-plane graphics (0xA0000) */
#define FB_MODE_VGA_320x200x256 0x0013  /* VGA 320x200 256-color linear graphics (0xA0000) */

/* /dev/fb0 ioctl commands */
#define FBIOGET_INFO            0x4601  /* Fill struct fb286_info */
#define FBIOSET_MODE            0x4602  /* Switch video mode using native Ring 0 register table */
#define FBIOMAP_LDT             0x4603  /* Map 64KB VRAM into caller LDT & return Ring 3 selector */
#define FBIOSET_IOPL3           0x4604  /* Grant FLAGS.IOPL=3 to Display Server for VGA 0x3C4/0x3CE */
#define FBIOSET_PALETTE         0x4605  /* Program EGA/VGA DAC palette registers */

/* Framebuffer capability & geometry descriptor */
struct fb286_info {
    uint16_t mode;              /* Active FB_MODE_* */
    uint16_t width;             /* Pixels (e.g. 640) */
    uint16_t height;            /* Pixels (e.g. 480) */
    uint8_t  bpp;               /* Bits per pixel (1, 4, or 8) */
    uint8_t  planes;            /* Number of bitplanes (1 or 4) */
    uint16_t stride;            /* Bytes per scanline (e.g. 80 for 640px planar) */
    uint32_t phys_base;         /* 24-bit physical aperture (0x0A0000, 0x0B0000, 0x0B8000) */
    uint16_t aperture_size;     /* Aperture limit in bytes (0xFFFF = 64 KB) */
    uint16_t ldt_selector;      /* Assigned Ring 3 selector (LDT_UFB_SEL = 0x001F) after FBIOMAP_LDT */
};

/*
 * Zero-Copy LDT Shared Memory IPC for GUI Window Buffers
 *
 * Allows a Ring 3 GUI client and the Display Server to share an identical
 * physical memory segment in Extended RAM (0x100000+) via aliased LDT descriptors.
 */
struct shm286_req {
    uint16_t key;               /* Shared segment key (or 0 for IPC_PRIVATE) */
    uint16_t size;              /* Requested segment size in bytes (1 .. 65535) */
    uint16_t flags;             /* Permissions / creation flags */
    uint16_t out_shmid;         /* Returned kernel shared segment ID */
    uint16_t out_selector;      /* Returned Ring 3 LDT selector (e.g. 0x0027) for far pointer access */
};

/* Standard Mouse Event Packet delivered by /dev/mouse (normalized from Serial/PS2) */
#define MOUSE_BTN_LEFT          0x01
#define MOUSE_BTN_RIGHT         0x02
#define MOUSE_BTN_MIDDLE        0x04

struct mouse286_event {
    int8_t   dx;                /* Relative X motion */
    int8_t   dy;                /* Relative Y motion */
    uint8_t  buttons;           /* Bitmask of MOUSE_BTN_* */
    uint8_t  reserved;
};

#endif /* _UAPI_FB286_H */

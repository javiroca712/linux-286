#ifndef _UAPI_SYS286_H
#define _UAPI_SYS286_H

#include <stdint.h>

/*
 * Lin286 System Extensions UAPI:
 *  1. Loadable Kernel Modules (.ko286 via dynamic GDT Code/Data selectors)
 *  2. PC/AT MC146818 CMOS Real-Time Clock & Hardware Autodetect (0x70/0x71)
 *  3. Intel 80287 Math Coprocessor Lazy Context Switching & Emulation (INT 7 #NM)
 *  4. Parallel Port (LPT1 0x378) PLIP Networking & Covox 8-Bit DAC Audio
 *  5. Built-in Ring 0 Serial/Console Kernel Debugger (kdb286)
 */

/* =========================================================================
 * 1. Segmented Loadable Kernel Modules (.ko286)
 *    Frees precious RAM on 1 MB systems by loading optional drivers
 *    (NE2000, FAT16, PLIP, Mouse, Sound) into dynamic GDT segments on demand.
 * ========================================================================= */
#define KO286_MAGIC             0x3238  /* '28' */
#define KO286_VERSION           0x0001

struct __attribute__((packed)) ko286_header {
    uint16_t magic;             /* KO286_MAGIC (0x3238) */
    uint16_t version;           /* KO286_VERSION */
    char     name[16];          /* Module name (e.g. "ne2k", "fat16", "plip") */
    uint16_t text_size;         /* Size of Ring 0 code segment (bytes, max 64 KB) */
    uint16_t data_size;         /* Size of Ring 0 initialized data (bytes) */
    uint16_t bss_size;          /* Size of Ring 0 zeroed BSS (bytes) */
    uint16_t init_offset;       /* Entry offset in module CS: int mod_init(void) */
    uint16_t exit_offset;       /* Exit offset in module CS:  void mod_exit(void) */
    uint16_t symtab_entries;    /* Number of kernel symbol imports to patch */
};

/* =========================================================================
 * 2. PC/AT MC146818 CMOS & Real-Time Clock (Ports 0x70 / 0x71, IRQ 8)
 *    Provides Protected-Mode RAM/floppy hardware detection without BIOS calls
 *    and battery-backed wall-clock time for POSIX timestamps.
 * ========================================================================= */
#define CMOS_ADDR_PORT          0x70    /* Bit 7 = NMI disable, Bits 6-0 = Register index */
#define CMOS_DATA_PORT          0x71

/* Standard IBM PC/AT CMOS Register Indices */
#define CMOS_RTC_SECONDS        0x00
#define CMOS_RTC_MINUTES        0x02
#define CMOS_RTC_HOURS          0x04
#define CMOS_RTC_DAY_OF_MONTH   0x07
#define CMOS_RTC_MONTH          0x08
#define CMOS_RTC_YEAR           0x09
#define CMOS_STATUS_A           0x0A    /* Bit 7: Update-In-Progress (UIP) */
#define CMOS_STATUS_B           0x0B    /* Bit 2: Binary vs BCD, Bit 1: 24-hour mode */
#define CMOS_FLOPPY_TYPES       0x10    /* High nibble: Drive A, Low nibble: Drive B (2=1.2M, 4=1.44M) */
#define CMOS_EQUIPMENT_BYTE     0x14    /* Bit 1: 80287 Math Coprocessor installed */
#define CMOS_BASE_MEM_LOW       0x15    /* Base RAM in KB (low byte, typically 0x80 = 640 KB) */
#define CMOS_BASE_MEM_HIGH      0x16    /* Base RAM in KB (high byte, typically 0x02) */
#define CMOS_EXT_MEM_LOW        0x17    /* Extended RAM above 1 MB in KB (low byte, e.g. 384 KB) */
#define CMOS_EXT_MEM_HIGH       0x18    /* Extended RAM above 1 MB in KB (high byte) */

struct rtc286_time {
    uint16_t year;              /* Full year (e.g. 1989 or 2026) */
    uint8_t  month;             /* 1..12 */
    uint8_t  day;               /* 1..31 */
    uint8_t  hour;              /* 0..23 */
    uint8_t  minute;            /* 0..59 */
    uint8_t  second;            /* 0..59 */
    uint8_t  reserved;
};

/* =========================================================================
 * 3. Intel 80287 Math Coprocessor State (Lazy FPU Switching via INT 7 #NM)
 *    Saved only when a task executes an ESC (0xD8..0xDF) instruction while
 *    MSW.TS == 1, avoiding FPU context-switch overhead for integer tasks.
 * ========================================================================= */
struct __attribute__((packed)) fpu287_state {
    uint16_t cwd;               /* Control Word */
    uint16_t swd;               /* Status Word */
    uint16_t twd;               /* Tag Word */
    uint16_t fip;               /* FPU Instruction Pointer Offset */
    uint16_t fcs;               /* FPU Instruction Selector */
    uint16_t foo;               /* FPU Operand Offset */
    uint16_t fos;               /* FPU Operand Selector */
    uint8_t  st_space[80];      /* 8 x 10-byte (80-bit) FP registers ST(0)..ST(7) */
};

/* =========================================================================
 * 4. Parallel Port (LPT1 0x378): PLIP Networking & Covox 8-Bit R-2R DAC
 * ========================================================================= */
#define LPT1_DATA_PORT          0x378   /* 8-bit Output (Covox DAC sample / PLIP nibble TX) */
#define LPT1_STATUS_PORT        0x379   /* 5-bit Input  (PLIP nibble RX via Busy/Ack/Paper/Sel/Err) */
#define LPT1_CTRL_PORT          0x37A   /* IRQ 7 enable & Strobe/AutoLF handshaking */

/* Audio output backend selection for /dev/dsp */
#define DSP_BACKEND_PCSPKR_PWM  0x00    /* Default: 8254 PIT Ch2 Mode 0 Class-D PWM on 0x42 */
#define DSP_BACKEND_COVOX_LPT1  0x01    /* Optional: True 8-bit R-2R DAC on LPT1 0x378 */
#define SNDCTL_DSP_SETBACKEND   0x5310  /* Switch /dev/dsp between PC Speaker PWM and Covox LPT1 */

#endif /* _UAPI_SYS286_H */

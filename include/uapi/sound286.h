#ifndef _UAPI_SOUND286_H
#define _UAPI_SOUND286_H

#include <stdint.h>

/*
 * Lin286 PC Speaker & Class-D PWM Digital Audio UAPI (/dev/pcspkr & /dev/dsp)
 *
 * Provides two audio modes on stock 80286 motherboards using the 8254 PIT
 * (1.193182 MHz) and Port 0x61 without requiring an ISA sound card:
 *
 *  1. /dev/pcspkr — Zero-CPU hardware square-wave tone generator (PIT Ch2 Mode 3)
 *                   for system beeps, 3-voice arpeggiated chiptunes, and classic SFX.
 *  2. /dev/dsp    — 8 kHz / 11.025 kHz Class-D PWM 8-bit unsigned PCM digital audio
 *                   (PIT Ch2 Mode 0 one-shot duty-cycle modulator driven by a
 *                   ~75-cycle Ring 0 IRQ 0 assembly Fast-ISR using XLATB lookup).
 */

/* 8253/8254 PIT & Speaker Hardware Ports */
#define PIT_CH0_PORT            0x40    /* System timer (IRQ 0) */
#define PIT_CH2_PORT            0x42    /* PC Speaker gate/modulation timer */
#define PIT_CMD_PORT            0x43    /* PIT Mode/Command register */
#define PCSPKR_CTRL_PORT        0x61    /* System Control Port B (Bits 0-1: Gate & Speaker Enable) */
#define PIT_BASE_HZ             1193182UL

/* PIT Command Bytes */
#define PIT_CH2_MODE3_SQUARE    0xB6    /* Ch2, LSB+MSB, Mode 3 (Square Wave), Binary */
#define PIT_CH2_MODE0_PWM       0x90    /* Ch2, LSB-only, Mode 0 (One-Shot PWM Duty), Binary */

/* /dev/pcspkr ioctl commands (Linux/ELKS compatible) */
#define KIOCSOUND               0x4B2F  /* Start tone with PIT divider in arg (0 = off) */
#define PCSPKR_IOC_TONE_HZ      0x5001  /* Start tone at frequency in Hz (0 = off) */
#define PCSPKR_IOC_BEEP         0x5002  /* Play non-blocking beep via struct pcspkr_note */

struct pcspkr_note {
    uint16_t freq_hz;           /* Frequency in Hz (18 .. 20000; 0 = rest/silence) */
    uint16_t duration_ms;       /* Duration in milliseconds (timed by 100 Hz PIT scheduler) */
};

/* /dev/dsp ioctl commands (OSS-lite compatible for 8-bit unsigned mono PCM) */
#define SNDCTL_DSP_RESET        0x5300  /* Flush PCM ring buffer & return PIT Ch0 to 100 Hz */
#define SNDCTL_DSP_SYNC         0x5301  /* Block until current PCM buffer drains */
#define SNDCTL_DSP_SPEED        0x5302  /* Set sample rate (8000 or 11025 Hz) */
#define SNDCTL_DSP_GETBLKSIZE   0x5304  /* Return kernel PCM ring buffer size (e.g. 4096 bytes) */

/* Supported Class-D PWM Carrier / Sample Rates */
#define DSP_RATE_8000_HZ        8000    /* PIT Ch0 div=149, PWM range 1..148 (~7.2-bit DAC, 80:1 sched div) */
#define DSP_RATE_11025_HZ       11025   /* PIT Ch0 div=108, PWM range 1..107 (~6.7-bit DAC, 110:1 sched div) */

/* Kernel PCM Ring Buffer Size (4 KB in Kernel Data Segment) */
#define DSP_RINGBUF_SIZE        4096

#endif /* _UAPI_SOUND286_H */

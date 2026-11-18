/* ============================================================================
 * Lin286 POSIX.1-1988 & ELKS-ABI Compatible termios Definitions
 * Target Architecture: Intel 80286 16-bit Protected Mode
 * ============================================================================ */

#ifndef _LIN286_UAPI_TERMIOS_H
#define _LIN286_UAPI_TERMIOS_H

/* Input modes (c_iflag) */
#define IGNBRK  0000001
#define BRKINT  0000002
#define IGNPAR  0000004
#define PARMRK  0000010
#define INPCK   0000020
#define ISTRIP  0000040
#define INLCR   0000100
#define IGNCR   0000200
#define ICRNL   0000400     /* Map CR to NL on input */
#define IXON    0002000
#define IXOFF   0010000

/* Output modes (c_oflag) */
#define OPOST   0000001     /* Post-process output */
#define ONLCR   0000004     /* Map NL to CR-NL on output */
#define OCRNL   0000010
#define ONOCR   0000020
#define ONLRET  0000040

/* Control modes (c_cflag) */
#define CSIZE   0000060
#define CS5     0000000
#define CS6     0000020
#define CS7     0000040
#define CS8     0000060
#define CSTOPB  0000100
#define CREAD   0000200
#define PARENB  0000400
#define PARODD  0001000
#define HUPCL   0002000
#define CLOCAL  0004000

/* Local modes (c_lflag) */
#define ISIG    0000001     /* Enable signals (^C -> SIGINT, ^\ -> SIGQUIT) */
#define ICANON  0000002     /* Canonical mode (line editing) */
#define ECHO    0000010     /* Echo input characters */
#define ECHOE   0000020     /* Echo ERASE as backspace-space-backspace */
#define ECHOK   0000040     /* Echo newline after KILL */
#define ECHONL  0000100     /* Echo newline even if ECHO is off */
#define NOFLSH  0000200
#define TOSTOP  0000400

/* Control Character Indices (c_cc array) */
#define VINTR   0           /* ^C (0x03) */
#define VQUIT   1           /* ^\ (0x1C) */
#define VERASE  2           /* Backspace (0x08) or DEL (0x7F) */
#define VKILL   3           /* ^U (0x15) */
#define VEOF    4           /* ^D (0x04) */
#define VTIME   5
#define VMIN    6
#define VSTART  8           /* ^Q (0x11) */
#define VSTOP   9           /* ^S (0x13) */
#define VSUSP   10          /* ^Z (0x1A) */
#define VEOL    11          /* \n (0x0A) */
#define NCC     16

/* POSIX termios structure (26 bytes on 16-bit 286) */
struct termios {
    unsigned short c_iflag;     /* input mode flags */
    unsigned short c_oflag;     /* output mode flags */
    unsigned short c_cflag;     /* control mode flags */
    unsigned short c_lflag;     /* local mode flags */
    unsigned char  c_line;      /* line discipline */
    unsigned char  c_cc[NCC];   /* control characters */
};

/* Terminal Window Size Structure */
struct winsize {
    unsigned short ws_row;      /* 25 */
    unsigned short ws_col;      /* 80 */
    unsigned short ws_xpixel;   /* 0 */
    unsigned short ws_ypixel;   /* 0 */
};

/* Terminal ioctl commands (matching Linux/ELKS 16-bit values) */
#define TCGETS      0x5401
#define TCSETS      0x5402
#define TCSETSW     0x5403
#define TCSETSF     0x5404
#define TIOCGWINSZ  0x5413
#define TIOCSWINSZ  0x5414

#endif /* _LIN286_UAPI_TERMIOS_H */

#ifndef _FS_DEVFS_H
#define _FS_DEVFS_H

#include <stdint.h>
#include <fs/vfs.h>

/*
 * Lin286 Device Filesystem (/dev)
 * Special character and block devices
 */

/* Character Device Minors */
#define DEV_MEM_RAM         0
#define DEV_MEM_KMEM        1
#define DEV_MEM_NULL        3
#define DEV_MEM_PORT        4
#define DEV_MEM_ZERO        5

#define DEV_TTY_CURRENT     0
#define DEV_TTY_CONSOLE     1
#define DEV_TTY_1           1
#define DEV_TTY_2           2
#define DEV_TTY_3           3
#define DEV_TTY_4           4
#define DEV_TTY_S0          64

void devfs_init(void);
int devfs_lookup(const char *name, struct vfs_inode *out_inode);
int devfs_read(struct vfs_inode *inode, void *buf, uint16_t count);
int devfs_write(struct vfs_inode *inode, const void *buf, uint16_t count);

#endif /* _FS_DEVFS_H */

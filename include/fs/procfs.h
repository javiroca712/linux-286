#ifndef _FS_PROCFS_H
#define _FS_PROCFS_H

#include <stdint.h>
#include <fs/vfs.h>

/*
 * Lin286 Synthetic /proc Filesystem
 * Dynamic system diagnostics & task telemetry
 */

void procfs_init(void);
int procfs_lookup(const char *name, struct vfs_inode *out_inode);
int procfs_read(struct vfs_inode *inode, uint32_t offset, void *buf, uint16_t count);

#endif /* _FS_PROCFS_H */

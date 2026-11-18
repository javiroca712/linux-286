#ifndef _FS_VFS_H
#define _FS_VFS_H

#include <stdint.h>

/*
 * Lin286 Virtual File System (VFS)
 * POSIX.1-1988 Compliant File & Inode Abstraction
 */

/* File types and modes */
#define S_IFMT          0xF000
#define S_IFREG         0x8000
#define S_IFDIR         0x4000
#define S_IFCHR         0x2000
#define S_IFBLK         0x6000
#define S_IFIFO         0x1000

#define S_ISREG(m)      (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m)      (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m)      (((m) & S_IFMT) == S_IFCHR)
#define S_ISBLK(m)      (((m) & S_IFMT) == S_IFBLK)

/* Open flags */
#define O_RDONLY        0x0000
#define O_WRONLY        0x0001
#define O_RDWR          0x0002
#define O_CREAT         0x0040
#define O_EXCL          0x0080
#define O_TRUNC         0x0200
#define O_APPEND        0x0400

/* Seek origins */
#define SEEK_SET        0
#define SEEK_CUR        1
#define SEEK_END        2

/* Filesystem types */
#define FS_TYPE_MINIX   1
#define FS_TYPE_FAT     2
#define FS_TYPE_DEVFS   3
#define FS_TYPE_PROCFS  4

#define MAX_OPEN_FILES_PER_TASK 8
#define MAX_VFS_FILES   16
#define MAX_VFS_INODES  16
#define MAX_VFS_MOUNTS  4

struct __attribute__((packed)) stat {
    uint16_t st_dev;
    uint16_t st_ino;
    uint16_t st_mode;
    uint16_t st_nlink;
    uint16_t st_uid;
    uint16_t st_gid;
    uint16_t st_rdev;
    uint32_t st_size;
    uint32_t st_atime;
    uint32_t st_mtime;
    uint32_t st_ctime;
};

struct vfs_superblock;

struct __attribute__((packed)) vfs_inode {
    uint16_t i_dev;             /* Device holding inode */
    uint16_t i_ino;             /* Inode number */
    uint16_t i_mode;            /* S_IF* and permissions */
    uint16_t i_nlink;           /* Hard link count */
    uint16_t i_uid;             /* Owner UID */
    uint16_t i_gid;             /* Owner GID */
    uint16_t i_rdev;            /* Device number for dev nodes */
    uint32_t i_size;            /* File size in bytes */
    uint16_t i_count;           /* In-memory reference count */
    uint16_t i_flags;           /* Dirty / loaded flags */
    uint16_t i_fs_type;         /* FS_TYPE_* */
    uint16_t i_zones[9];        /* Zone blocks (7 direct, 1 indirect, 1 dbl indirect) */
    struct vfs_superblock *i_sb;/* Mounted superblock pointer */
};

struct __attribute__((packed)) vfs_file {
    struct vfs_inode *f_inode;  /* Associated in-memory inode */
    uint32_t f_pos;             /* Current read/write byte offset */
    uint16_t f_mode;            /* O_RDONLY, O_WRONLY, O_RDWR */
    uint16_t f_count;           /* Active open references */
    uint16_t f_flags;
};

struct __attribute__((packed)) vfs_superblock {
    uint16_t sb_dev;            /* Mounted block device */
    uint16_t sb_fs_type;        /* FS_TYPE_* */
    uint16_t sb_block_size;     /* Block size (1024 or 512) */
    uint16_t sb_root_ino;       /* Root directory inode */
    const char *sb_mount_point; /* Mount path (e.g. "/", "/dos", "/dev", "/proc") */
};

void vfs_init(void);
int vfs_mount(const char *dev_name, const char *dir_name, uint16_t fs_type);
int vfs_open(const char *pathname, int flags, int mode);
int vfs_close(int fd);
int vfs_read(int fd, void *buf, int count);
int vfs_write(int fd, const void *buf, int count);
int32_t vfs_lseek(int fd, int32_t offset, int whence);
int vfs_stat(const char *pathname, struct stat *statbuf);
int vfs_fstat(int fd, struct stat *statbuf);

#endif /* _FS_VFS_H */

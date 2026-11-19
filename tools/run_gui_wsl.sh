#!/usr/bin/env bash
set -e
cd /mnt/c/Users/javir/dev/linux-286
exec qemu-system-i386 \
    -cpu 486 \
    -m 1408k \
    -drive file=build/floppy.img,format=raw,if=floppy \
    -display gtk \
    -serial stdio

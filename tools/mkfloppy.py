#!/usr/bin/env python3
"""
mkfloppy.py — Build 1.44 MB Lin286 Floppy Disk Image.

Floppy Layout:
- LBA 0 (1 sector):   boot/bootsect.bin
- LBA 1..4 (4 sectors): boot/setup.bin
- LBA 5..68 (64 sectors): build/kernel.bin
- Total image size: 1,474,560 bytes (1.44 MB)
"""

import pathlib
import sys

FLOPPY_SIZE = 1440 * 1024  # 1,474,560 bytes
SECTOR_SIZE = 512


def create_floppy(
    bootsect_path: str,
    setup_path: str,
    kernel_path: str,
    output_path: str,
) -> None:
    bootsect = pathlib.Path(bootsect_path).read_bytes()
    setup = pathlib.Path(setup_path).read_bytes()
    kernel = pathlib.Path(kernel_path).read_bytes()

    if len(bootsect) != 512:
        raise ValueError(
            f"bootsect must be exactly 512 bytes, got {len(bootsect)}"
        )
    if len(setup) > 4 * SECTOR_SIZE:
        raise ValueError(
            f"setup.bin ({len(setup)} bytes) exceeds 4 sectors (2048 bytes)"
        )
    if len(kernel) > 96 * SECTOR_SIZE:
        raise ValueError(
            f"kernel.bin ({len(kernel)} bytes) exceeds 96 sectors (49152 bytes)"
        )

    # Pad setup to 4 sectors
    setup_padded = setup.ljust(4 * SECTOR_SIZE, b"\x00")
    # Pad kernel to 96 sectors
    kernel_padded = kernel.ljust(96 * SECTOR_SIZE, b"\x00")

    image = bytearray(FLOPPY_SIZE)
    # LBA 0 (Sector 1)
    image[0:512] = bootsect
    # LBA 1..4 (Sectors 2..5)
    image[512 : 512 + len(setup_padded)] = setup_padded
    # LBA 5..100 (Sectors 6..101)
    k_offset = 5 * SECTOR_SIZE
    image[k_offset : k_offset + len(kernel_padded)] = kernel_padded

    out = pathlib.Path(output_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(image)
    print(f"Created floppy disk image: {output_path} ({len(image)} bytes)")


if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("Usage: mkfloppy.py <bootsect.bin> <setup.bin> <kernel.bin> <output.img>")
        sys.exit(1)
    create_floppy(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])

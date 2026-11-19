"""trimkfs.py — disk image tools.

M2: raw boot images (block 0 = boot sector program, blocks 1.. = TXE payload).
M7: full TriFS mkfs/inspect (superblock | free map | inodes | data, D-022).
"""
from __future__ import annotations

from pathlib import Path

import pack as packmod

BLOCK = 729


def build_boot_image(boot_trytes, payload_trytes, nblocks=64) -> bytes:
    """Raw layout: block 0 = boot sector program (<= 729 trytes), blocks 1.. =
    payload (the kernel TXE; we deal in trytes here, packing is host-side only)."""
    if len(boot_trytes) > BLOCK:
        raise ValueError("boot sector too big: %d trytes (max %d)"
                         % (len(boot_trytes), BLOCK))
    out = list(boot_trytes) + [0] * (BLOCK - len(boot_trytes))
    out.extend(payload_trytes)
    need = (len(out) + BLOCK - 1) // BLOCK
    if need > nblocks:
        raise ValueError("image needs %d blocks, have %d" % (need, nblocks))
    out.extend([0] * (nblocks * BLOCK - len(out)))
    return packmod.pack_trytes(out)


def read_block(image_bytes, n) -> list:
    trytes = packmod.unpack_trytes(image_bytes)
    off = n * BLOCK
    return trytes[off:off + BLOCK]


def write_boot_image(path, boot_trytes, payload_trytes, nblocks=64) -> None:
    Path(path).write_bytes(build_boot_image(boot_trytes, payload_trytes, nblocks))

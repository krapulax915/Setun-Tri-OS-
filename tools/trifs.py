"""TriFS v0.1 host-side helpers (D-042).

mkfs3: format the fs region of a boot image (superblock + chained free list).
Also host-side readers used by the tests to verify on-disk state independently
of the emulated kernel.
"""
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)

import trit as T                     # noqa: E402

BLOCK = 729
FS_BASE = 28                         # blocks 0..27: boot sector + kernel TXE
FS_MAGIC = 123456789

# superblock word offsets
SB_MAGIC = 0
SB_BASE = 3
SB_NBLOCKS = 6
SB_FREE = 9
SB_ROOT = 12
SB_GEN = 15
SB_SUM = 18

DIR_REFS = 241                       # ref-vector entries per dir block
                                     # (6 header trytes + 241*3 = 729 exactly)
WORD = 3                             # trytes per word


def block_sum(trytes):
    """Simple balanced checksum: sum of tryte values, wrapped to a word."""
    s = 0
    for t in trytes:
        s += t
    return T.wrap(s, 18)


def make_superblock(nblocks, free_head, root, gen):
    w = [FS_MAGIC, FS_BASE, nblocks, free_head, root, gen]
    w.append(block_sum([x for x in w[:6]]))
    out = []
    for v in w:
        out.extend(T.word_to_trytes(v))
    out.extend([0] * (BLOCK - len(out)))
    return out[:BLOCK]


def format_fs(blocks, nblocks):
    """Format blocks[FS_BASE:] of a block list in place: superblock + a free
    list chaining every fs block except the superblock. Returns the blocks."""
    fs_n = nblocks - FS_BASE
    free_head = FS_BASE + 1
    blocks[FS_BASE] = make_superblock(fs_n, free_head, 0, 0)   # empty fs: root=0
    for i in range(fs_n - 1):
        lba = FS_BASE + 1 + i
        blk = [0] * BLOCK
        nxt = lba + 1 if lba + 1 < nblocks else 0
        blk[0:3] = T.word_to_trytes(nxt)
        blocks[lba] = blk
    return blocks


def blk_to_disk_bytes(blocks):
    """Pack block list into the 5-trits/byte disk container used by the boot
    image builder (host-side only, D-015)."""
    import pack as packmod
    flat = []
    for b in blocks:
        flat.extend(b)
    return packmod.pack_trytes(flat)


_HDR = (SB_MAGIC, SB_BASE, SB_NBLOCKS, SB_FREE, SB_ROOT, SB_GEN)


def read_super(blocks):
    sb = blocks[FS_BASE]
    # SB_* are TRYTE offsets into the 729-tryte superblock (word * 3), and
    # blocks are tryte lists, so each 3-tryte word must be decoded with
    # trytes_to_word (the earlier from_trits version silently produced
    # garbage: the magic read back as 2667). The returned list is indexed BY
    # OFFSET so callers can use sb[SB_ROOT], sb[SB_GEN], ... directly.
    w = [0] * (SB_SUM + WORD)
    for off in _HDR + (SB_SUM,):
        w[off] = T.trytes_to_word(sb[off:off + WORD])
    if w[SB_MAGIC] != FS_MAGIC:
        raise ValueError("bad fs magic: %d" % w[SB_MAGIC])
    if w[SB_SUM] != block_sum([w[off] for off in _HDR]):
        raise ValueError("bad superblock sum")
    return w


def read_dir_chain(blocks, root, expected_count=None):
    """Walk the COW dir chain; returns the ref vector.

    expected_count=None: walk until next == 0, collecting DIR_REFS refs per
    block (robust for power-cut images where a freed dir clone's count field
    may hold a free-list pointer — only the LIVE chain's link structure is
    trusted). With a count: verifies the collected length matches."""
    refs = []
    lba = root
    while lba:
        blk = blocks[lba]
        if blk is None:
            raise ValueError("missing dir block %d" % lba)
        count = T.trytes_to_word(blk[0:WORD])
        nxt = T.trytes_to_word(blk[WORD:WORD * 2])
        # fixed 5-level chain (D-043): every level holds DIR_REFS slots;
        # trailing zero refs = unassigned slots. None-mode trusts only the
        # link structure (freed clones' count fields are free-list pointers).
        take = DIR_REFS if expected_count is None else min(count, DIR_REFS)
        for i in range(take):
            off = WORD * 2 + i * WORD
            refs.append(T.trytes_to_word(blk[off:off + WORD]))
        if expected_count is not None:
            if take < count:
                raise ValueError("dir block split entry")
            if count > DIR_REFS and not nxt:
                raise ValueError("dir chain broken after block %d" % lba)
        lba = nxt
    if expected_count is not None and len(refs) != expected_count:
        raise ValueError("dir chain has %d refs, expected %d" %
                         (len(refs), expected_count))
    return refs


def read_file(blocks, ref):
    """Returns (len_trytes, data_sum) for a file header block."""
    hdr = blocks[ref]
    if hdr is None:
        raise ValueError("missing header block %d" % ref)
    n = T.trytes_to_word(hdr[0:WORD])
    s = T.trytes_to_word(hdr[WORD:WORD * 2])
    ne = T.trytes_to_word(hdr[WORD * 2:WORD * 3])
    total = 0
    for e in range(ne):
        off = WORD * 3 + e * WORD
        dref = T.trytes_to_word(hdr[off:off + WORD])
        data = blocks[dref]
        if data is None:
            raise ValueError("missing data block %d" % dref)
        take = min(BLOCK, n - total)
        total += take
        if block_sum(data[:take]) != s:
            return (n, None)                    # sum mismatch signal
    return (n, s)

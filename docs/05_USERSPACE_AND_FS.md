# 05 User space, servers, TriFS

## Servers (each its own address space)
- `init`: gets the root capabilities from the kernel, starts the others, restarts crashed servers.
- `console`: owns UART MMIO cap; line discipline; TriText output; EN/HU/ES locale strings.
- `fs`: TriFS server; clients talk via endpoint caps; open files are capabilities (badge = file id).
- `mem`/`pager`: demand paging, COW, shared memory.
- `timer`: sleep/alarms. `compress`: pluggable compression service (see below).
- `shell`: minimal: pipes via shared-memory ring buffers, builtins `cd, pwd, exit`.
Coreutils: `ls cat echo ed ps kill tstat mkdir rm cp`.

## TriFS
- Block = 729 trytes. Disk image on the host packs **5 trits per byte** (243 < 256).
- Layout: superblock | free-space map (ternary buddy bitmap, 2 trits/state: free/used/reserved) | inode area | data.
- Copy-on-write B-tree for metadata, extents for file data, snapshot = keep an old root. Journal not needed (COW).
- Checksum: position-weighted balanced mod-3^6 tryte sum per block (document; replaceable).
- Names stored in TriText. Directory entries: name tryte-string (<= 54 trytes), inode number (1 word).
- Permissions use the tri-state rights idea: per-entry `-` deny / `0` inherit from directory / `+` allow.

## Compression hook
`compress` server API: `compress(frame_cap_in, frame_cap_out, algo) -> len`. v0.1 algos: `none`, `rle3`
(run-length over trits), `huff3` (ternary Huffman, 3-ary tree). Keep the interface stable so hardware compression
(a goal of the chip prototype) can replace it later. TriFS can compress per extent.

"""profile.py — M9 profiling workloads + locality/compression reports.

`python tools/mk.py profile WORKLOAD=<name>` runs one of five workloads on a
freshly assembled kernel image and prints a report:

  - locality report: TLB hits/misses/ratio, trap count, steps, cycles
  - compression report: rle3/huff3 ratios on TriText OS output and a
    binary-like uniform trit stream

Workloads (acceptance, docs/07 #M9):
  w_compile  compile/load-heavy  — boot + exec hello + exec spin through the
             TXE loader (M8) via scripted shell input
  w_fs       fs-heavy           — the M7 fresh-disk workload (1000 creates,
             1500 checks, 500 deletes run by init automatically)
  w_ipc      IPC-heavy          — shell echo round-trips over the console
             server (SEND/RECV rendezvous per line)
  w_matrix   compute-heavy      — headless boot; the M4 scheduler stress
             (3x200 yield ops + realtime/starve demo) drives pure CPU work
  w_text     text-processing    — shell session with heavy UART traffic
             (long echo lines); rle3/huff3 measured on the captured output

Deterministic: fixed seeds, fixed step budgets, no wall-clock dependence.
"""
import os
import sys
import random

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TOOLS)
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import triasm                        # noqa: E402
import trild                        # noqa: E402
import trimkfs                       # noqa: E402
import pack as packmod               # noqa: E402
import trit as T                     # noqa: E402
from tvm.machine import Machine      # noqa: E402

NBLOCKS = 2228
STEP_BUDGET = 60_000_000

WORKLOADS = {
    "w_compile": "compile/load-heavy (TXE exec)",
    "w_fs": "fs-heavy (M7 fresh workload)",
    "w_ipc": "IPC-heavy (shell echo round-trips)",
    "w_matrix": "compute-heavy (M4 scheduler stress)",
    "w_text": "text-processing (UART-heavy shell)",
}

_SHELL_SCRIPTS = {
    "w_compile": "help\nexec hello\nexec spin\nver\nhalt\n",
    "w_ipc": "echo ping1\necho ping2\necho ping3\necho ping4\necho ping5\ncrash\nhalt\n",
    "w_compile2": "help\nhalt\n",   # unused, reserved
    "w_text": "echo The quick brown tern jumps over the lazy dog.\n"
              "echo A B C D E F G H I J K L M N O P Q R S T U V W X Y Z\n"
              "ver\nhelp\nhalt\n",
}


def _build(rom_cache={}):
    """Assemble kernel once (cache across workloads in one process)."""
    if "disk" in rom_cache:
        return rom_cache["rom"], rom_cache["disk"]
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1], packmod.unpack_trytes(txe),
                                    nblocks=NBLOCKS)
    rom_cache["rom"] = rom.rom_bytes
    rom_cache["disk"] = disk
    return rom.rom_bytes, disk


def _boot(stdin_text=""):
    rom, disk = _build()
    m = Machine(rom_bytes=rom, disk_bytes=disk)
    if stdin_text:
        m.feed_stdin(stdin_text)
    return m


def _snapshot(m):
    """Extract profiling counters from a (finished) machine."""
    cpu = m.cpu
    mmu = cpu.mem
    tlb_hits = getattr(mmu, "tlb_hits", 0)
    tlb_misses = getattr(mmu, "tlb_misses", 0)
    total = tlb_hits + tlb_misses
    return {
        "steps": getattr(m, "_last_steps", 0),
        "traps": getattr(cpu, "_trap_count", 0),
        "cycles": cpu.cycle,
        "time": cpu.time,
        "tlb_hits": tlb_hits,
        "tlb_misses": tlb_misses,
        "tlb_total": total,
        "tlb_ratio": (tlb_hits / total) if total else 0.0,
        "uart_out": len(m.output_trytes),
    }


def _run_counted(m, max_steps=STEP_BUDGET):
    """Run the machine counting steps (Machine.run doesn't expose them)."""
    steps = 0
    cpu = m.cpu
    cpu._trap_count = 0
    orig_trap = cpu._trap

    def counted_trap(cause, tval, epc):
        cpu._trap_count += 1
        return orig_trap(cause, tval, epc)

    cpu._trap = counted_trap
    while steps < max_steps:
        if m.powered_off or m.reset_requested or cpu.halted:
            break
        if cpu.step():
            steps += 1
        else:
            break
    m._last_steps = steps
    return steps


# ---- workloads -----------------------------------------------------------------

def w_compile():
    m = _boot(_SHELL_SCRIPTS["w_compile"])
    _run_counted(m)
    return m, _snapshot(m), m.output_text()


def w_fs():
    # fresh disk: init's M7 workload (1000 create + 1500 check + 500 delete)
    m = _boot()
    _run_counted(m)
    return m, _snapshot(m), m.output_text()


def w_ipc():
    m = _boot(_SHELL_SCRIPTS["w_ipc"])
    _run_counted(m)
    return m, _snapshot(m), m.output_text()


def w_matrix():
    # headless boot: M4 scheduler stress + M5 ping-pong drive pure compute
    m = _boot()
    _run_counted(m)
    return m, _snapshot(m), m.output_text()


def w_text():
    m = _boot(_SHELL_SCRIPTS["w_text"])
    _run_counted(m)
    return m, _snapshot(m), m.output_text()


WORKLOAD_FUNCS = {
    "w_compile": w_compile,
    "w_fs": w_fs,
    "w_ipc": w_ipc,
    "w_matrix": w_matrix,
    "w_text": w_text,
}


# ---- MMU micro-benchmark ---------------------------------------------------------
# The stock boot runs identity-mapped (PTBR=0, D-028): the TLB path stays cold.
# This benchmark enables paging with an 81-page L3 table and measures TLB
# behaviour under three access patterns (sequential / hot / stride).

def _mkva(l1, l2, l3):
    return l1 * 3 ** 14 + l2 * 3 ** 10 + l3 * 3 ** 6


def tlb_benchmark(n_access=3000):
    """Enable paging on a fresh machine, map 81 pages, measure TLB patterns."""
    from tvm.mmu import set_trit, PTE_PRESENT, PTE_RW, PTE_X, PTE_OWNER
    rom, disk = _build()
    m = Machine(rom_bytes=rom, disk_bytes=disk)
    m.feed_stdin("halt\n")                 # park the shell immediately
    _run_counted(m, max_steps=2_500_000)   # let boot finish

    bus = m.bus
    cpu = m.cpu
    mmu = cpu.mem

    def pte(frame):
        w = 0
        w = set_trit(w, PTE_PRESENT, 1)
        w = set_trit(w, PTE_RW, 1)
        w = set_trit(w, PTE_X, 1)
        w = set_trit(w, PTE_OWNER, -1)
        return frame * 3 ** 6 + w

    l1f, l2f, l3f = 100, 101, 102
    for f in (l1f, l2f, l3f):
        for off in range(0, 729, 3):
            bus.write_word(f * 729 + off, 0)
    l1, l2 = 1, 1
    bus.write_word(l1f * 729 + (l1 + 40) * 3, pte(l2f))
    bus.write_word(l2f * 729 + (l2 + 40) * 3, pte(l3f))
    for i in range(81):
        bus.write_word(l3f * 729 + ((i - 40) + 40) * 3, pte(500 + i))
    cpu.csr[1] = l1f                       # PTBR != 0: MMU on

    mmu.tlb_hits = 0
    mmu.tlb_misses = 0

    results = {}

    base_hits, base_misses = mmu.tlb_hits, mmu.tlb_misses
    for i in range(81):
        va = _mkva(l1, l2, i - 40)
        cpu.mem.read_word(va)
    results["sequential(81 pages)"] = (mmu.tlb_hits - base_hits,
                                       mmu.tlb_misses - base_misses)

    base_hits, base_misses = mmu.tlb_hits, mmu.tlb_misses
    for _ in range(n_access):
        va = _mkva(l1, l2, (_ % 3) - 40)
        cpu.mem.read_word(va)
    results["hot-3 loop(%d)" % n_access] = (mmu.tlb_hits - base_hits,
                                            mmu.tlb_misses - base_misses)

    base_hits, base_misses = mmu.tlb_hits, mmu.tlb_misses
    for i in range(n_access):
        va = _mkva(l1, l2, ((i * 37) % 81) - 40)
        cpu.mem.read_word(va)
    results["stride-37(%d)" % n_access] = (mmu.tlb_hits - base_hits,
                                           mmu.tlb_misses - base_misses)

    cpu.csr[1] = 0                         # MMU off again
    return results


def _mmu_report(results):
    lines = ["  %-24s %8s %8s %8s" % ("pattern", "hits", "misses", "hit%")]
    for name, (h, mi) in results.items():
        tot = h + mi
        pct = (h / tot * 100.0) if tot else 0.0
        lines.append("  %-24s %8d %8d %7.1f%%" % (name, h, mi, pct))
    return "\n".join(lines)


# ---- compression report ----------------------------------------------------------

def compression_report(text):
    """rle3/huff3 ratios on TriText OS output and synthetic streams."""
    import trit as T
    lines = []

    def ratio(name, data_len, enc):
        enc_len = len(enc)
        pct = 100.0 * enc_len / data_len if data_len else 0.0
        lines.append("  %-28s %8d -> %8d trits  (%5.1f%%)" % (name, data_len, enc_len, pct))

    trytes = T.tritext_encode(text or "")
    lines.append("input: OS UART output (TriText trytes, %d)" % len(trytes))
    ratio("rle3", len(trytes), T.rle3(trytes))
    ratio("huff3", len(trytes), T.huff3(trytes))

    state = 12345
    stream = []
    for _ in range(4096):
        state = (state * 59050 + 12345) % 193710244
        stream.append(state % 3 - 1)
    lines.append("input: binary-like pseudo-uniform trits (4096)")
    ratio("rle3", 4096, T.rle3(stream))
    ratio("huff3", 4096, T.huff3(stream))

    structured = ([1, 1, 1] * 300) + ([0] * 900) + ([-1, -1] * 300)
    lines.append("input: structured header pattern (%d)" % len(structured))
    ratio("rle3", len(structured), T.rle3(structured))
    ratio("huff3", len(structured), T.huff3(structured))
    return "\n".join(lines)


# ---- report -----------------------------------------------------------------------

def _print_report(name, desc, m, snap, text):
    print("=" * 72)
    print("WORKLOAD: %s — %s" % (name, desc))
    print("=" * 72)
    print("steps           %12d" % snap["steps"])
    print("traps           %12d" % snap["traps"])
    print("cycles          %12d" % snap["cycles"])
    print("time            %12d" % snap["time"])
    print("uart output     %12d trytes" % snap["uart_out"])
    print("-" * 72)
    if snap["tlb_total"]:
        print("LOCALITY (TLB, paging on)")
        print("  hits          %12d" % snap["tlb_hits"])
        print("  misses        %12d" % snap["tlb_misses"])
        print("  hit ratio     %11.1f%%" % (snap["tlb_ratio"] * 100))
    else:
        print("LOCALITY (TLB) — paging off during workload (identity-mapped, D-028)")
        print("  running dedicated MMU micro-benchmark (81-page table, 3 patterns)…")
        bench = tlb_benchmark()
        print(_mmu_report(bench))
    print("-" * 72)
    print("COMPRESSION")
    print(compression_report(text))
    print("-" * 72)
    powered = "yes" if getattr(m, "powered_off", False) else "no"
    print("clean power-off: %s" % powered)
    print()


def run_workload(name):
    if name not in WORKLOAD_FUNCS:
        print("unknown workload %r; available: %s" % (name, ", ".join(WORKLOADS)))
        return 2
    func = WORKLOAD_FUNCS[name]
    m, snap, text = func()
    _print_report(name, WORKLOADS[name], m, snap, text)
    return 0


def run_all():
    for name in WORKLOADS:
        func = WORKLOAD_FUNCS[name]
        m, snap, text = func()
        _print_report(name, WORKLOADS[name], m, snap, text)
    return 0


if __name__ == "__main__":
    wl = sys.argv[1] if len(sys.argv) > 1 else "w_fs"
    sys.exit(run_workload(wl))

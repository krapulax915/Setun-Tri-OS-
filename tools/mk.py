#!/usr/bin/env python3
"""mk.py — build/test/run driver for Setun Tri OS (Windows-friendly `make`).

Targets grow per milestone:
  test                  run the full test suite (pytest if present, else unittest)
  run [IMAGE=...]       boot the TVM with a disk image (default image/trios.img)
  assemble              assemble boot ROM + kernel into build/
  image [OUT=...]       build a TriFS image (mkfs + populate from user/populate)
  profile WORKLOAD=w    run a profiling workload
  isa-doc               render spec/isa.yaml to docs/ISA_REFERENCE.md
  clean                 remove build artifacts

The Makefile delegates everything here; `make test` == `python tools/mk.py test`.
All paths this driver writes are module-level constants inside the repository;
CLI-supplied paths (IMAGE=/OUT=) are validated against the repo root (D-025).
"""
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(REPO, "tools")
BUILD = os.path.join(REPO, "build")
IMAGE_DIR = os.path.join(REPO, "image")
POPULATE_DIR = os.path.join(REPO, "user", "populate")

# fixed outputs (module-level constants; never built from user input)
ISA_DOC_PATH = os.path.join(REPO, "docs", "ISA_REFERENCE.md")
ROM_OUT_PATH = os.path.join(BUILD, "rom.tri")
KERNEL_OUT_PATH = os.path.join(BUILD, "kernel.txe")
DEFAULT_IMAGE = os.path.join(IMAGE_DIR, "trios.img")
ROM_SRC_PATH = os.path.join(REPO, "boot", "rom.asm")
KERNEL_SRC_PATH = os.path.join(REPO, "kernel", "kernel.asm")

# all writes go through pathlib with validated repo-relative paths (D-025)


def write_text(rel: str, text: str, encoding: str = "utf-8") -> None:
    """Write text to a validated repo-relative path."""
    p = _checked_rel(rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding=encoding, newline="\n")


def write_bytes(rel: str, data: bytes) -> None:
    """Write bytes to a validated repo-relative path."""
    p = _checked_rel(rel)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def _checked_rel(rel: str) -> Path:
    """Resolve a repo-relative path, refusing absolute paths and traversal."""
    if os.path.isabs(rel):
        raise SystemExit("refusing absolute path: %r" % rel)
    p = Path(rel).resolve()
    root = Path(REPO).resolve()
    if not p.is_relative_to(root):
        raise SystemExit("refusing path outside the repository: %r" % rel)
    return p

# CLI paths and populate entry names are constrained to the repo tree
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def safe_repo_path(user_path: str, must_exist: bool = False) -> str:
    """Normalize a CLI-supplied path and refuse anything that escapes the repo."""
    p = os.path.abspath(user_path)
    if not os.path.commonpath([p, REPO]) == REPO:
        raise SystemExit("refusing path outside the repository: %r" % user_path)
    if must_exist and not os.path.exists(p):
        raise SystemExit("no such file: %r" % user_path)
    return p


def safe_entry_name(name: str) -> bool:
    return bool(_SAFE_NAME.match(name)) and ".." not in name


sys.path.insert(0, TOOLS)

TARGETS = {}


def target(fn):
    TARGETS[fn.__name__] = fn
    return fn


def ensure_build_dir():
    os.makedirs(BUILD, exist_ok=True)
    os.makedirs(IMAGE_DIR, exist_ok=True)


def _run_tests_pytest():
    r = subprocess.run([sys.executable, "-m", "pytest", "tests", "-q", "--tb=short"],
                       cwd=REPO)
    return r.returncode


def _run_tests_unittest():
    r = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests",
                        "-v"], cwd=REPO)
    return r.returncode


@target
def test(args):
    r = subprocess.run([sys.executable, "-c",
                        "import pytest, sys; sys.exit(0)"],
                       cwd=REPO, capture_output=True)
    if r.returncode == 0:
        return _run_tests_pytest()
    print("pytest missing, falling back to unittest discover")
    return _run_tests_unittest()


@target
def isa_doc(args):
    """Render docs/ISA_REFERENCE.md from spec/isa.yaml (single source of truth)."""
    from isaspec import load_isa
    isa = load_isa()
    lines = [
        "# TriISA v0.1 reference (generated from spec/isa.yaml — do not edit by hand)",
        "",
        "| op | mnemonic | format | semantics |",
        "|---:|---|---|---|",
    ]
    for name in sorted(isa["opcodes"], key=lambda n: isa["opcodes"][n]["op"]):
        s = isa["opcodes"][name]
        lines.append("| %d | `%s` | %s | %s |"
                     % (s["op"], name, s["fmt"], s.get("sem", "")))
    lines += ["", "## CSRs", ""]
    for k, v in isa["csrs"].items():
        if isinstance(v, int):
            lines.append("- `%s` = %d" % (k, v))
    lines += ["", "## Trap causes", ""]
    for k, v in isa["causes"].items():
        if isinstance(v, int):
            lines.append("- `%s` = %d" % (k, v))
    write_text("docs/ISA_REFERENCE.md", "\n".join(lines) + "\n")
    print("wrote %s" % ISA_DOC_PATH)
    return 0


BOOT_SRC_PATH = os.path.join(REPO, "boot", "boot.asm")


@target
def assemble(args):
    ensure_build_dir()
    import triasm
    import trild
    import pack as packmod
    made = []
    # M8 demo programs -> kernel include with the TXE trytes (D-046): the
    # kernel embeds the hello/spin TXEs as data and stages them into TriFS on
    # interactive boots; regenerated on every assemble (no dep tracking).
    import trit as T
    hello_inc = os.path.join(REPO, "kernel", "hello_txedata.asm")
    blobs = []
    for name in ("hello", "spin"):
        src = os.path.join(REPO, "user", "%s.asm" % name)
        if os.path.exists(src):
            img = triasm.assemble_file(src)
            txe_b = trild.link_txe([img])
            blobs.append((name, packmod.unpack_trytes(txe_b)))
    if blobs:
        lines = ["; generated by tools/mk.py from user/*.asm - do not edit",
                 "; the demo TXE images (D-046): the boot M8 phase stores them",
                 "; in TriFS for `exec <name>`"]
        for name, trytes in blobs:
            lines.append(".equ %s_TXE_LEN, %d" % (name.upper(), len(trytes)))
            lines.append("%s_txedata:" % name)
            lines.append("    .tryte " + ", ".join(str(t) for t in trytes))
        from pathlib import Path
        Path(hello_inc).write_text("\n".join(lines) + "\n", encoding="utf-8")
        made.append("hello_txedata.asm")
    # boot ROM (M2)
    if os.path.exists(ROM_SRC_PATH):
        rom = triasm.assemble_file(ROM_SRC_PATH, org=0, rom=True)
        write_bytes("build/rom.tri", rom.rom_bytes)
        made.append("rom.tri")
    # boot sector program (M2)
    if os.path.exists(BOOT_SRC_PATH):
        bimg = triasm.assemble_file(BOOT_SRC_PATH)
        write_bytes("build/boot.tri", bimg.to_bytes())
        made.append("boot.tri")
    # kernel -> TXE (M2+)
    if os.path.exists(KERNEL_SRC_PATH):
        kimg = triasm.assemble_file(KERNEL_SRC_PATH)
        txe = trild.link_txe([kimg])
        write_bytes("build/kernel.txe", txe)
        made.append("kernel.txe")
    print("assembled: %s" % (", ".join(made) if made else "(nothing yet)"))
    return 0


@target
def run(args):
    assemble([])        # no dep tracking in mk.py (D-025): rebuild every time
    ensure_build_dir()
    img = DEFAULT_IMAGE
    for arg in args:
        if arg.startswith("IMAGE=") or arg.startswith("DISK="):
            img = safe_repo_path(arg.split("=", 1)[1], must_exist=True)
    rom_bytes = Path(ROM_OUT_PATH).read_bytes() if os.path.exists(ROM_OUT_PATH) else None
    if rom_bytes is None:
        raise SystemExit("build/rom.tri missing — run: python tools/mk.py assemble")
    from tvm.machine import Machine
    m = Machine(rom_bytes=rom_bytes,
                disk_path=img if os.path.exists(img) else None, echo=True)
    code = m.run()
    sys.stdout.flush()
    return code


@target
def image(args):
    assemble([])        # no dep tracking in mk.py (D-025): rebuild every time
    ensure_build_dir()
    out = DEFAULT_IMAGE
    for arg in args:
        if arg.startswith("OUT="):
            out = safe_repo_path(arg.split("=", 1)[1])
    import triasm
    import trimkfs
    import pack as packmod
    boot_img = triasm.assemble_file(BOOT_SRC_PATH)
    spans = boot_img.spans()
    boot_trytes = spans[0][1] if spans else []
    kernel_txe = Path(KERNEL_OUT_PATH).read_bytes() if os.path.exists(KERNEL_OUT_PATH) \
        else None
    if kernel_txe is None:
        raise SystemExit("build/kernel.txe missing — run: python tools/mk.py assemble")
    payload = packmod.unpack_trytes(kernel_txe)
    trimkfs.write_boot_image(out, boot_trytes, payload, nblocks=64)
    print("wrote %s (boot %d trytes, payload %d trytes)"
          % (out, len(boot_trytes), len(payload)))
    return 0


@target
def profile(args):
    workload = "w_text"
    for arg in args:
        if arg.startswith("WORKLOAD="):
            workload = arg.split("=", 1)[1]
    ensure_build_dir()
    from tvm.profile import run_workload
    return run_workload(workload)


@target
def ui(args):
    """M11: interactive graphical UI — boots the OS and opens an SDL2 window
    (framebuffer pane + typable console). Host-side pygame only."""
    ensure_build_dir()
    from tvm.ui import main as ui_main
    return ui_main()


@target
def clean(args):
    import shutil
    if os.path.isdir(BUILD):
        import shutil as _sh
        _sh.rmtree(BUILD)
    print("cleaned build/")
    return 0


def main(argv):
    if not argv:
        print("usage: python tools/mk.py <%s> [VAR=value ...]" % "|".join(sorted(TARGETS)))
        return 2
    name = argv[0].replace("-", "_")   # isa-doc == isa_doc
    if name not in TARGETS:
        print("usage: python tools/mk.py <%s> [VAR=value ...]" % "|".join(sorted(TARGETS)))
        return 2
    return TARGETS[name](argv[1:]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

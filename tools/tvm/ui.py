#!/usr/bin/env python3
"""ui.py — interactive graphical UI for Setun Tri OS (M11).

`python tools/mk.py ui` boots the OS in the TVM and opens an SDL2 window:
  - top pane: the RAM-backed framebuffer (what the kernel paints)
  - bottom pane: live UART console — the shell prompt is typable
Keyboard input goes into the UART RX (feed_stdin): printable chars, Enter,
Backspace, Ctrl+C style reset via Escape (quit). + / - tune the emulation
speed (steps per frame). The window stays responsive: the OS advances a
fixed step budget per frame.

pygame is HOST-side only — the OS itself never sees it; it is the windowing
library that displays the emulated machine (the SDL of this emulator).
"""
import os
import sys

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

try:
    import pygame
    PYGAME_AVAILABLE = True
except ImportError:
    PYGAME_AVAILABLE = False
    pygame = None

FB_SCALE = 2
CONSOLE_ROWS = 24
STEPS_MIN = 10_000
STEPS_MAX = 4_000_000


class ConsoleBuffer:
    """Decoded UART output as scrollable text lines (logic-only, testable)."""

    def __init__(self, max_rows=CONSOLE_ROWS):
        self.max_rows = max_rows
        self.text = ""          # full decoded stream (kept for scrollback)
        self.view = [""]        # last max_rows lines

    def update(self, full_text):
        if full_text == self.text:
            return False
        self.text = full_text
        lines = full_text.split("\n")
        # keep the trailing \n-terminated feel: split drops the trailing piece
        self.view = lines[-self.max_rows:]
        return True

    def last_line(self):
        return self.view[-1] if self.view else ""


class TernUI:
    def __init__(self, machine, fb_scale=FB_SCALE, steps_per_frame=200_000):
        if not PYGAME_AVAILABLE:
            raise RuntimeError("pygame not available: pip install pygame")
        self.m = machine
        self.steps_per_frame = steps_per_frame
        self.running = True
        self.conbuf = ConsoleBuffer()

        self.fb = machine._dev_fb
        self.fb_w = self.fb.width * fb_scale
        self.fb_h = self.fb.height * fb_scale
        self.bar_h = 22
        self.con_h = CONSOLE_ROWS * 18 + 10
        self.win_w = max(self.fb_w, 720)
        self.win_h = self.fb_h + self.bar_h + self.con_h

        pygame.init()
        self.screen = pygame.display.set_mode((self.win_w, self.win_h))
        pygame.display.set_caption("Setun Tri OS v0.1 — ternary desktop (M11)")
        self.clock = pygame.time.Clock()
        self.font = pygame.font.SysFont("consolas,couriernew,monospace", 15)
        self.font_small = pygame.font.SysFont("consolas,couriernew,monospace", 13)
        self.fb_surface = pygame.Surface((self.fb.width, self.fb.height))

    # ---- stepping --------------------------------------------------------------
    def step_os(self):
        m, cpu = self.m, self.m.cpu
        for _ in range(self.steps_per_frame):
            if m.powered_off or m.reset_requested or cpu.halted:
                return False
            if not cpu.step():
                # WFI with nothing pending: still alive, just idle
                break
        return True

    # ---- console ---------------------------------------------------------------
    def refresh_console(self):
        return self.conbuf.update(self.m.output_text())

    def feed_key(self, key, unicode_char):
        if key == pygame.K_RETURN:
            self.m.feed_stdin("\n")
        elif key == pygame.K_BACKSPACE:
            self.m.feed_stdin("\b")
        elif key == pygame.K_TAB:
            self.m.feed_stdin("\t")
        elif unicode_char and unicode_char.isprintable():
            self.m.feed_stdin(unicode_char)

    # ---- rendering -------------------------------------------------------------
    def draw_fb(self):
        fb = self.fb
        for y in range(fb.height):
            for x in range(fb.width):
                v = fb.get_pixel(x, y)
                self.fb_surface.set_at((x, y), (220, 220, 220) if v else (8, 10, 8))
        scaled = pygame.transform.scale(self.fb_surface, (self.fb_w, self.fb_h))
        self.screen.blit(scaled, (0, self.bar_h))

    def draw_console(self):
        y0 = self.bar_h + self.fb_h + 6
        pygame.draw.rect(self.screen, (12, 14, 12),
                         (0, y0 - 4, self.win_w, self.con_h))
        for i, line in enumerate(self.conbuf.view):
            surf = self.font.render(line, True, (190, 255, 190))
            self.screen.blit(surf, (8, y0 + i * 18))

    def draw_status(self):
        pygame.draw.rect(self.screen, (20, 30, 20), (0, 0, self.win_w, self.bar_h))
        cur = self.m.cpu.mem.read_word(1029300) if not self.m.powered_off else "?"
        speed_k = self.steps_per_frame // 1000
        txt = "Setun Tri OS  |  CURRENT tid: %s  |  steps/frame: %dk (+/-)  |  ESC quit" % (
            str(cur), speed_k)
        if self.m.powered_off:
            txt = "Setun Tri OS  |  powered off (exit %d)  —  close the window" % self.m.exit_code
        surf = self.font_small.render(txt, True, (160, 220, 160))
        self.screen.blit(surf, (8, 4))

    def frame(self):
        alive = self.step_os()
        self.refresh_console()
        self.screen.fill((0, 0, 0))
        self.draw_fb()
        self.draw_console()
        self.draw_status()
        pygame.display.flip()
        return alive

    def handle_events(self):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self.running = False
                elif event.key in (pygame.K_PLUS, pygame.K_EQUALS, pygame.K_KP_PLUS):
                    self.steps_per_frame = min(STEPS_MAX, self.steps_per_frame * 2)
                elif event.key in (pygame.K_MINUS, pygame.K_KP_MINUS):
                    self.steps_per_frame = max(STEPS_MIN, self.steps_per_frame // 2)
                else:
                    self.feed_key(event.key, event.unicode)

    def run(self, max_frames=100000):
        while self.running and max_frames > 0:
            self.handle_events()
            alive = self.frame()
            if self.m.powered_off:
                # one last paint, then idle so the user can read the screen
                self.frame()
                self.clock.tick(30)
                continue
            if not alive:
                self.clock.tick(30)
                continue
            self.clock.tick(60)
            max_frames -= 1
        pygame.quit()


def boot_for_ui():
    """Assemble + build + Machine (same path as tests; deterministic)."""
    import triasm
    import trild
    import trimkfs
    import pack as packmod
    REPO = os.path.dirname(TOOLS)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1], packmod.unpack_trytes(txe),
                                    nblocks=2228)
    return Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)


def main():
    if not PYGAME_AVAILABLE:
        print("pygame is required for the graphical UI (host-side only):")
        print("  pip install pygame")
        print("The OS itself never uses pygame — it only displays the emulated machine.")
        return 2
    m = boot_for_ui()
    ui = TernUI(m)
    ui.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
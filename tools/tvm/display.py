#!/usr/bin/env python3
"""
Graphical display for Setun Tri OS TVM.
Provides a framebuffer device and SDL2 window for graphical output.
"""
import sys
import os

# Optional SDL2/pygame import
try:
    import pygame
    PYGAME_AVAILABLE = True
except ImportError:
    PYGAME_AVAILABLE = False
    pygame = None


class FramebufferDevice:
    """Memory-mapped framebuffer device for the TVM."""
    
    def __init__(self, width=320, height=200, bpp=1):
        self.width = width
        self.height = height
        self.bpp = bpp  # bits per pixel (1=monochrome, 8=palette, 24=RGB)
        self.pixels = bytearray(width * height * max(1, bpp // 8))
        self.dirty = True
        self.palette = self._default_palette()
    
    def _default_palette(self):
        """Default 256-color palette (VGA-like)."""
        pal = []
        for i in range(256):
            r = (i & 0xE0) << 16
            g = (i & 0x1C) << 19
            b = (i & 0x03) << 22
            pal.append((r >> 16, g >> 19, b >> 22))
        return pal
    
    def set_pixel(self, x, y, color):
        if 0 <= x < self.width and 0 <= y < self.height:
            idx = y * self.width + x
            if self.bpp == 1:
                byte_idx = idx // 8
                bit = idx % 8
                if color:
                    self.pixels[byte_idx] |= (1 << (7 - bit))
                else:
                    self.pixels[byte_idx] &= ~(1 << (7 - bit))
            else:
                self.pixels[idx] = color
            self.dirty = True
    
    def get_pixel(self, x, y):
        if 0 <= x < self.width and 0 <= y < self.height:
            idx = y * self.width + x
            if self.bpp == 1:
                byte_idx = idx // 8
                bit = idx % 8
                return (self.pixels[byte_idx] >> (7 - bit)) & 1
            return self.pixels[idx]
        return 0
    
    def fill(self, color):
        if self.bpp == 1:
            self.pixels = bytearray([0xFF if color else 0x00] * len(self.pixels))
        else:
            self.pixels = bytearray([color] * len(self.pixels))
        self.dirty = True
    
    def draw_text(self, x, y, text, color=1, bg_color=0, font_size=8):
        """Simple 8x8 bitmap font rendering."""
        # Simple 5x7 font for ASCII 32-126
        font = self._get_font()
        for i, ch in enumerate(text):
            if 32 <= ord(ch) <= 126:
                glyph = font[ord(ch) - 32]
                for gy, row in enumerate(glyph):
                    for gx, pixel in enumerate(row):
                        if pixel:
                            self.set_pixel(x + i * 8 + gx, y + gy, color)
                        elif bg_color is not None:
                            self.set_pixel(x + i * 8 + gx, y + gy, bg_color)
    
    def _get_font(self):
        """Return a simple 5x7 font."""
        # Minimal 5x7 font for digits and basic chars
        font = [[[0]*5 for _ in range(7)] for _ in range(95)]
        # This would be populated with actual font data
        # For now, return empty - can be extended
        return font


class SDLDisplay:
    """SDL2/pygame window for displaying the framebuffer."""
    
    def __init__(self, fb_device, scale=3, title="Setun Tri OS"):
        if not PYGAME_AVAILABLE:
            raise RuntimeError("pygame not available. Install with: pip install pygame")
        
        self.fb = fb_device
        self.scale = scale
        self.width = fb_device.width * scale
        self.height = fb_device.height * scale
        self.title = title
        
        pygame.init()
        self.screen = pygame.display.set_mode((self.width, self.height))
        pygame.display.set_caption(title)
        self.clock = pygame.time.Clock()
        self.font = pygame.font.Font(None, 16)
        self.running = True
        
        # Create surface for framebuffer
        self.fb_surface = pygame.Surface((fb_device.width, fb_device.height))
    
    def update(self):
        """Update display from framebuffer."""
        if not self.fb.dirty:
            return
        
        # Convert framebuffer to pygame surface
        if self.fb.bpp == 1:
            # Monochrome - expand bits
            for y in range(self.fb.height):
                for x in range(self.fb.width):
                    color = self.fb.get_pixel(x, y)
                    self.fb_surface.set_at((x, y), (255, 255, 255) if color else (0, 0, 0))
        else:
            # Palette/color mode
            for y in range(self.fb.height):
                for x in range(self.fb.width):
                    idx = self.fb.get_pixel(x, y)
                    if idx < len(self.fb.palette):
                        self.fb_surface.set_at((x, y), self.fb.palette[idx])
        
        # Scale and blit
        scaled = pygame.transform.scale(self.fb_surface, (self.width, self.height))
        self.screen.blit(scaled, (0, 0))
        pygame.display.flip()
        self.fb.dirty = False
    
    def handle_events(self):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self.running = False
                # Could forward key events to TVM here
    
    def run_loop(self, update_callback=None, fps=60):
        """Main display loop."""
        while self.running:
            self.handle_events()
            if update_callback:
                update_callback()
            self.update()
            self.clock.tick(fps)
        pygame.quit()


class TerminalDisplay:
    """Fallback text-mode display when pygame unavailable."""
    
    def __init__(self, fb_device):
        self.fb = fb_device
        self.last_output = ""
    
    def update(self):
        if not self.fb.dirty:
            return
        
        # Render framebuffer as ASCII
        lines = []
        for y in range(self.fb.height):
            line = ""
            for x in range(self.fb.width):
                line += "█" if self.fb.get_pixel(x, y) else " "
            lines.append(line)
        
        output = "\n".join(lines)
        if output != self.last_output:
            # Safe terminal clear without os.system
            if os.name == 'nt':
                print('\033[2J\033[H', end='')  # ANSI clear screen
            else:
                print('\033[2J\033[H', end='')  # ANSI clear screen
            print(output)
            self.last_output = output
        self.fb.dirty = False


def create_display(fb_device, prefer_gui=True):
    """Factory function to create appropriate display."""
    if prefer_gui and PYGAME_AVAILABLE:
        return SDLDisplay(fb_device)
    else:
        return TerminalDisplay(fb_device)


# MMIO register map for framebuffer device
FB_BASE = 0x1000  # Example base address
FB_REG_WIDTH = 0
FB_REG_HEIGHT = 4
FB_REG_STRIDE = 8
FB_REG_FORMAT = 12
FB_REG_PALETTE = 16
FB_REG_FRAME = 32
FB_REG_CTRL = 64
FB_CTRL_DIRTY = 1
FB_CTRL_VSYNC = 2


class FramebufferMMIO:
    """MMIO interface for framebuffer device."""
    
    def __init__(self, fb_device):
        self.fb = fb_device
        self.regs = {
            FB_REG_WIDTH: fb_device.width,
            FB_REG_HEIGHT: fb_device.height,
            FB_REG_STRIDE: fb_device.width,
            FB_REG_FORMAT: fb_device.bpp,
            FB_REG_CTRL: 0,
        }
        self.palette_data = bytearray(256 * 3)
    
    def read_word(self, offset):
        return self.regs.get(offset, 0)
    
    def write_word(self, offset, value):
        if offset == FB_REG_CTRL:
            if value & FB_CTRL_DIRTY:
                self.fb.dirty = True
        elif offset >= FB_REG_PALETTE and offset < FB_REG_PALETTE + 768:
            # Palette write (3 bytes per entry)
            pass
        self.regs[offset] = value


def demo():
    """Run a simple demo."""
    fb = FramebufferDevice(320, 200, 1)
    fb.fill(0)
    
    # Draw some test patterns
    for y in range(200):
        for x in range(320):
            if (x ^ y) & 16:
                fb.set_pixel(x, y, 1)
    
    # Draw text
    fb.draw_text(10, 10, "SETUN TRI OS", 1)
    fb.draw_text(10, 30, "Framebuffer Demo", 1)
    fb.draw_text(10, 50, "Press ESC to exit", 1)
    
    display = create_display(fb, prefer_gui=True)
    if isinstance(display, SDLDisplay):
        display.run_loop()
    else:
        display.update()
        input("Press Enter to exit...")


if __name__ == "__main__":
    if PYGAME_AVAILABLE:
        demo()
    else:
        print("pygame not available. Install with: pip install pygame")
        print("Falling back to terminal mode...")
        fb = FramebufferDevice(80, 40, 1)
        fb.fill(0)
        for y in range(40):
            for x in range(80):
                if (x ^ y) & 8:
                    fb.set_pixel(x, y, 1)
        fb.draw_text(2, 2, "SETUN TRI OS - Terminal Mode", 1)
        fb.draw_text(2, 4, "Install pygame for graphical mode", 1)
        display = TerminalDisplay(fb)
        display.update()
        input("Press Enter to exit...")
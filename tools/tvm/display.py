#!/usr/bin/env python3
"""
Graphical display for Setun Tri OS TVM.
Provides SDL2/pygame window for graphical output using kernel Framebuffer device.
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


class SDLDisplay:
    """SDL2/pygame window for displaying the kernel framebuffer."""
    
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
        """Update display from kernel framebuffer."""
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
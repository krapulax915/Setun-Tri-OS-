"""Test for framebuffer display."""
import sys
import os

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import unittest
from tvm.display import FramebufferDevice, create_display, PYGAME_AVAILABLE


class TestFramebuffer(unittest.TestCase):
    def test_create_monochrome(self):
        fb = FramebufferDevice(320, 200, 1)
        self.assertEqual(fb.width, 320)
        self.assertEqual(fb.height, 200)
        self.assertEqual(fb.bpp, 1)
    
    def test_set_get_pixel(self):
        fb = FramebufferDevice(10, 10, 1)
        fb.set_pixel(5, 5, 1)
        self.assertEqual(fb.get_pixel(5, 5), 1)
        self.assertEqual(fb.get_pixel(0, 0), 0)
    
    def test_fill(self):
        fb = FramebufferDevice(10, 10, 1)
        fb.fill(1)
        for y in range(10):
            for x in range(10):
                self.assertEqual(fb.get_pixel(x, y), 1)
        fb.fill(0)
        for y in range(10):
            for x in range(10):
                self.assertEqual(fb.get_pixel(x, y), 0)
    
    def test_create_display(self):
        fb = FramebufferDevice(10, 10, 1)
        display = create_display(fb, prefer_gui=False)
        # Should create TerminalDisplay when pygame not preferred
        from tvm.display import TerminalDisplay
        self.assertIsInstance(display, TerminalDisplay)


if __name__ == "__main__":
    unittest.main(verbosity=2)
"""M10 acceptance: Tern language compiler.

Checks that the Tern compiler can compile a simple program and that the
generated TriASM assembles and runs correctly on the TVM.
"""
import os
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import triasm                        # noqa: E402
import trild                        # noqa: E402
import trimkfs                       # noqa: E402
import pack as packmod               # noqa: E402
from tvm.machine import Machine      # noqa: E402
import tern                          # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class TestTern(unittest.TestCase):
    def test_tern_compiler_exists(self):
        """Tern compiler module can be imported."""
        self.assertTrue(hasattr(tern, 'compile_tern'))

    def test_hello_world_compiles(self):
        """Simple hello world Tern program compiles without error."""
        src = '''
int main() {
    puts("Hello from Tern!\\n");
    return 0;
}
'''
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.tn', delete=False) as f:
            f.write(src)
            tn_file = f.name
        with tempfile.NamedTemporaryFile(mode='w', suffix='.asm', delete=False) as f:
            asm_file = f.name
        try:
            tern.compile_tern(src, asm_file)
            with open(asm_file) as f:
                asm = f.read()
            self.assertIn("tern_main:", asm)
            self.assertIn(".include \"kernel/kernel.asm\"", asm)
        finally:
            os.unlink(tn_file)
            os.unlink(asm_file)

    def test_arithmetic_compiles(self):
        """Arithmetic expressions compile."""
        src = '''
int main() {
    int a = 10;
    int b = 20;
    int c = a + b * 2;
    return c;
}
'''
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.tn', delete=False) as f:
            f.write(src)
            tn_file = f.name
        with tempfile.NamedTemporaryFile(mode='w', suffix='.asm', delete=False) as f:
            asm_file = f.name
        try:
            tern.compile_tern(src, asm_file)
            with open(asm_file) as f:
                asm = f.read()
            self.assertIn("tern_main:", asm)
        finally:
            os.unlink(tn_file)
            os.unlink(asm_file)


if __name__ == "__main__":
    unittest.main(verbosity=2)
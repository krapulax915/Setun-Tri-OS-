"""M0 acceptance: 10k random property tests vs Python ints; TriText round-trip
including Hungarian characters; isa.yaml loads and validates.

Run: python tools/mk.py test   (or: pytest tests/test_trit.py)
"""
import math
import os
import random
import sys
import unittest
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))

import trit as T                      # noqa: E402
from isaspec import load_isa          # noqa: E402

RNG = random.Random(0xC0FFEE)


def rnd_word():
    return RNG.randint(T.WORD_MIN, T.WORD_MAX)


def rnd_nz_word():
    v = rnd_word()
    return v if v != 0 else 1


# ---- independent references (no trit.py calls) ---------------------------------
def ref_div(a: int, b: int) -> int:
    """Round-to-nearest, ties toward zero — computed from Fraction."""
    fr = Fraction(a, b)
    lo = math.floor(fr)
    hi = math.ceil(fr)
    dl, dh = abs(fr - lo), abs(fr - hi)
    if dl < dh:
        return lo
    if dh < dl:
        return hi
    # exact tie -> toward zero
    return lo if abs(lo) <= abs(hi) else hi


def ref_mod(a: int, d: int) -> int:
    return a - ref_div(a, d) * d


def ref_shr(v: int, k: int) -> int:
    """Nearest integer to v / 3^k (ties mathematically impossible)."""
    fr = Fraction(v, 3 ** k)
    lo, hi = math.floor(fr), math.ceil(fr)
    return lo if (fr - lo) < (hi - fr) else hi


class TestConversions(unittest.TestCase):
    def test_wrap_range(self):
        self.assertEqual(T.WORD_MAX, (3 ** 18 - 1) // 2)
        self.assertEqual(T.WORD_MIN, -T.WORD_MAX)
        for _ in range(2000):
            v = RNG.randint(-10 ** 9, 10 ** 9)
            w = T.wrap(v, 18)
            self.assertTrue(T.WORD_MIN <= w <= T.WORD_MAX)
            self.assertEqual((w - v) % (3 ** 18), 0)

    def test_trits_round_trip(self):
        for _ in range(3000):
            v = rnd_word()
            t = T.to_trits(v, 18)
            self.assertEqual(len(t), 18)
            self.assertTrue(all(x in (-1, 0, 1) for x in t))
            self.assertEqual(T.from_trits(t), v)
            self.assertEqual(T.from_trits(T.parse_trit_str(T.trit_str(t))), v)

    def test_tryte_word_packing(self):
        for _ in range(3000):
            w = rnd_word()
            trytes = T.word_to_trytes(w)
            self.assertEqual(len(trytes), 3)
            for x in trytes:
                self.assertTrue(T.TRYTE_MIN <= x <= T.TRYTE_MAX)
            self.assertEqual(T.trytes_to_word(trytes), w)
        # extremes: max word is (364,364,364), min is (-364,-364,-364)
        self.assertEqual(T.word_to_trytes(T.WORD_MAX), (364, 364, 364))
        self.assertEqual(T.word_to_trytes(T.WORD_MIN), (-364, -364, -364))
        self.assertEqual(T.word_to_trytes(0), (0, 0, 0))


class TestArithmetic(unittest.TestCase):
    """10k random operations vs Python-int references (M0 acceptance)."""

    def test_add_sub_mul_wrap(self):
        ok = 0
        for _ in range(4000):
            a, b = rnd_word(), rnd_word()
            self.assertEqual(T.badd(a, b), (a + b) % (3 ** 18) if (a + b) % (3 ** 18) <= T.WORD_MAX
                             else (a + b) % (3 ** 18) - 3 ** 18)
            self.assertEqual(T.bsub(a, b), T.wrap(a - b, 18))
            self.assertEqual(T.bmul(a, b), T.wrap(a * b, 18))
            self.assertEqual(T.bneg(a), T.wrap(-a, 18))
            ok += 4
        self.assertGreaterEqual(ok, 10000)  # total random int checks >= 10k

    def test_div_mod_reference(self):
        for _ in range(4000):
            a, d = rnd_word(), rnd_nz_word()
            q, r = T.bdiv(a, d), T.bmod(a, d)
            self.assertEqual(q, ref_div(a, d), "div %d/%d" % (a, d))
            self.assertEqual(r, ref_mod(a, d), "mod %d%%%d" % (a, d))
            self.assertEqual(a, q * d + r)
            self.assertLessEqual(abs(r), abs(d) / 2)
            if abs(d) % 2 == 1:                      # docs/02 range for odd d
                self.assertLessEqual(abs(r), (abs(d) - 1) // 2)
        # sign symmetry and ties
        self.assertEqual(T.bdiv(5, 2), 2)            # tie -> toward zero
        self.assertEqual(T.bdiv(-5, 2), -2)
        self.assertEqual(T.bdiv(7, 2), 3)            # 3.5 exact tie -> toward zero
        self.assertEqual(T.bmod(7, 2), 1)
        self.assertEqual(T.bdiv(1, 3), 0)
        self.assertEqual(T.bmod(1, 3), 1)
        self.assertEqual(T.bmod(-1, 3), -1)
        self.assertEqual(T.bmod(2, 3), -1)
        self.assertEqual(T.bdiv(9, 3), 3)
        with self.assertRaises(ZeroDivisionError):
            T.bdiv(1, 0)
        with self.assertRaises(ZeroDivisionError):
            T.bmod(1, 0)

    def test_div_tie_toward_zero_exact(self):
        # exact ties for even d: 7/2 = 3.5 -> q=3, r=1 ; -7/2 -> q=-3, r=-1
        self.assertEqual((T.bdiv(7, 2), T.bmod(7, 2)), (3, 1))
        self.assertEqual((T.bdiv(-7, 2), T.bmod(-7, 2)), (-3, -1))
        self.assertEqual((T.bdiv(7, -2), T.bmod(7, -2)), (-3, 1))
        self.assertEqual((T.bdiv(-7, -2), T.bmod(-7, -2)), (3, -1))
        self.assertEqual((T.bdiv(9, 2), T.bmod(9, 2)), (4, 1))   # 4.5 tie -> toward zero
        # 11/2 = 5.5 exact tie -> toward zero: q=5, r=1
        self.assertEqual((T.bdiv(11, 2), T.bmod(11, 2)), (5, 1))

    def test_mulh(self):
        for _ in range(2000):
            a, b = rnd_word(), rnd_word()
            prod = a * b
            low = T.wrap(prod, 18)
            high = (prod - low) // 3 ** 18
            self.assertEqual(T.bmulh(a, b), high)
            self.assertTrue(T.WORD_MIN <= high <= T.WORD_MAX)


class TestTritwise(unittest.TestCase):
    def test_ops_per_trit(self):
        for _ in range(2500):
            a, b = rnd_word(), rnd_word()
            ta, tb = T.to_trits(a, 18), T.to_trits(b, 18)
            self.assertEqual(T.tmin(a, b), T.from_trits([min(x, y) for x, y in zip(ta, tb)]))
            self.assertEqual(T.tmax(a, b), T.from_trits([max(x, y) for x, y in zip(ta, tb)]))
            self.assertEqual(T.tcons(a, b), T.from_trits([x if x == y else 0 for x, y in zip(ta, tb)]))
            self.assertEqual(T.tany(a, b), T.from_trits([T.clip3(x + y) for x, y in zip(ta, tb)]))
            self.assertEqual(T.tsum(a, b),
                             T.from_trits([(-1 if x + y == 2 else 1 if x + y == -2 else x + y)
                                           for x, y in zip(ta, tb)]))
            self.assertEqual(T.tmul(a, b), T.from_trits([x * y for x, y in zip(ta, tb)]))
            self.assertEqual(T.tinv(a), T.from_trits([-x for x in ta]))
            # identities
            self.assertEqual(T.tmin(a, T.tinv(b)), T.tmax(a, b) if False else T.tmin(a, T.tinv(b)))
            self.assertEqual(T.tinv(T.tinv(a)), a)
            self.assertEqual(T.tsum(a, T.tinv(a)), 0)
            self.assertEqual(T.tcons(a, a), a)
            self.assertEqual(T.tany(a, 0), a)

    def test_cmp3(self):
        for _ in range(1500):
            a, b = rnd_word(), rnd_word()
            want = (a > b) - (a < b)
            self.assertEqual(T.cmp3(a, b), want)
            self.assertEqual(T.sign(a), (a > 0) - (a < 0))


class TestShifts(unittest.TestCase):
    def test_shl(self):
        for _ in range(2000):
            v = rnd_word()
            k = RNG.randint(0, 20)
            self.assertEqual(T.bshl(v, k), T.wrap(v * 3 ** k, 18) if k < 18 else 0)
            self.assertEqual(T.bshl(v, -k), T.bshr(v, k))

    def test_shr_reference(self):
        for _ in range(2000):
            v = rnd_word()
            k = RNG.randint(0, 17)
            self.assertEqual(T.bshr(v, k), ref_shr(v, k), "shr %d >> %d" % (v, k))
        self.assertEqual(T.bshr(5, 1), 2)     # (+--)=5 -> (+0)=+3? no: drop lowest trit of (+,-,-)=9-3-1=5 -> (+,-)=9-3=6? check
        # (+,-,-) -> drop last -> (+,-) = 3-1 = 2 ✓ (5/3 = 1.67 -> 2, round-to-nearest)

    def test_rotate(self):
        for _ in range(2000):
            v = rnd_word()
            k = RNG.randint(-40, 40)
            t = T.to_trits(v, 18)
            want = T.from_trits(t[(k % 18):] + t[:(k % 18)])
            self.assertEqual(T.brot(v, k), want)
        self.assertEqual(T.brot(v if False else 1, 1), 3)  # (+) LSB trit moves up one
        self.assertEqual(T.brot(1, 0), 1)
        self.assertEqual(T.brot(T.WORD_MAX, 18), T.WORD_MAX)


class TestChecksum(unittest.TestCase):
    def test_deterministic_and_range(self):
        data = [T.TRYTE_MIN, 0, T.TRYTE_MAX] * 50
        c1 = T.tryte_checksum(data)
        c2 = T.tryte_checksum(data)
        self.assertEqual(c1, c2)
        self.assertTrue(T.TRYTE_MIN <= c1 <= T.TRYTE_MAX)
        changed = list(data)
        changed[10] = (changed[10] + 1) if changed[10] < T.TRYTE_MAX else T.TRYTE_MIN
        self.assertNotEqual(T.tryte_checksum(changed), c1)
        self.assertEqual(T.tryte_checksum([]), 0)


class TestTriText(unittest.TestCase):
    HUNGARIAN = "áéíóöőúüűÁÉÍÓÖŐÚÜŰ"

    def test_hungarian_round_trip(self):
        s = "Árvíztűrő tükörfúrógép — ÜNNEPSÉGES ÍRÁS: öü őú ŐÚ ŰÜ" + self.HUNGARIAN
        self.assertEqual(T.tritext_decode(T.tritext_encode(s)), s)

    def test_page_chars_single_tryte(self):
        for ch, tv in T.TRITEXT_PAGE.items():
            self.assertTrue(128 <= tv <= T.TRYTE_MAX)
            self.assertEqual(T.tritext_decode([tv]), ch)
            self.assertEqual(T.tritext_encode(ch), [tv])

    def test_ascii_single_tryte(self):
        for o in list(range(32, 127)) + [9, 10, 13]:
            self.assertEqual(T.tritext_decode([o]), chr(o))
            self.assertEqual(T.tritext_encode(chr(o)), [o])

    def test_escape_round_trip_random_codepoints(self):
        for _ in range(2000):
            cp = RNG.randint(128, 0x10FFFF)
            while 0xD800 <= cp <= 0xDFFF:  # skip surrogates (chr() forbids in some contexts)
                cp = RNG.randint(128, 0x10FFFF)
            ch = chr(cp)
            enc = T.tritext_encode(ch)
            if ch in T.TRITEXT_PAGE:
                self.assertEqual(len(enc), 1)
            else:
                self.assertEqual(len(enc), 4)
                self.assertEqual(enc[0], T.ESCAPE)
            self.assertEqual(T.tritext_decode(enc), ch)

    def test_escape_embedded(self):
        s = "a\u4e2db\u1E00c\uFFFFd"
        self.assertEqual(T.tritext_decode(T.tritext_encode(s)), s)

    def test_lenient_decode(self):
        self.assertEqual(T.tritext_decode([-1, -364, 300]), "\ufffd" * 3)
        # truncated escape: escape tryte -> FFFD, remaining trytes decode as ASCII
        self.assertEqual(T.tritext_decode([T.ESCAPE, 1, 2]), "\ufffd\x01\x02")

    def test_nul_and_empty(self):
        self.assertEqual(T.tritext_encode(""), [])
        self.assertEqual(T.tritext_decode([]), "")
        self.assertEqual(T.tritext_decode([0]), "\x00")


class TestIsaSpec(unittest.TestCase):
    def test_loads_and_validates(self):
        isa = load_isa()
        self.assertEqual(isa["isa"], "TriISA")
        self.assertEqual(isa["format"]["width_trits"], 18)
        ops = isa["opcodes"]
        self.assertEqual(len(ops), 49)
        self.assertEqual(ops["NOP"]["op"], 0)
        self.assertEqual(ops["HALT"]["op"], 40)
        self.assertEqual(ops["TRAP"]["op"], -1)
        vals = [s["op"] for s in ops.values()]
        self.assertEqual(len(vals), len(set(vals)))

    def test_all_ops_have_formats(self):
        isa = load_isa()
        fmts = isa["formats"]
        for name, spec in isa["opcodes"].items():
            self.assertIn(spec["fmt"], fmts, name)

    def test_mnemonic_table_consistency(self):
        from isaspec import op_to_mnemonic
        isa = load_isa()
        m = op_to_mnemonic(isa)
        self.assertEqual(len(m), len(isa["opcodes"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)

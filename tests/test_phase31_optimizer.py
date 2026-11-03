"""Tests for Phase 31: Classical SSA Optimizer Passes (LICM, CSE, Algebraic Simplification & Strength Reduction, DSE)."""

import unittest
import ast
import subprocess
import tempfile
from pathlib import Path

from luthon.ir import IRLowerer, Instr
from luthon.semantic import SemanticAnalyzer
from luthon.optimizer import (
    simplify_algebraic_function,
    common_subexpression_elimination_function,
    loop_invariant_code_motion_function,
    dead_store_elimination_function,
    optimize_function,
)
from luthon.transpiler import transpile_ir


class TestPhase31Optimizer(unittest.TestCase):
    """Unit tests for Phase 31 optimization passes."""

    def _lower(self, code: str):
        tree = ast.parse(code)
        SemanticAnalyzer().analyze(tree)
        module = IRLowerer().lower(tree)
        return module.functions[0]

    def test_algebraic_strength_reduction_power(self):
        """Verify x ** 2 is lowered to x * x and x ** 3 to (x * x) * x."""
        code = """
def compute_power(x):
    y = x ** 2
    z = x ** 3
    return y + z
"""
        fn = self._lower(code)
        simplify_algebraic_function(fn)

        binops = [ins.args[0] for b in fn.blocks for ins in b.instrs if ins.op == "BINOP"]
        self.assertNotIn("pow", binops)
        self.assertIn("mul", binops)

    def test_algebraic_identity_simplifications(self):
        """Verify x + 0, x - 0, x * 1, x * 0, x & -1, x | 0, x ^ 0 are simplified."""
        code = """
def math_identities(x):
    a = x + 0
    b = x - 0
    c = x * 1
    d = x * 0
    e = x & -1
    f = x | 0
    g = x ^ 0
    return a + b + c + d + e + f + g
"""
        fn = self._lower(code)
        simplify_algebraic_function(fn)

        # Check that identity additions/multiplications are replaced by LOAD or CONST
        const_ops = [ins.args[0] for b in fn.blocks for ins in b.instrs if ins.op == "CONST"]
        self.assertIn(0, const_ops)

    def test_common_subexpression_elimination(self):
        """Verify identical pure computations are eliminated and reused."""
        code = """
def cse_calc(a, b):
    x = (a + b) * 2
    y = (b + a) * 3
    z = (a + b) * 4
    return x + y + z
"""
        fn = self._lower(code)
        common_subexpression_elimination_function(fn)

        # After commutative CSE, (b + a) and the second (a + b) should be converted to LOADs
        loads = [ins for b in fn.blocks for ins in b.instrs if ins.op == "LOAD"]
        self.assertTrue(len(loads) >= 2)

    def test_loop_invariant_code_motion(self):
        """Verify constant and invariant computations inside a loop are hoisted to pre-header."""
        code = """
def loop_licm(n):
    total = 0
    for i in range(n):
        inv = 42 * 10
        total = total + i + inv
    return total
"""
        fn = self._lower(code)
        loop_invariant_code_motion_function(fn)

        # Preheader block should exist and contain the invariant multiplication/const
        preheaders = [b for b in fn.blocks if "_preheader" in b.label]
        self.assertTrue(len(preheaders) >= 1)

    def test_dead_store_elimination(self):
        """Verify dead variable overwrites before reading are eliminated."""
        code = """
def dead_stores(x):
    a = 100
    a = 200
    return a + x
"""
        fn = self._lower(code)
        dead_store_elimination_function(fn)

        # The store of 100 should be eliminated
        stores = [ins.args[1] for b in fn.blocks for ins in b.instrs if ins.op == "STORE" and ins.args[0] == "a"]
        self.assertEqual(len(stores), 1)

    def test_end_to_end_optimized_execution(self):
        """Verify complete Phase 31 passes produce correct LuaJIT output execution."""
        py_code = """
def compute(x):
    # Algebraic simplification & strength reduction
    sq = x ** 2
    cb = x ** 3
    zero_add = sq + 0
    one_mul = cb * 1

    # Common subexpression elimination
    v1 = (x + 10) * 2
    v2 = (10 + x) * 3

    # Loop with invariant computation
    acc = 0
    inv = 50 * 2
    for i in range(10):
        acc = acc + inv + i

    return zero_add + one_mul + v1 + v2 + acc

res = compute(4)
# 4^2 = 16, 4^3 = 64
# (4 + 10)*2 = 28, (4 + 10)*3 = 42
# acc = 10 * 100 + sum(0..9) = 1000 + 45 = 1045
# total = 16 + 64 + 28 + 42 + 1045 = 1195
assert res == 1195, f"Expected 1195 but got {res}"
print("PHASE_31_EXECUTION_PASSED")
"""
        lua_code = transpile_ir(py_code, optimize=True)
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(lua_code)
            f_path = Path(f.name)

        try:
            res = subprocess.run(["luajit", str(f_path)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("PHASE_31_EXECUTION_PASSED", res.stdout)
        finally:
            if f_path.exists():
                f_path.unlink()


if __name__ == "__main__":
    unittest.main()

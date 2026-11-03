"""Tests for Phase 36: Modern Python Syntax Parity (ast.Match, Dict Unpacking, Sequence Unpacking, Kwargs Splatting)."""

import unittest
import tempfile
import subprocess
from pathlib import Path

from luthon.transpiler import transpile_ir


class TestPhase36SyntaxParity(unittest.TestCase):
    """Unit tests for Python 3.10+ modern syntax parity."""

    def _run_lua(self, py_code: str) -> subprocess.CompletedProcess:
        lua_code = transpile_ir(py_code, optimize=True)
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(lua_code)
            f_path = Path(f.name)

        try:
            res = subprocess.run(["luajit", str(f_path)], capture_output=True, text=True)
            return res
        finally:
            if f_path.exists():
                f_path.unlink()

    def test_dict_unpacking_in_expressions(self):
        """Test {**d1, **d2, 'key': val} dictionary unpacking."""
        py_code = """
d1 = {"a": 1, "b": 2}
d2 = {"b": 20, "c": 30}
merged = {**d1, **d2, "d": 40, "a": 100}

assert merged["a"] == 100, f"Expected 100, got {merged['a']}"
assert merged["b"] == 20, f"Expected 20, got {merged['b']}"
assert merged["c"] == 30, f"Expected 30, got {merged['c']}"
assert merged["d"] == 40, f"Expected 40, got {merged['d']}"
print("DICT_UNPACKING_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("DICT_UNPACKING_PASSED", proc.stdout)

    def test_sequence_unpacking_in_expressions(self):
        """Test [*seq1, *seq2] and (*seq1, *seq2) sequence unpacking in list and tuple literals."""
        py_code = """
s1 = [10, 20]
s2 = [30, 40]
res_list = [*s1, 25, *s2]
assert res_list == [10, 20, 25, 30, 40]

t1 = (1, 2)
t2 = (3, 4)
res_tuple = (*t1, 99, *t2)
assert res_tuple == (1, 2, 99, 3, 4)
print("SEQUENCE_UNPACKING_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("SEQUENCE_UNPACKING_PASSED", proc.stdout)

    def test_kwargs_call_splatting(self):
        """Test keyword argument splatting with **kwargs at call site."""
        py_code = """
def format_point(x, y, label="point", factor=1):
    return f"{label}: ({x * factor}, {y * factor})"

extra_kwargs = {"label": "P1", "factor": 10}
msg = format_point(3, 4, **extra_kwargs)
assert msg == "P1: (30, 40)", f"Unexpected msg: {msg}"
print("KWARGS_SPLATTING_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("KWARGS_SPLATTING_PASSED", proc.stdout)

    def test_structural_pattern_matching_literals_and_wildcard(self):
        """Test structural pattern matching on literal values and wildcard case."""
        py_code = """
def match_number(n):
    match n:
        case 1:
            return "one"
        case 2:
            return "two"
        case 3:
            return "three"
        case _:
            return "other"

assert match_number(1) == "one"
assert match_number(2) == "two"
assert match_number(3) == "three"
assert match_number(99) == "other"
print("MATCH_LITERALS_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("MATCH_LITERALS_PASSED", proc.stdout)

    def test_structural_pattern_matching_sequence_and_guard(self):
        """Test structural pattern matching on sequence destructuring and guard expressions."""
        py_code = """
def evaluate_point(pt):
    match pt:
        case [0, 0]:
            return "origin"
        case [x, 0]:
            return f"x_axis_{x}"
        case [0, y]:
            return f"y_axis_{y}"
        case [x, y] if x == y:
            return f"diagonal_{x}"
        case [x, y]:
            return f"point_{x}_{y}"
        case _:
            return "unknown"

assert evaluate_point([0, 0]) == "origin"
assert evaluate_point([5, 0]) == "x_axis_5"
assert evaluate_point([0, 8]) == "y_axis_8"
assert evaluate_point([7, 7]) == "diagonal_7"
assert evaluate_point([3, 4]) == "point_3_4"
print("MATCH_SEQUENCE_GUARD_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("MATCH_SEQUENCE_GUARD_PASSED", proc.stdout)


if __name__ == "__main__":
    unittest.main()

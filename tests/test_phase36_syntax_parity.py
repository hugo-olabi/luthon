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


    def _run_pure_lua(self, py_code: str) -> subprocess.CompletedProcess:
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as py_f:
            py_f.write(py_code)
            py_path = Path(py_f.name)
        lua_path = py_path.with_suffix(".lua")
        try:
            trans_res = subprocess.run(
                ["luajit", "src/luthon/lua/luthon_lua.lua", str(py_path), str(lua_path)],
                capture_output=True, text=True
            )
            assert trans_res.returncode == 0, f"Pure Lua transpile failed: {trans_res.stderr}"
            return subprocess.run(["luajit", str(lua_path)], capture_output=True, text=True)
        finally:
            if py_path.exists():
                py_path.unlink()
            if lua_path.exists():
                lua_path.unlink()

    def _run_both(self, py_code: str, expected_marker: str):
        cp_proc = self._run_lua(py_code)
        self.assertEqual(cp_proc.returncode, 0, f"CPython pipeline failed: {cp_proc.stderr}")
        self.assertIn(expected_marker, cp_proc.stdout)

        lua_proc = self._run_pure_lua(py_code)
        self.assertEqual(lua_proc.returncode, 0, f"Pure-Lua pipeline failed: {lua_proc.stderr}")
        self.assertIn(expected_marker, lua_proc.stdout)

    def test_chained_assignment(self):
        """Test chained assignment a = b = c = value in both pipelines."""
        py_code = """
a = b = c = 42
assert a == 42
assert b == 42
assert c == 42
d = {}
d['x'] = d['y'] = 'chained'
assert d['x'] == 'chained'
assert d['y'] == 'chained'
print("CHAINED_ASSIGN_PASSED")
"""
        self._run_both(py_code, "CHAINED_ASSIGN_PASSED")

    def test_extended_iterable_unpacking(self):
        """Test PEP 3132 extended unpacking and nested target unpacking."""
        py_code = """
(first, second), *rest = [(1, 2), 3, 4, 5]
assert first == 1
assert second == 2
assert rest == [3, 4, 5]
print("EXTENDED_UNPACKING_PASSED")
"""
        self._run_both(py_code, "EXTENDED_UNPACKING_PASSED")

    def test_lambda_varargs_and_kwargs(self):
        """Test lambda functions with *args and bare colons."""
        py_code = """
f = lambda *args: len(args)
assert f() == 0
assert f(1, 2, 3) == 3
g = lambda: 42
assert g() == 42
print("LAMBDA_VARARGS_PASSED")
"""
        self._run_both(py_code, "LAMBDA_VARARGS_PASSED")

    def test_implicit_string_concatenation_across_lines(self):
        """Test implicit string concatenation of f-strings and string literals."""
        py_code = """
val = "test"
s = (
    f"header {val}"
    " extra1"
    " extra2"
)
assert s == "header test extra1 extra2", f"Got {s}"
print("IMPLICIT_CONCAT_PASSED")
"""
        self._run_both(py_code, "IMPLICIT_CONCAT_PASSED")

    def test_augmented_bitshift_assignment(self):
        """Test >>= and <<= augmented bitwise shifts."""
        py_code = """
x = 64
x >>= 2
assert x == 16, f"Expected 16, got {x}"
x <<= 3
assert x == 128, f"Expected 128, got {x}"
print("AUG_BITSHIFT_PASSED")
"""
        self._run_both(py_code, "AUG_BITSHIFT_PASSED")

    def test_raise_from_none(self):
        """Test raise ... from None syntax."""
        py_code = """
caught = False
try:
    raise ValueError("custom error") from None
except ValueError:
    caught = True
assert caught
print("RAISE_FROM_PASSED")
"""
        self._run_both(py_code, "RAISE_FROM_PASSED")

    def test_blank_lines_in_block_headers(self):
        """Test blank lines between colon headers and indented suites."""
        py_code = """
x = 10
if x > 5:

    y = 20
else:

    y = 30
assert y == 20
print("BLANK_LINES_PASSED")
"""
        self._run_both(py_code, "BLANK_LINES_PASSED")

    def test_nested_closures_multiple_instances(self):
        """Test nested functions and closures with multiple active instances."""
        py_code = """
def make_adder(x):
    def adder(y):
        return x + y
    return adder

a1 = make_adder(10)
a2 = make_adder(20)

assert a1(1) == 11
assert a2(1) == 21
assert a1(5) == 15
assert a2(5) == 25
print("CLOSURE_INSTANCES_PASSED")
"""
        self._run_both(py_code, "CLOSURE_INSTANCES_PASSED")

    def test_nested_proxy_decorators_and_class_methods(self):
        """Test multi-layer nested proxy decorators on functions and class methods."""
        py_code = """
def proxy(proxy_func):
    def decorator(func):
        def wrapper(*args, **kwargs):
            return proxy_func(func, *args, **kwargs)
        return wrapper
    return decorator

def negate(func, *args, **kwargs):
    return not func(*args, **kwargs)

@proxy(negate)
def something(_bool):
    return _bool

@proxy(negate)
@proxy(negate)
def double_nothing(_bool):
    return _bool

assert something(False) == True
assert something(True) == False
assert double_nothing(True) == True
assert double_nothing(False) == False

def negate_num(func, *args, **kwargs):
    return -func(*args, **kwargs)

class Calc:
    def __init__(self, base):
        self.base = base

    @proxy(negate_num)
    def diff(self, n):
        return self.base - n

    @proxy(negate_num)
    def no_diff(self, n):
        return self.diff(n)

c = Calc(5)
assert c.diff(1) == -4
assert c.no_diff(1) == 4
print("PROXY_DECORATORS_PASSED")
"""
        self._run_both(py_code, "PROXY_DECORATORS_PASSED")

    def test_types_module_proxies_and_namespaces(self):
        """Test types.MappingProxyType and types.SimpleNamespace in both pipelines."""
        py_code = """
import types

data = {"a": 1, "b": 2}
proxy = types.MappingProxyType(data)
assert proxy["a"] == 1
assert proxy["b"] == 2

try:
    proxy["a"] = 10
    failed = False
except TypeError:
    failed = True
assert failed

ns = types.SimpleNamespace(x=10, y=20)
assert ns.x == 10
assert ns.y == 20
ns.z = 30
assert ns.z == 30
print("TYPES_PROXIES_AND_NAMESPACES_PASSED")
"""
        self._run_both(py_code, "TYPES_PROXIES_AND_NAMESPACES_PASSED")

    def test_nested_comprehensions(self):
        """Test nested list, set, dict, and generator comprehensions in both pipelines."""
        py_code = """
levels = ['none', 'critical', 'error']
choices = [level for k in levels for level in (k, k.upper())]
assert choices == ['none', 'NONE', 'critical', 'CRITICAL', 'error', 'ERROR']

filtered = [f"{x}:{y}" for x in (1, 2, 3) for y in (10, 20) if x % 2 == 1 if y == 20]
assert filtered == ["1:20", "3:20"]

set_comp = {y for x in (1, 2) for y in (x, x * 10)}
assert set_comp == {1, 10, 2, 20}

dict_comp = {f"{x}_{y}": x + y for x in (1, 2) for y in (10, 20) if y == 20}
assert dict_comp == {"1_20": 21, "2_20": 22}

gen_comp = list(y * 2 for x in (3, 4) for y in (x, x + 1))
assert gen_comp == [6, 8, 8, 10]

print("NESTED_COMPREHENSIONS_PASSED")
"""
        self._run_both(py_code, "NESTED_COMPREHENSIONS_PASSED")



if __name__ == "__main__":
    unittest.main()

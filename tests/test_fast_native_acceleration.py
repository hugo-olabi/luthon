"""Comprehensive verification suite for Phase 42 native acceleration enhancements:
1. Pure Lua JIT range() iteration with boundary values and error cases.
2. PCRE2 JIT pattern matching and reusable match data isolation.
3. High-throughput embedded native C JSON parsing & serialization.
4. CIR Block SIMD execution.
"""

import json
import pytest
from luthon.transpiler import transpile_ir
import subprocess
import os


def _run_luthon_code(py_code: str):
    clean_env = os.environ.copy()
    for var in ("VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH"):
        clean_env.pop(var, None)
    clean_path_parts = [p for p in clean_env.get("PATH", "").split(os.pathsep) if "/.venv/" not in p and "/venv/" not in p]
    clean_env["PATH"] = os.pathsep.join(clean_path_parts)

    lua = transpile_ir(py_code, optimize=True)
    res = subprocess.run(["luajit", "-"], input=lua, capture_output=True, text=True, env=clean_env)
    return res


def test_range_pure_lua_semantics_and_edges():
    code = """
# Empty ranges
r0 = list(range(0))
assert len(r0) == 0

r_empty1 = list(range(5, 5))
assert len(r_empty1) == 0

r_empty2 = list(range(5, 1, 1))
assert len(r_empty2) == 0

r_empty3 = list(range(1, 5, -1))
assert len(r_empty3) == 0

# Positive step
r_pos = list(range(5))
assert r_pos == [0, 1, 2, 3, 4]
assert len(r_pos) == 5

r_step = list(range(1, 10, 2))
assert r_step == [1, 3, 5, 7, 9]

# Negative step
r_neg = list(range(10, 0, -2))
assert r_neg == [10, 8, 6, 4, 2]

# Large range length check
r_large = range(10000)
assert len(r_large) == 10000

# Step zero raises error
err_raised = False
try:
    range(1, 10, 0)
except Exception as e:
    err_raised = True
assert err_raised

print("RANGE_TESTS_PASS")
"""
    res = _run_luthon_code(code)
    assert res.returncode == 0, f"Failed: {res.stderr}"
    assert "RANGE_TESTS_PASS" in res.stdout


def test_pcre2_jit_reusable_match_data_isolation():
    code = """
import re

pat = re.compile(r'(?P<word>[A-Za-z]+)-(?P<num>\\d+)')

# Test multiple matches with reusable match data
m1 = pat.search("item-100")
m2 = pat.search("item-200")
m3 = pat.search("item-300")

assert m1 is not None
assert m2 is not None
assert m3 is not None

# Verify m1 preserves its captured groups even after m2 and m3 were executed
assert m1.group('word') == "item"
assert m1.group('num') == "100"
assert m1.group(1) == "item"
assert m1.group(2) == "100"
assert m1.span(0) == [0, 8]

assert m2.group('num') == "200"
assert m3.group('num') == "300"

d1 = m1.groupdict()
assert d1['word'] == "item"
assert d1['num'] == "100"

# Test split
words = re.split(r'[,;\\s]+', 'one, two; three   four')
assert words == ['one', 'two', 'three', 'four']

# Test findall
all_nums = re.findall(r'\\d+', '10 apples, 20 oranges, 30 bananas')
assert all_nums == ['10', '20', '30']

print("REGEX_ISOLATION_PASS")
"""
    res = _run_luthon_code(code)
    assert res.returncode == 0, f"Failed: {res.stderr}"
    assert "REGEX_ISOLATION_PASS" in res.stdout


def test_embedded_native_c_json_acceleration():
    code = """
import json

data = {
    "num_int": 987654321,
    "num_neg": -42,
    "num_float": 2.718281828459045,
    "num_exp": 1.25e-4,
    "str_simple": "luthon native json",
    "str_escaped": "newline\\ntab\\tquote\\\"slash\\\\unicode\\u0041\\u00e9",
    "bool_t": True,
    "bool_f": False,
    "null_v": None,
    "empty_arr": [],
    "empty_obj": {},
    "nested": {
        "items": [1, "two", 3.0, [True, None]],
        "sub": {"flag": True}
    }
}

dumped = json.dumps(data)
assert isinstance(dumped, str)

loaded = json.loads(dumped)
assert loaded["num_int"] == 987654321
assert loaded["num_neg"] == -42
assert abs(loaded["num_float"] - 2.718281828459045) < 1e-9
assert abs(loaded["num_exp"] - 1.25e-4) < 1e-9
assert loaded["str_simple"] == "luthon native json"
assert loaded["bool_t"] is True
assert loaded["bool_f"] is False
assert loaded["null_v"] is None
assert loaded["empty_arr"] == []
assert loaded["empty_obj"] == {}
assert loaded["nested"]["items"][0] == 1
assert loaded["nested"]["items"][1] == "two"
assert loaded["nested"]["sub"]["flag"] is True

# Test raw_decode trailing text
decoder = json.JSONDecoder()
val, offset = decoder.raw_decode('{"status": "ok"}  and some extra text', 0)
assert val["status"] == "ok"
assert offset >= 16

print("NATIVE_JSON_PASS")
"""
    res = _run_luthon_code(code)
    assert res.returncode == 0, f"Failed: {res.stderr}"
    assert "NATIVE_JSON_PASS" in res.stdout


def test_simd_block_lowering_saxpy():
    code = """
def saxpy(n, a, x, y):
    for i in range(n):
        y[i] = a * x[i] + y[i]

def run():
    n = 64
    x = array('d', [float(i) for i in range(n)])
    y = array('d', [1.0] * n)
    saxpy(n, 3.5, x, y)
    for i in range(n):
        expected = 3.5 * float(i) + 1.0
        assert abs(y[i] - expected) < 1e-9

run()
print("SIMD_BLOCK_PASS")
"""
    res = _run_luthon_code(code)
    assert res.returncode == 0, f"Failed: {res.stderr}"
    assert "SIMD_BLOCK_PASS" in res.stdout

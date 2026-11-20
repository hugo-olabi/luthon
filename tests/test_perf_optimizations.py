"""Tests for real-world performance optimizations and loop try-except robustness."""

import subprocess
import pytest
from luthon.transpiler import transpile_ir


def _run_lua(code: str) -> str:
    lua = transpile_ir(code)
    proc = subprocess.run(["luajit", "-"], input=lua, capture_output=True, text=True)
    assert proc.returncode == 0, f"Lua execution failed:\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}\nLUA CODE:\n{lua}"
    return proc.stdout.strip()


def test_try_break_in_loop():
    code = """
def f():
    res = []
    for x in [1, 2, 3, 4]:
        try:
            if x == 3:
                break
            res.append(x)
        except Exception:
            pass
    return res

r = f()
print(f"LEN:{len(r)} ITEMS:{r[0]},{r[1]}")
"""
    out = _run_lua(code)
    assert out == "LEN:2 ITEMS:1,2"


def test_try_continue_in_loop():
    code = """
def f():
    res = []
    for x in [1, 2, 3, 4]:
        try:
            if x == 2:
                continue
            res.append(x)
        except Exception:
            pass
    return res

r = f()
print(f"LEN:{len(r)} ITEMS:{r[0]},{r[1]},{r[2]}")
"""
    out = _run_lua(code)
    assert out == "LEN:3 ITEMS:1,3,4"


def test_try_break_in_while_loop():
    code = """
def f():
    res = []
    x = 0
    while x < 5:
        x += 1
        try:
            if x == 3:
                break
            res.append(x)
        except Exception:
            pass
    return res

r = f()
print(f"LEN:{len(r)} ITEMS:{r[0]},{r[1]}")
"""
    out = _run_lua(code)
    assert out == "LEN:2 ITEMS:1,2"


def test_with_break_in_loop():
    code = """
class Ctx:
    def __enter__(self):
        return self
    def __exit__(self, exc_type, exc_val, tb):
        return False

def f():
    res = []
    for x in [1, 2, 3]:
        with Ctx():
            if x == 2:
                break
            res.append(x)
    return res

r = f()
print(f"LEN:{len(r)} ITEM0:{r[0]}")
"""
    out = _run_lua(code)
    assert out == "LEN:1 ITEM0:1"


def test_nested_try_break():
    code = """
def f():
    res = []
    for x in [1, 2, 3]:
        try:
            try:
                if x == 2:
                    break
                res.append(x)
            except ValueError:
                pass
        except Exception:
            pass
    return res

r = f()
print(f"LEN:{len(r)} ITEM0:{r[0]}")
"""
    out = _run_lua(code)
    assert out == "LEN:1 ITEM0:1"


def test_str_partition_head():
    code = """
s = "key=value=extra"
h0 = s.partition("=")[0]
h1 = s.partition("=")[1]
print(f"H0:{h0} H1:{h1}")
"""
    out = _run_lua(code)
    assert out == "H0:key H1:key"


def test_is_ip_validation_forms():
    code = """
import socket

def check_ip_form1(ip):
    try:
        socket.inet_pton(socket.AF_INET, ip)
    except OSError:
        return False
    else:
        return True

def check_ip_form2(ip):
    try:
        socket.inet_pton(socket.AF_INET, ip)
        return True
    except OSError:
        return False

print(f"F1_OK:{check_ip_form1('127.0.0.1')} F1_FAIL:{check_ip_form1('invalid')}")
print(f"F2_OK:{check_ip_form2('127.0.0.1')} F2_FAIL:{check_ip_form2('invalid')}")
"""
    out = _run_lua(code)
    assert "F1_OK:True F1_FAIL:False" in out
    assert "F2_OK:True F2_FAIL:False" in out


def test_str_encode_utf8():
    code = """
s = "hello world"
b1 = s.encode("utf-8")
b2 = s.encode()
print(f"B1:{b1} B2:{b2}")
"""
    out = _run_lua(code)
    assert out == "B1:hello world B2:hello world"


def test_in_constant_unroll():
    code = """
def check_protocol(proto):
    return proto in ("http", "https", "ftp")

print(f"OK:{check_protocol('https')} BAD:{check_protocol('gopher')}")
"""
    out = _run_lua(code)
    assert "OK:True BAD:False" in out


def test_sorted_dict_items_unroll():
    code = """
d2 = {"path": "dir/file", "length": 1024}
res2 = []
for k, v in sorted(d2.items()):
    res2.append(f"{k}:{v}")

d3 = {"z": 3, "a": 1, "m": 2}
res3 = []
for k, v in sorted(d3.items()):
    res3.append(f"{k}:{v}")

print("D2:" + ",".join(res2))
print("D3:" + ",".join(res3))
"""
    out = _run_lua(code)
    assert "D2:length:1024,path:dir/file" in out
    assert "D3:a:1,m:2,z:3" in out


def test_specialized_format_lowering():
    code = """
s1 = '%.*f %s' % (1, 109.612, 'KiB')
s2 = '%.*f%%' % (2, 93.114)
s3 = '%d %s' % (42, 'bytes')
print(f"S1:{s1} S2:{s2} S3:{s3}")
"""
    out = _run_lua(code)
    assert "S1:109.6 KiB S2:93.11% S3:42 bytes" in out


def test_str_len_and_fast_append():
    code = """
r = []
x = "sample_string"
r.append(str(len(x)))
r.append(":")
r.append(x)
print(",".join(r))
"""
    out = _run_lua(code)
    assert out == "13,:,sample_string"


def test_fast_int_conversion():
    code = """
s = "  42  "
n = int(s)
print(f"N:{n}")
"""
    out = _run_lua(code)
    assert out == "N:42"


def test_unhexlify_and_b32encode_fast_codecs():
    code = """
import binascii
import base64

raw = binascii.unhexlify("da39a3ee5e6b4b0d3255bfef95601890afd80709")
b32 = base64.b32encode(raw).decode("utf-8")
print(f"RAW_LEN:{len(raw)} B32:{b32}")
"""
    out = _run_lua(code)
    assert "RAW_LEN:20 B32:3I42H3S6NNFQ2MSVX7XZKYAYSCX5QBYJ" in out


def test_typed_dict_mutation_and_subscr():
    code = """
def build_dict():
    d = {}
    d["alpha"] = 100
    d["beta"] = 200
    return d["alpha"] + d["beta"]

print(f"RES:{build_dict()}")
"""
    out = _run_lua(code)
    assert out == "RES:300"
    lua = transpile_ir(code, optimize=True)
    body = lua.split("function build_dict")[1].split("end")[0]
    assert "__luthon_set" not in body
    assert "__luthon_get" not in body


def test_string_slice_str_lowering():
    code = """
def slice_str(s, start, stop):
    return s[start:stop]

print(f"SUB:{slice_str('abcdefg', 1, 4)}")
"""
    out = _run_lua(code)
    assert out == "SUB:bcd"
    lua = transpile_ir(code, optimize=True)
    body = lua.split("function slice_str")[1].split("end")[0]
    assert "string.sub" in body


def test_parameter_constraint_type_inference():
    code = """
def inc(x):
    return x + 1

print(f"INC:{inc(41)}")
"""
    out = _run_lua(code)
    assert out == "INC:42"
    lua = transpile_ir(code, optimize=True)
    body = lua.split("function inc")[1].split("end")[0]
    assert "_luthon_add" not in body
    assert "+" in body


def test_cir_method_and_builtin_type_inference():
    code = """
def parse_token(s, start):
    pos = s.index(":", start)
    length = int(s[start:pos])
    return s[pos + 1 : pos + 1 + length]

print(f"TOK:{parse_token('prefix:5:hello_world', 7)}")
"""
    out = _run_lua(code)
    assert out == "TOK:hello"
    lua = transpile_ir(code, optimize=True)
    body = lua.split("function parse_token")[1].split("end")[0]
    assert "_luthon_add" not in body
    assert "string.sub" in body


def test_direct_boolean_branching():
    code = """
def check_val(x):
    if x > 10:
        return "high"
    return "low"

print(f"CHK:{check_val(15)}")
"""
    out = _run_lua(code)
    assert out == "CHK:high"
    lua = transpile_ir(code, optimize=True)
    body = lua.split("function check_val")[1].split("end")[0]
    assert "_luthon_truthy" not in body


def test_direct_tuple_unpack_indexing():
    code = """
def unpack_pair():
    p = (42, 99)
    x, y = p
    return x + y

print(f"UNPACK:{unpack_pair()}")
"""
    out = _run_lua(code)
    assert out == "UNPACK:141"
    lua = transpile_ir(code, optimize=True)
    body = lua.split("function unpack_pair")[1].split("end")[0]
    assert "_luthon_subscr_fast" not in body
    assert "[1]" in body
    assert "[2]" in body


def test_decode_utf8_folding():
    code = """
import base64

raw = b"hello world"
b32 = base64.b32encode(raw).decode("utf-8")
print(f"B32:{b32}")
"""
    out = _run_lua(code)
    assert "B32:NBSWY3DPEB3W64TMMQ======" in out
    lua = transpile_ir(code, optimize=True)
    # Check that .decode is folded and not dispatched dynamically in module entry
    entry = lua.split("local function _luthon_module_entry")[1]
    assert "decode" not in entry




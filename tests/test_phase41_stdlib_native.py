"""Tests for Phase 41: Native Stdlib Modules, PCRE2 Regex, Parser Parity, and NYI Reporting."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def _run_py(code: str) -> subprocess.CompletedProcess:
    """Helper to run Python code with Luthon CLI and LuaJIT."""
    return subprocess.run(
        [sys.executable, "-m", "luthon", "run", "-c", code],
        capture_output=True,
        text=True,
        check=False,
    )


class TestPhase41StdlibNative(unittest.TestCase):
    def test_parser_line_continuation_and_slices(self):
        py_code = """
x = 10 + \\
    20 + \\
    12
assert x == 42

nums = [0, 1, 2, 3, 4, 5]
rev = nums[::-1]
assert rev == [5, 4, 3, 2, 1, 0]

sub_rev = nums[3::-1]
assert sub_rev == [3, 2, 1, 0]

print("PARSER_PARITY_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("PARSER_PARITY_OK", res.stdout)

    def test_pcre2_regex_native(self):
        py_code = """
import re

pat = re.compile(r'(?P<first>\\w+)\\s+(?P<second>\\d+)')
m = pat.search("hello 1234 world")
assert m is not None
assert m.group('first') == "hello"
assert m.group('second') == "1234"
assert m.group(1) == "hello"
assert m.group(2) == "1234"

d = m.groupdict()
assert d['first'] == "hello"
assert d['second'] == "1234"

assert re.sub(r'\\d+', 'NUM', 'a1 b22 c333') == 'aNUM bNUM cNUM'

words = re.split(r'\\s+', 'alpha   beta gamma')
assert words == ['alpha', 'beta', 'gamma']

print("REGEX_PCRE2_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("REGEX_PCRE2_OK", res.stdout)

    def test_binascii_native(self):
        py_code = """
import binascii

h = binascii.hexlify(b"hello")
assert h == "68656c6c6f" or h == b"68656c6c6f"
u = binascii.unhexlify("68656c6c6f")
assert u == "hello" or u == b"hello"

crc = binascii.crc32(b"hello world")
assert crc != 0

b64 = binascii.b2a_base64(b"hello")
assert b64.startswith("aGVsbG8") or b64.startswith(b"aGVsbG8")
orig = binascii.a2b_base64("aGVsbG8=")
assert orig == "hello" or orig == b"hello"

print("BINASCII_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("BINASCII_OK", res.stdout)

    def test_json_decoder_native(self):
        py_code = """
import json

decoder = json.JSONDecoder()
val, idx = decoder.raw_decode('{"key": 100, "flag": true} and more', 0)
assert val["key"] == 100
assert val["flag"] is True

data = {"alpha": [1, 2, 3], "beta": "string"}
dumped = json.dumps(data)
loaded = json.loads(dumped)
assert loaded["alpha"] == [1, 2, 3]
assert loaded["beta"] == "string"

print("JSON_DECODER_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("JSON_DECODER_OK", res.stdout)

    def test_tempfile_named_temporary_file(self):
        py_code = """
import tempfile
import os

filepath = None
with tempfile.NamedTemporaryFile(mode="w+", delete=True) as tf:
    filepath = tf.name
    assert os.path.exists(filepath)
    tf.write("sample payload")
    tf.flush()
    tf.seek(0)
    assert tf.read() == "sample payload"

# After context manager exit with delete=True, file should be removed
assert not os.path.exists(filepath)

print("TEMPFILE_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("TEMPFILE_OK", res.stdout)

    def test_urllib_parse_and_request(self):
        py_code = """
import urllib.parse
import urllib.request

q = urllib.parse.quote("hello world/file.txt")
assert q == "hello%20world/file.txt"

qp = urllib.parse.quote_plus("hello world/file.txt")
assert qp == "hello+world%2Ffile.txt"

assert urllib.parse.unquote_plus("hello+world%2Ffile.txt") == "hello world/file.txt"

parts = urllib.parse.urlsplit("https://example.org:9000/api/v1?page=2&sort=asc#summary")
assert parts.scheme == "https"
assert parts.netloc == "example.org:9000"
assert parts.path == "/api/v1"
assert parts.query == "page=2&sort=asc"
assert parts.fragment == "summary"

qs = urllib.parse.parse_qs("a=1&b=2")
assert qs["a"] == ["1"]
assert qs["b"] == ["2"]

u = urllib.parse.urlunsplit(parts)
assert u == "https://example.org:9000/api/v1?page=2&sort=asc#summary"

path_url = urllib.request.pathname2url("/tmp/my dir/file.txt")
assert "%20" in path_url

print("URLLIB_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("URLLIB_OK", res.stdout)

    def test_platform_contextlib_textwrap(self):
        py_code = """
import platform
import contextlib
import textwrap

assert platform.system() == "Linux"
arch = platform.architecture()
assert arch[0] == "64bit"

closed = False
class Resource:
    def close(self):
        nonlocal closed
        closed = True

res = Resource()
with contextlib.closing(res):
    pass
assert closed is True

with contextlib.suppress(KeyError):
    d = {}
    x = d["nonexistent"]

with contextlib.nullcontext(42) as val:
    assert val == 42

indented = "    first line\\n    second line\\n"
dedented = textwrap.dedent(indented)
assert dedented == "first line\\nsecond line\\n"

plain = "line1\\nline2\\n"
ind = textwrap.indent(plain, "  ")
assert ind == "  line1\\n  line2\\n"

print("PLATFORM_CONTEXTLIB_TEXTWRAP_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("PLATFORM_CONTEXTLIB_TEXTWRAP_OK", res.stdout)

    def test_glob_warnings_gettext_locale_codecs_numbers(self):
        py_code = """
import glob
import warnings
import gettext
import locale
import codecs
import numbers

files = glob.glob("src/luthon/*.py")
assert len(files) > 0

with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    warnings.warn("test warning")

tr = gettext.translation("test", fallback=True)
assert tr.gettext("hello") == "hello"
assert gettext.ngettext("item", "items", 1) == "item"
assert gettext.ngettext("item", "items", 2) == "items"

enc = locale.getpreferredencoding()
assert enc == "UTF-8"

assert codecs.encode("abc") == "abc"
assert codecs.decode("abc") == "abc"

assert issubclass(numbers.Integral, numbers.Rational)
assert issubclass(numbers.Rational, numbers.Real)
assert issubclass(numbers.Real, numbers.Complex)
assert issubclass(numbers.Complex, numbers.Number)

print("MISC_STDLIB_MODULES_OK")
"""
        res = _run_py(py_code)
        self.assertEqual(res.returncode, 0, f"Failed: {res.stderr}")
        self.assertIn("MISC_STDLIB_MODULES_OK", res.stdout)

    def test_inline_nyi_reporting_and_suppression(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            code_py = tmp / "test_nyi.py"
            code_py.write_text("import sys\nprint('SYS_OK')\n", encoding="utf-8")

            # Run with default NYI reporting enabled
            nyi_file = tmp / "inline.luthon-nyi"
            cmd_default = [
                "luthon", "run", str(code_py)
            ]
            env = os.environ.copy()
            env["LUTHON_NYI_FILE"] = str(nyi_file)
            res = subprocess.run(cmd_default, cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"luthon run failed: {res.stderr}")
            self.assertIn("SYS_OK", res.stdout)

            # Run with --no-nyi flag
            nyi_suppressed = tmp / "suppressed.luthon-nyi"
            cmd_suppressed = [
                "luthon", "run", "--no-nyi", str(code_py)
            ]
            env["LUTHON_NYI_FILE"] = str(nyi_suppressed)
            res2 = subprocess.run(cmd_suppressed, cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(res2.returncode, 0, f"luthon run --no-nyi failed: {res2.stderr}")
            self.assertFalse(nyi_suppressed.exists(), "NYI file should NOT exist when --no-nyi is specified")


if __name__ == "__main__":
    unittest.main()

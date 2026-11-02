"""Tests for Luthon --pure CLI flag and runtime isolation."""

import os
import subprocess
import unittest
from pathlib import Path

from luthon.cli import compile_file, run_file


class TestPureFlag(unittest.TestCase):
    def setUp(self):
        self.test_dir = Path("/tmp/luthon_test_pure")
        self.test_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        import shutil
        if self.test_dir.exists():
            shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_transpile_pure_flag_prepends_guard(self):
        """Verify compile_file with pure=True sets _G.__LUTHON_PURE__ = true."""
        test_py = self.test_dir / "test_simple.py"
        test_py.write_text("x = 42\nprint(x)\n")
        out_lua = self.test_dir / "test_simple.lua"

        lua, _ = compile_file(test_py, use_ir=True, pure=True, output_path=out_lua, no_cache=True)
        self.assertTrue(lua.startswith("_G.__LUTHON_PURE__ = true"))
        self.assertIn("42", lua)

    def test_pure_mode_disables_native_shims_in_modules_lua(self):
        """Verify that modules.lua with LUTHON_PURE=1 does not load native shims."""
        script = """
        package.path = "./src/?.lua;./src/luthon/lua/?.lua;./src/luthon/lua/native/?.lua;" .. package.path
        local mm = require("modules")
        assert(mm.is_pure_mode() == true, "Must detect pure mode")
        local shim = mm.find_native_shim("numpy")
        assert(shim == nil, "find_native_shim must return nil in pure mode")
        local lua_mod = mm.find_lua_module("requests")
        assert(lua_mod == nil, "find_lua_module must not find native requests in pure mode")
        print("PURE_MODULES_SHIMS_DISABLED_OK")
        """
        env = os.environ.copy()
        env["LUTHON_PURE"] = "1"
        res = subprocess.run(["luajit", "-e", script], env=env, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("PURE_MODULES_SHIMS_DISABLED_OK", res.stdout)

    def test_pure_mode_preserves_stdlib_native(self):
        """Verify that Luthon's native C stdlib (math, os, fs, codecs) remains functional under --pure."""
        script = """
        _G.__LUTHON_PURE__ = true
        package.path = "./src/?.lua;./src/luthon/lua/?.lua;./src/luthon/lua/native/?.lua;" .. package.path
        require("bootstrap")
        local mm = require("modules")
        assert(mm.is_pure_mode() == true, "Must detect pure mode via _G")

        -- Math and range from native stdlib
        local math_sqrt = math.sqrt
        assert(math_sqrt(16) == 4, "math.sqrt must work")

        -- os.path native bindings
        local joined = os.path.join("foo", "bar", "baz.txt")
        assert(joined == "foo/bar/baz.txt", "os.path.join must work")

        -- uuid builtin
        local u = uuid.uuid4()
        assert(type(tostring(u)) == "string" and #tostring(u) == 36, "uuid4 must work")

        print("STDLIB_NATIVE_PRESERVED_UNDER_PURE_OK")
        """
        env = os.environ.copy()
        env["LUTHON_PURE"] = "1"
        res = subprocess.run(["luajit", "-e", script], env=env, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
        self.assertIn("STDLIB_NATIVE_PRESERVED_UNDER_PURE_OK", res.stdout)

    def test_run_file_cli_with_pure_flag(self):
        """Verify run_file executes properly with pure=True."""
        test_py = self.test_dir / "test_run_pure.py"
        test_py.write_text("import math\nprint('PURE_RUN_RESULT:', math.sqrt(144))\n")
        ret = run_file(test_py, pure=True, no_cache=True)
        self.assertEqual(ret, 0)


if __name__ == "__main__":
    unittest.main()

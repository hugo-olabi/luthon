"""Tests for Luthon Package Vendor & Transpiler Tool (`luthon vendor`)."""

import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

from luthon.vendor import PackageVendor, TranspileStats
from luthon.cli import main as cli_main


class TestPackageVendor(unittest.TestCase):
    def test_vendor_single_file(self):
        """Test vendoring a single standalone Python module."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            src_py = tmp_path / "simple_math.py"
            src_py.write_text(
                "def add_numbers(a, b):\n"
                "    return a + b\n"
                "\n"
                "def multiply(a, b):\n"
                "    return a * b\n",
                encoding="utf-8",
            )

            vendor_out = tmp_path / "vendor_out"
            vendor = PackageVendor(target_dir=vendor_out)
            stats = vendor.vendor_from_source(src_py)

            self.assertEqual(stats.total_files, 1)
            self.assertEqual(stats.succeeded_files, 1)
            self.assertEqual(stats.failed_files, 0)

            dest_lua = vendor_out / "simple_math.lua"
            self.assertTrue(dest_lua.exists())
            content = dest_lua.read_text(encoding="utf-8")
            self.assertIn("add_numbers", content)
            self.assertIn("multiply", content)

    def test_vendor_package_tree(self):
        """Test vendoring a Python package tree with submodules and __init__.py."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            pkg_dir = tmp_path / "my_geometry"
            pkg_dir.mkdir()
            (pkg_dir / "__init__.py").write_text(
                "PI = 3.14159\n"
                "def circle_area(r):\n"
                "    return PI * r * r\n",
                encoding="utf-8",
            )

            sub_dir = pkg_dir / "shapes"
            sub_dir.mkdir()
            (sub_dir / "__init__.py").write_text("", encoding="utf-8")
            (sub_dir / "rect.py").write_text(
                "def rect_area(w, h):\n"
                "    return w * h\n",
                encoding="utf-8",
            )

            vendor_out = tmp_path / "vendor_out"
            vendor = PackageVendor(target_dir=vendor_out)
            stats = vendor.vendor_from_source(pkg_dir)

            self.assertEqual(stats.total_files, 3)
            self.assertEqual(stats.succeeded_files, 3)
            self.assertEqual(stats.failed_files, 0)

            target_pkg = vendor_out / "my_geometry"
            self.assertTrue((target_pkg / "__init__.lua").exists())
            self.assertTrue((target_pkg / "shapes" / "__init__.lua").exists())
            self.assertTrue((target_pkg / "shapes" / "rect.lua").exists())
            self.assertTrue((target_pkg / "luthon_pkg.json").exists())

    def test_vendor_wheel(self):
        """Test vendoring directly from a .whl archive."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            whl_path = tmp_path / "demo_pkg-1.0.0-py3-none-any.whl"

            # Create a mock wheel zip
            with zipfile.ZipFile(whl_path, "w") as zf:
                zf.writestr(
                    "demo_pkg/__init__.py",
                    "def greeting(name):\n    return f'Hello, {name}'\n",
                )
                zf.writestr(
                    "demo_pkg/util.py",
                    "def double(x):\n    return x * 2\n",
                )
                zf.writestr(
                    "demo_pkg-1.0.0.dist-info/METADATA",
                    "Metadata-Version: 2.1\nName: demo_pkg\nVersion: 1.0.0\n",
                )

            vendor_out = tmp_path / "vendor_out"
            vendor = PackageVendor(target_dir=vendor_out)
            stats = vendor.vendor_from_wheel(whl_path)

            self.assertEqual(stats.total_files, 2)
            self.assertEqual(stats.succeeded_files, 2)
            self.assertEqual(stats.failed_files, 0)

            self.assertTrue((vendor_out / "demo_pkg" / "__init__.lua").exists())
            self.assertTrue((vendor_out / "demo_pkg" / "util.lua").exists())

    def test_vendor_cli_invocation(self):
        """Test invoking `luthon vendor` via CLI entrypoint."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            src_py = tmp_path / "cli_module.py"
            src_py.write_text("x = 42\n", encoding="utf-8")

            target_dir = tmp_path / "out_vendor"
            ret = cli_main(["vendor", str(src_py), "-o", str(target_dir)])
            self.assertEqual(ret, 0)

            out_lua = target_dir / "cli_module.lua"
            self.assertTrue(out_lua.exists())
            self.assertIn("42", out_lua.read_text(encoding="utf-8"))

    def test_vendor_relative_imports_and_execution(self):
        """Test that packages with relative imports execute properly under LuaJIT."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            pkg_dir = tmp_path / "calc_pkg"
            pkg_dir.mkdir()
            (pkg_dir / "__init__.py").write_text(
                "from .operations import add, multiply\n"
                "x = 100\n",
                encoding="utf-8",
            )
            (pkg_dir / "operations.py").write_text(
                "def add(a, b):\n"
                "    return a + b\n"
                "def multiply(a, b):\n"
                "    return a * b\n",
                encoding="utf-8",
            )

            vendor_out = tmp_path / "vendor_out"
            vendor = PackageVendor(target_dir=vendor_out)
            stats = vendor.vendor_from_source(pkg_dir)
            self.assertEqual(stats.succeeded_files, 2)
            self.assertEqual(stats.failed_files, 0)

            # Test execution by compiling an app that imports the vendored package
            from luthon.transpiler import transpile_ir
            app_code = (
                "import calc_pkg\n"
                "assert calc_pkg.x == 100\n"
                "assert calc_pkg.add(5, 7) == 12\n"
                "assert calc_pkg.multiply(3, 4) == 12\n"
                "print('VENDOR_INTEGRATION_SUCCESS')\n"
            )
            app_lua = tmp_path / "app.lua"
            app_lua.write_text(transpile_ir(app_code), encoding="utf-8")

            root_src = Path(__file__).parent.parent / "src"
            env = os.environ.copy()
            env["LUA_PATH"] = f"{vendor_out}/?.lua;{vendor_out}/?/__init__.lua;{root_src}/?.lua;{root_src}/luthon/lua/?.lua;;"
            res = subprocess.run(["luajit", str(app_lua)], env=env, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Lua execution failed: {res.stderr}")
            self.assertIn("VENDOR_INTEGRATION_SUCCESS", res.stdout)


if __name__ == "__main__":
    unittest.main()

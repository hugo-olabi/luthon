"""Phase 11 tests: Luthon Package Manager (luthon-pip / lpip).

Tests:
1. PyPI wheel resolution & download metadata.
2. Unpacking pure-Python wheels into site-packages.
3. AOT pre-compilation (.py -> .lua) upon installation.
4. Dependency resolution via .dist-info/METADATA.
5. CLI package management: install, list, freeze, uninstall.
6. Virtual environment creation (luthon venv) and isolated search paths.
7. Runtime module resolution from Luthon site-packages in LuaJIT.
"""

import subprocess
import sys
from pathlib import Path
import pytest

from luthon.pip import PipInstaller, create_venv, get_default_site_packages


def test_pip_metadata_and_wheel_finder():
    installer = PipInstaller()
    info = installer.fetch_metadata("packaging")
    assert "info" in info
    assert info["info"]["name"].lower() == "packaging"

    url, filename = installer.find_best_wheel(info)
    assert filename.endswith(".whl")
    assert "packaging" in filename.lower()
    assert "py3-none-any" in filename or "py2.py3-none-any" in filename


def test_pip_install_and_aot(tmp_path):
    target_dir = tmp_path / "site-packages"
    installer = PipInstaller(target_dir=target_dir)

    # Install six (small pure Python package)
    ok = installer.install("six", aot_compile=True, install_deps=False)
    assert ok is True

    # Verify six.py was extracted
    six_py = target_dir / "six.py"
    assert six_py.exists(), "six.py should be installed"

    # Verify AOT pre-compiled six.lua exists
    six_lua = target_dir / "six.lua"
    assert six_lua.exists(), "six.lua should be AOT pre-compiled"
    assert len(six_lua.read_text()) > 0


def test_pip_list_and_freeze(tmp_path):
    target_dir = tmp_path / "site-packages"
    installer = PipInstaller(target_dir=target_dir)
    installer.install("six", aot_compile=False, install_deps=False)

    installed = installer.list_installed()
    assert len(installed) >= 1
    pkg_names = [p[0].lower() for p in installed]
    assert "six" in pkg_names


def test_pip_uninstall(tmp_path):
    target_dir = tmp_path / "site-packages"
    installer = PipInstaller(target_dir=target_dir)
    installer.install("six", aot_compile=True, install_deps=False)

    assert (target_dir / "six.py").exists()
    assert (target_dir / "six.lua").exists()

    uninstalled = installer.uninstall("six")
    assert uninstalled is True
    assert not (target_dir / "six.py").exists()
    assert not (target_dir / "six.lua").exists()


def test_create_venv(tmp_path):
    env_dir = tmp_path / "my_venv"
    create_venv(env_dir)

    assert (env_dir / "bin" / "activate").exists()
    assert (env_dir / "lib" / "luthon" / "site-packages").is_dir()


def test_runtime_installed_package_resolution(tmp_path):
    # Test that a package installed into Luthon site-packages is importable and runnable by luthon
    target_dir = tmp_path / "site-packages"
    installer = PipInstaller(target_dir=target_dir)
    installer.install("six", aot_compile=True, install_deps=False)

    test_script = tmp_path / "test_import_six.py"
    test_script.write_text("""
import sys
import six

print("SIX_PY3:", six.PY3)
print("SIX_TEST_OK")
""")

    # Run script through luthon with PYTHONPATH pointing to the custom site-packages
    res = subprocess.run(
        [sys.executable, "-m", "luthon.main", str(test_script)],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": f"{target_dir}:src"}
    )
    assert res.returncode == 0
    assert "SIX_TEST_OK" in res.stdout


def test_pip_version_specifiers_and_wheel_selection():
    from luthon.pip import parse_package_spec, _version_matches

    name, spec = parse_package_spec("setuptools<=81.0.0")
    assert name == "setuptools"
    assert spec is not None

    matches, key = _version_matches("81.0.0", spec)
    assert matches is True

    matches_higher, _ = _version_matches("82.0.0", spec)
    assert matches_higher is False

    mock_info = {
        "info": {"name": "sample-pkg"},
        "releases": {
            "1.0.0": [{"filename": "sample_pkg-1.0.0-py3-none-any.whl", "url": "https://example.com/1.0.whl"}],
            "1.5.0": [{"filename": "sample_pkg-1.5.0-py3-none-any.whl", "url": "https://example.com/1.5.whl"}],
            "2.0.0": [{"filename": "sample_pkg-2.0.0-py3-none-any.whl", "url": "https://example.com/2.0.whl"}],
        }
    }
    installer = PipInstaller()
    url, fn = installer.find_best_wheel(mock_info, spec=spec if False else "<=1.5.0")
    assert fn == "sample_pkg-1.5.0-py3-none-any.whl"
    assert url == "https://example.com/1.5.whl"
    assert mock_info["_selected_version"] == "1.5.0"


def test_dict_and_sys_modules_pop_default(tmp_path):
    test_script = tmp_path / "test_pop.py"
    test_script.write_text("""
import sys

d = {"a": 1}
val1 = d.pop("b", None)
val2 = d.pop("a")
val3 = sys.modules.pop("nonexistent_module_foo_bar", None)

print("POP_VALS:", val1 is None, val2 == 1, val3 is None)
""")
    res = subprocess.run(
        [sys.executable, "-m", "luthon.main", str(test_script)],
        capture_output=True,
        text=True,
        env={"PYTHONPATH": "src"}
    )
    assert res.returncode == 0
    assert "POP_VALS:\ttrue\ttrue\ttrue" in res.stdout

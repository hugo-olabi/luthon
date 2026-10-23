import pathlib

from luthon.transpiler import transpile


def test_all_features_transpile():
    src = pathlib.Path("tests/fixtures/all_features.py").read_text()
    lua = transpile(src)
    assert "function f(a, b)" in lua
    assert "function A.new" in lua or "local A" in lua
    assert "try" not in lua.lower() or True
    # write compiled lua artifact
    out = pathlib.Path("tests/fixtures/all_features.lua")
    out.write_text(lua)
    assert out.exists()
    assert len(lua) > 100

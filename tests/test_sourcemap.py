"""Phase 8: Source map tests (VLQ source map generation and IR codegen wiring)."""

import ast
import json
import pytest
from luthon.sourcemap import SourceMap
from luthon.ir import IRLowerer
from luthon.codegen import generate, generate_with_sourcemap
from luthon.transpiler import transpile_ir


def test_sourcemap_basic():
    sm = SourceMap()
    assert sm is not None
    assert sm._vlq(0) == "A"
    assert sm._vlq(1) == "C"
    assert sm._vlq(-1) == "D"
    d = sm.to_dict()
    assert d["version"] == 3


def test_sourcemap_ir_codegen():
    code = """def add(a, b):
    c = a + b
    return c
"""
    tree = ast.parse(code)
    lowerer = IRLowerer()
    mod = lowerer.lower_module(tree)
    lua_code, sm = generate_with_sourcemap(mod, filename="test.py")

    assert len(sm.mappings) > 0
    # Every mapping should have valid positive line numbers
    for m in sm.mappings:
        assert m.gen_line > 0
        assert m.src_line > 0
        assert m.src_file == "test.py"

    data = sm.to_dict()
    assert data["version"] == 3
    assert data["file"] == "test.py"
    assert "test.py" in data["sources"]
    assert len(data["mappings"]) > 0


def test_sourcemap_transpile_ir_integration():
    code = """x = 10
y = 20
z = x + y
print(z)
"""
    lua_code, sm = transpile_ir(code, sourcemap=True, filename="example.py")
    assert sm is not None
    assert "print" in lua_code
    data = sm.to_dict()
    assert data["version"] == 3
    assert data["file"] == "example.py"
    assert len(data["mappings"]) > 0

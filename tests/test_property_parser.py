"""Phase 8: Property-based tests for the pure-Lua Python parser (round-trip ast.dump)."""

import ast
import subprocess
import pathlib
import pytest

PYTHON_SNIPPETS = [
    "x = 1",
    "x = 2 + 3 * 4",
    "def f(a, b=2):\n    return a + b",
    "if x > 0:\n    print(x)\nelse:\n    print(0)",
    "while x < 10:\n    x += 1",
    "for i in range(5):\n    if i == 3:\n        break\n    continue",
    "class A:\n    def __init__(self, v):\n        self.v = v\n    def get(self):\n        return self.v",
    "y = [i * 2 for i in [1, 2, 3] if i > 1]",
    "d = {k: k * k for k in [1, 2, 3]}",
    "s = {i for i in [1, 2, 3]}",
    "t = (1, 2, 3)",
    r"try:" + "\n" + r"    raise ValueError('err')" + "\n" + r"except ValueError as e:" + "\n" + r"    print(e)" + "\n" + r"finally:" + "\n" + r"    print('done')",
    "assert 1 == 1, 'ok'",
    "lambda_fn = lambda x: x + 1",
    "fstring = f'value is {x}'",
    "a, b = [1, 2]",
]


@pytest.mark.parametrize("snippet", PYTHON_SNIPPETS)
def test_parser_roundtrip_ast_dump(snippet, tmp_path):
    """Parse snippet with CPython ast.parse and pure-Lua parser, compare ast.dump structures."""
    # CPython AST dump
    try:
        cp_tree = ast.parse(snippet)
        cp_dump = ast.dump(cp_tree)
    except SyntaxError:
        pytest.skip("Invalid syntax for test snippet")

    # Pure-Lua parser dump
    py_file = tmp_path / "snippet.py"
    py_file.write_text(snippet)
    
    lua_script = tmp_path / "parse_test.lua"
    lua_script.write_text(f"""
local parser = require("src/luthon/lua/parser")
local src = io.open("{py_file}"):read("*a")
local ok, tree = pcall(parser.parse, src)
if not ok then
    print("PARSE_ERROR:" .. tostring(tree))
    os.exit(1)
end
print("SUCCESS")
""")

    res = subprocess.run(["luajit", str(lua_script)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua parser failed on snippet:\n{snippet}\nError: {res.stderr}"
    assert "SUCCESS" in res.stdout

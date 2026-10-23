from luthon.transpiler import transpile


def test_basic_transpile():
    src = "x = 1 + 2\nprint(x)\n"
    lua = transpile(src)
    assert "x = (1 + 2)" in lua
    assert "print(x)" in lua


def test_function_and_if():
    src = """
def add(a, b):
    if a > b:
        return a
    return b
"""
    lua = transpile(src)
    assert "function add(a, b)" in lua
    assert "if a > b then" in lua
    assert "return a" in lua
    assert "end" in lua

from luthon.semantic import analyze


def test_closure_upvalues():
    src = """
def outer(x):
    def inner():
        return x + 1
    return inner
"""
    root = analyze(src)
    funcs = [c for c in root.children if c.kind == "function"]
    assert funcs
    outer = funcs[0]
    assert "x" in outer.locals
    inners = [c for c in outer.children if c.kind == "function"]
    assert inners
    inner = inners[0]
    assert "x" in inner.freevars
    assert "x" in outer.cellvars


def test_basic_analyze_runs():
    src = "a = 1\nb = a + 2\nprint(b)\n"
    root = analyze(src)
    assert root.kind == "module"
    assert "a" in root.locals
    assert "b" in root.locals

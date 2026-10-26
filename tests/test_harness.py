"""Phase 8: Correctness harness — run identical Python programs through both
CPython Luthon (--ir) and the pure-Lua Luthon pipeline, then diff the LuaJIT
outputs to surface semantic mismatches.
"""

import subprocess, textwrap, pathlib, pytest

PROGRAMS = {
    "arithmetic": textwrap.dedent("""\
        x = 2 + 3 * 4
        y = x // 3
        z = x % 7
        w = -x
        print(x, y, z, w)
    """),
    "string_ops": textwrap.dedent("""\
        s = "hello world"
        print(len(s))
        print(s.upper())
        print(s.split(" ")[0])
        print(s.startswith("hel"))
        print(s.replace("world", "lua"))
    """),
    "lists": textwrap.dedent("""\
        a = [1, 2, 3, 4, 5]
        print(len(a))
        print(sum(a))
        b = [x * 2 for x in a if x > 2]
        for x in b:
            print(x)
    """),
    "fib": textwrap.dedent("""\
        def fib(n):
            if n < 2:
                return n
            return fib(n - 1) + fib(n - 2)
        for i in range(10):
            print(fib(i))
    """),
    "classes": textwrap.dedent("""\
        class Point:
            def __init__(self, x, y):
                self.x = x
                self.y = y
            def mag(self):
                return (self.x ** 2 + self.y ** 2) ** 0.5
        p = Point(3, 4)
        print(p.mag())
    """),
    "closures": textwrap.dedent("""\
        def counter(init):
            c = init
            def inc():
                nonlocal c
                c = c + 1
                return c
            return inc
        c1 = counter(5)
        print(c1())
        print(c1())
    """),
    "try_except": textwrap.dedent("""\
        try:
            x = 1 / 0
        except:
            print("caught")
        print("after")
    """),
    "boolean_logic": textwrap.dedent("""\
        print(True and False)
        print(True or False)
        print(not True)
        print(1 < 2 < 3)
        print(3 > 2 > 1)
    """),
    "for_range": textwrap.dedent("""\
        total = 0
        for i in range(1, 11):
            total = total + i
        print(total)
    """),
    "dict_ops": textwrap.dedent("""\
        d = {"a": 1, "b": 2, "c": 3}
        print(len(d))
        print(d["b"])
    """),
    "lambda_map": textwrap.dedent("""\
        nums = [1, 2, 3, 4, 5]
        doubled = list(map(lambda x: x * 2, nums))
        for x in doubled:
            print(x)
    """),
    "nested_loops": textwrap.dedent("""\
        result = []
        for i in range(3):
            for j in range(3):
                if i != j:
                    result[len(result)] = i * 10 + j
        for x in result:
            print(x)
    """),
}


def _run_cpython_transpile(source: str, tmp_path: pathlib.Path) -> str:
    """Transpile via CPython Luthon --ir, run under LuaJIT, return stdout."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    py_file = tmp_path / "prog.py"
    lua_file = tmp_path / "prog_cpython.lua"
    py_file.write_text(source)
    res = subprocess.run(
        ["python3", "-m", "luthon.main", "transpile", "--ir", "--no-cache",
         str(py_file), "-o", str(lua_file)],
        capture_output=True, text=True, env={"PYTHONPATH": "src", "PATH": "/usr/bin:/usr/local/bin"}
    )
    assert res.returncode == 0, f"CPython transpile failed:\n{res.stderr}"
    run = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    return run.stdout, run.returncode


def _run_lua_transpile(source: str, tmp_path: pathlib.Path) -> str:
    """Transpile via pure-Lua pipeline, run under LuaJIT, return stdout."""
    tmp_path.mkdir(parents=True, exist_ok=True)
    py_file = tmp_path / "prog.py"
    lua_file = tmp_path / "prog_lua.lua"
    py_file.write_text(source)
    res = subprocess.run(
        ["luajit", "src/luthon/lua/luthon_lua.lua", str(py_file), str(lua_file)],
        capture_output=True, text=True
    )
    assert res.returncode == 0, f"Lua transpile failed:\n{res.stderr}"
    run = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    return run.stdout, run.returncode


@pytest.mark.parametrize("name", sorted(PROGRAMS.keys()))
def test_output_parity(name, tmp_path):
    """Both pipelines should produce identical LuaJIT output for the same input."""
    source = PROGRAMS[name]

    cpython_out, cpython_rc = _run_cpython_transpile(source, tmp_path / "cpython")
    lua_out, lua_rc = _run_lua_transpile(source, tmp_path / "lua")

    # Both should succeed
    assert cpython_rc == 0, f"CPython-transpiled program failed"
    assert lua_rc == 0, f"Lua-transpiled program failed"

    # Outputs must match
    assert cpython_out == lua_out, (
        f"Output mismatch for '{name}':\n"
        f"--- CPython pipeline ---\n{cpython_out}\n"
        f"--- Lua pipeline ---\n{lua_out}"
    )

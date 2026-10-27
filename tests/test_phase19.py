"""Phase 19: Strict LuaJIT Trace JIT Specialization & NYI Eliminator Tests."""

import subprocess
from pathlib import Path
import pytest
from luthon.ir import Function, Block, Instr, Module
from luthon.nyi import NYIAuditor, eliminate_loop_invariant_allocations
from luthon.cli import compile_file


def test_nyi_auditor_detects_allocations_in_loop():
    """Verify that the NYI auditor flags dynamic allocations inside loops."""
    fn = Function(name="loop_alloc")
    b_entry = Block(label="entry")
    b_loop = Block(label="loop")
    b_end = Block(label="end")

    b_entry.instrs.append(Instr(op="JUMP", args=["loop"]))

    # Loop contains a table allocation that would abort a trace
    b_loop.instrs.append(Instr(op="MAKE_TABLE", args=[], result="_t1"))
    b_loop.instrs.append(Instr(op="JUMP", args=["loop"]))  # Back-edge creates loop

    fn.blocks.extend([b_entry, b_loop, b_end])
    mod = Module(name="test_mod", functions=[fn])

    auditor = NYIAuditor(mod)
    violations = auditor.audit()

    assert len(violations) > 0
    assert any(v.category == "allocation_in_loop" for v in violations)


def test_loop_invariant_allocation_hoisting():
    """Verify that invariant buffer allocations are hoisted out of loops to pre-headers."""
    fn = Function(name="hoist_test")
    b_entry = Block(label="entry")
    b_loop = Block(label="loop")

    b_entry.instrs.append(Instr(op="JUMP", args=["loop"]))
    # Invariant allocation inside loop
    b_loop.instrs.append(Instr(op="MAKE_TABLE", args=[], result="_buf"))
    b_loop.instrs.append(Instr(op="CONST", args=[1], result="_t1"))
    b_loop.instrs.append(Instr(op="JUMP", args=["loop"]))  # Back-edge

    fn.blocks.extend([b_entry, b_loop])

    changed = eliminate_loop_invariant_allocations(fn)
    assert changed == True
    # The MAKE_TABLE instruction should now be in the entry block
    assert any(ins.op == "MAKE_TABLE" for ins in b_entry.instrs)
    # And removed from loop block
    assert not any(ins.op == "MAKE_TABLE" for ins in b_loop.instrs)


def test_cdata_memory_anchoring(tmp_path):
    """Verify that raw CData pointers are registered in the anchor table to prevent GC collection."""
    py_code = """
import ffi

# Create a native double buffer
arr = array("d", [10.5, 20.5, 30.5])
raw_buf = arr._buf

# Register anchor
_luthon_anchor(raw_buf, arr)
assert _luthon_is_anchored(raw_buf) == True

# Release anchor
_luthon_release_anchor(raw_buf)
assert _luthon_is_anchored(raw_buf) == False

print("CDATA_ANCHOR_OK")
"""
    py_file = tmp_path / "test_anchor.py"
    py_file.write_text(py_code)
    lua_file = tmp_path / "test_anchor.lua"

    compile_file(py_file, use_ir=True, no_cache=True, output_path=lua_file)

    res = subprocess.run(["luajit", str(lua_file)], capture_output=True, text=True)
    assert res.returncode == 0, f"Lua error: {res.stderr}"
    assert "CDATA_ANCHOR_OK" in res.stdout

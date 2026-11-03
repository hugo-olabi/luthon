"""Tests for Phase 35: Multi-Task Asynchronous Event Loop (asyncio.gather, create_task, sleep)."""

import unittest
import tempfile
import subprocess
from pathlib import Path

from luthon.transpiler import transpile_ir


class TestPhase35AsyncIO(unittest.TestCase):
    """Unit tests for Phase 35 asyncio task scheduling and gather."""

    def _run_lua(self, py_code: str) -> subprocess.CompletedProcess:
        lua_code = transpile_ir(py_code, optimize=True)
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(lua_code)
            f_path = Path(f.name)

        try:
            res = subprocess.run(["luajit", str(f_path)], capture_output=True, text=True)
            return res
        finally:
            if f_path.exists():
                f_path.unlink()

    def test_asyncio_create_task_interleaving(self):
        """Test cooperative multi-task interleaving using asyncio.create_task."""
        py_code = """
import asyncio

log = []

async def worker(task_id, steps):
    for i in range(steps):
        log.append(f"{task_id}_{i}")
        await asyncio.sleep(0.001)
    return task_id

async def main():
    t1 = asyncio.create_task(worker("A", 3))
    t2 = asyncio.create_task(worker("B", 3))
    r1 = await t1
    r2 = await t2
    return r1, r2

res1, res2 = asyncio.run(main())
assert res1 == "A"
assert res2 == "B"
assert len(log) == 6
# Verify interleaving: A_0 then B_0 happened
assert log[0] == "A_0"
assert log[1] == "B_0"
print("ASYNCIO_CREATE_TASK_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("ASYNCIO_CREATE_TASK_PASSED", proc.stdout)

    def test_asyncio_gather(self):
        """Test concurrent awaiting and result collection with asyncio.gather."""
        py_code = """
import asyncio

async def compute_square(x):
    await asyncio.sleep(0.001)
    return x * x

async def main():
    results = await asyncio.gather(
        compute_square(2),
        compute_square(3),
        compute_square(4),
        compute_square(5)
    )
    return results

res = asyncio.run(main())
assert res == [4, 9, 16, 25], f"Unexpected gather results: {res}"
print("ASYNCIO_GATHER_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("ASYNCIO_GATHER_PASSED", proc.stdout)

    def test_asyncio_nested_tasks_and_cancellation(self):
        """Test task completion status and cancellation."""
        py_code = """
import asyncio

async def background():
    await asyncio.sleep(1.0)
    return 42

async def main():
    task = asyncio.create_task(background())
    assert not task.done()
    task.cancel()
    assert task.done()
    return "OK"

res = asyncio.run(main())
assert res == "OK"
print("ASYNCIO_CANCELLATION_PASSED")
"""
        proc = self._run_lua(py_code)
        self.assertEqual(proc.returncode, 0, f"LuaJIT failed: {proc.stderr}")
        self.assertIn("ASYNCIO_CANCELLATION_PASSED", proc.stdout)


if __name__ == "__main__":
    unittest.main()

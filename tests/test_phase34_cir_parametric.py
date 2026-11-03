"""Tests for Phase 34: Parametric Container Type Propagation in CIR (cir.py)."""

import unittest
import ast
import tempfile
import subprocess
from pathlib import Path

from luthon.cir import (
    INT_TYPE,
    FLOAT_TYPE,
    STR_TYPE,
    BOOL_TYPE,
    ListType,
    DictType,
    TupleType,
    parse_type_annotation,
    TypeInferrer,
    normalize_to_typed_cir,
)
from luthon.ir import IRLowerer
from luthon.semantic import SemanticAnalyzer
from luthon.transpiler import transpile_ir


class TestPhase34ParametricCIR(unittest.TestCase):
    """Unit tests for Phase 34 parametric container types and inference."""

    def test_parametric_type_system_and_parser(self):
        """Test parsing of modern Python parametric type annotations."""
        # 1. ListType
        t1 = parse_type_annotation(ast.parse("list[float]", mode="eval").body)
        self.assertIsInstance(t1, ListType)
        self.assertEqual(t1.item_type, FLOAT_TYPE)
        self.assertEqual(str(t1), "list[float]")

        # 2. DictType
        t2 = parse_type_annotation(ast.parse("dict[str, int]", mode="eval").body)
        self.assertIsInstance(t2, DictType)
        self.assertEqual(t2.key_type, STR_TYPE)
        self.assertEqual(t2.value_type, INT_TYPE)
        self.assertEqual(str(t2), "dict[str, int]")

        # 3. TupleType
        t3 = parse_type_annotation(ast.parse("tuple[int, float, bool]", mode="eval").body)
        self.assertIsInstance(t3, TupleType)
        self.assertEqual(t3.item_types, (INT_TYPE, FLOAT_TYPE, BOOL_TYPE))
        self.assertEqual(str(t3), "tuple[int, float, bool]")

    def test_signature_type_seeding(self):
        """Verify type annotations on function parameters seed CIR type inference."""
        code = """
def calculate(vals: list[float], factor: float) -> float:
    acc = 0.0
    for v in vals:
        acc = acc + v * factor
    return acc
"""
        tree = ast.parse(code)
        SemanticAnalyzer().analyze(tree)
        module = IRLowerer().lower(tree)
        fn = module.functions[0]

        inferrer = TypeInferrer(fn)
        type_map = inferrer.infer()

        self.assertIsInstance(type_map["vals"], ListType)
        self.assertEqual(type_map["vals"].item_type, FLOAT_TYPE)
        self.assertEqual(type_map["factor"], FLOAT_TYPE)
        self.assertEqual(type_map["acc"], FLOAT_TYPE)

    def test_container_operation_type_inference_and_specialization(self):
        """Verify list subscript and iteration infer container item types and specialize instructions."""
        code = """
def sum_int_list(nums: list[int]) -> int:
    total = 0
    i = 0
    while i < 10:
        val = nums[i]
        total = total + val
        i = i + 1
    return total
"""
        tree = ast.parse(code)
        SemanticAnalyzer().analyze(tree)
        module = IRLowerer().lower(tree)
        fn = module.functions[0]

        inferrer = TypeInferrer(fn)
        type_map = inferrer.infer()

        self.assertEqual(type_map["val"], INT_TYPE)
        normalize_to_typed_cir(fn, type_map)

        # nums[i] should be specialized to SUBSCR_DIRECT
        subscrs = [ins.op for b in fn.blocks for ins in b.instrs if ins.op in ("SUBSCR", "SUBSCR_DIRECT")]
        self.assertIn("SUBSCR_DIRECT", subscrs)

    def test_end_to_end_typed_container_execution(self):
        """Verify typed container operations execute correctly in LuaJIT with specialized instructions."""
        py_code = """
def process_data(items: list[float], scale: float) -> float:
    result = 0.0
    for x in items:
        result = result + x * scale
    return result

values = [1.5, 2.5, 3.5, 4.5]
res = process_data(values, 2.0)
# (1.5 + 2.5 + 3.5 + 4.5) * 2.0 = 12.0 * 2.0 = 24.0
assert res == 24.0, f"Expected 24.0, got {res}"
print("PHASE_34_EXECUTION_PASSED")
"""
        lua_code = transpile_ir(py_code, optimize=True)
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(lua_code)
            f_path = Path(f.name)

        try:
            res = subprocess.run(["luajit", str(f_path)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"LuaJIT failed: {res.stderr}")
            self.assertIn("PHASE_34_EXECUTION_PASSED", res.stdout)
        finally:
            if f_path.exists():
                f_path.unlink()


if __name__ == "__main__":
    unittest.main()

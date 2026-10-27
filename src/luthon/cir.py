"""Typed High-Level Intermediate Representation (CIR) & Monomorphization (Phase 17).

Inspired by Codon, Numba, and PyPy:
1. Type Lattice & Constraint-Based Propagation (CPA) on IR.
2. Normalization of generic operations into typed magic methods (e.g. int.__add__).
3. Call-site specialization (monomorphization) for scalar types (int, float, bool).
4. Early pattern fusion (e.g. d[k] = d.get(k, 0) + 1 -> d[k] = (d[k] or 0) + 1).
"""

from __future__ import annotations
import ast
import copy
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Set, Tuple, Union
from .ir import Module, Function, Block, Instr


# =============================================================================
# 1. Type Lattice Definition
# =============================================================================

@dataclass(frozen=True)
class CIRType:
    name: str

    def __str__(self) -> str:
        return self.name


INT_TYPE = CIRType("int")
FLOAT_TYPE = CIRType("float")
BOOL_TYPE = CIRType("bool")
STR_TYPE = CIRType("str")
ANY_TYPE = CIRType("any")
BOTTOM_TYPE = CIRType("bottom")  # Unknown / unassigned

PRIMITIVE_TYPES = {INT_TYPE, FLOAT_TYPE, BOOL_TYPE, STR_TYPE}


# =============================================================================
# 2. Constraint-Based Type Inference (CPA)
# =============================================================================

class TypeInferrer:
    """Performs monotonic constraint-based type propagation across basic blocks."""

    def __init__(self, fn: Function, param_types: Optional[Dict[str, CIRType]] = None):
        self.fn = fn
        self.param_types = param_types or {}
        # Variable name -> Set of possible CIRTypes
        self.type_env: Dict[str, Set[CIRType]] = {}
        # Initial seeding
        for p in fn.params:
            if p in self.param_types:
                self.type_env[p] = {self.param_types[p]}
            else:
                self.type_env[p] = {ANY_TYPE}

    def infer(self) -> Dict[str, CIRType]:
        """Runs iterative fixed-point type propagation until convergence."""
        changed = True
        iterations = 0
        max_iterations = 20

        while changed and iterations < max_iterations:
            changed = False
            iterations += 1

            for block in self.fn.blocks:
                for ins in block.instrs:
                    if ins.op == "STORE":
                        var_name = ins.args[0] if ins.args else ""
                        val_arg = ins.args[1] if len(ins.args) > 1 else None
                        val_type = self._get_type(val_arg)
                        old_vtypes = set(self.type_env.get(var_name, set()))
                        new_vtypes = old_vtypes | {val_type}
                        if new_vtypes != old_vtypes:
                            self.type_env[var_name] = new_vtypes
                            changed = True
                        continue

                    if not ins.result:
                        continue

                    old_types = set(self.type_env.get(ins.result, set()))
                    new_types = self._transfer_instr(ins)
                    merged = old_types | new_types

                    if merged != old_types:
                        self.type_env[ins.result] = merged
                        changed = True

        # Summarize each variable to single most-specific type
        summary: Dict[str, CIRType] = {}
        for var, types in self.type_env.items():
            if not types or BOTTOM_TYPE in types:
                summary[var] = ANY_TYPE
            elif len(types) == 1:
                summary[var] = next(iter(types))
            elif INT_TYPE in types and FLOAT_TYPE in types:
                summary[var] = FLOAT_TYPE  # Numeric promotion
            else:
                summary[var] = ANY_TYPE
        return summary

    def _get_type(self, arg: Any) -> CIRType:
        if isinstance(arg, int):
            return INT_TYPE
        elif isinstance(arg, float):
            return FLOAT_TYPE
        elif isinstance(arg, bool):
            return BOOL_TYPE
        elif isinstance(arg, str):
            types = self.type_env.get(arg, {ANY_TYPE})
            if len(types) == 1:
                return next(iter(types))
            if INT_TYPE in types and FLOAT_TYPE in types:
                return FLOAT_TYPE
        return ANY_TYPE

    def _transfer_instr(self, ins: Instr) -> Set[CIRType]:
        op = ins.op

        if op == "CONST":
            val = ins.args[0] if ins.args else None
            if isinstance(val, bool):
                return {BOOL_TYPE}
            elif isinstance(val, int):
                return {INT_TYPE}
            elif isinstance(val, float):
                return {FLOAT_TYPE}
            elif isinstance(val, str):
                return {STR_TYPE}
            return {ANY_TYPE}

        elif op == "LOAD":
            var_name = ins.args[0] if ins.args else ""
            return set(self.type_env.get(var_name, {ANY_TYPE}))

        elif op == "STORE":
            var_name = ins.args[0] if ins.args else ""
            val_arg = ins.args[1] if len(ins.args) > 1 else None
            val_type = self._get_type(val_arg)
            existing = self.type_env.get(var_name, set())
            self.type_env[var_name] = existing | {val_type}
            return set()

        elif op == "BINOP":
            binop = (ins.args[0] or "").lower()
            left_t = self._get_type(ins.args[1] if len(ins.args) > 1 else None)
            right_t = self._get_type(ins.args[2] if len(ins.args) > 2 else None)

            if binop == "div":
                return {FLOAT_TYPE}
            if binop == "floordiv":
                return {INT_TYPE}
            if binop in ("band", "bor", "bxor", "lshift", "rshift", "mod"):
                return {INT_TYPE}

            if left_t == INT_TYPE and right_t == INT_TYPE:
                return {INT_TYPE}
            elif {left_t, right_t} <= {INT_TYPE, FLOAT_TYPE}:
                return {FLOAT_TYPE}
            elif left_t == STR_TYPE and right_t == STR_TYPE:
                return {STR_TYPE}
            return {ANY_TYPE}

        elif op == "UNOP":
            unop = (ins.args[0] or "").lower()
            operand_t = self._get_type(ins.args[1] if len(ins.args) > 1 else None)
            if unop == "not":
                return {BOOL_TYPE}
            if unop == "neg":
                return {operand_t}
            if unop == "inv":
                return {INT_TYPE}
            return {operand_t}

        elif op in ("CMP", "SELECT"):
            return {BOOL_TYPE} if op == "CMP" else {self._get_type(ins.args[1] if len(ins.args) > 1 else None)}

        return {ANY_TYPE}


# =============================================================================
# 3. High-Level Typed Method Normalization (CIR)
# =============================================================================

def normalize_to_typed_cir(fn: Function, type_map: Dict[str, CIRType]) -> bool:
    """Replaces generic BINOP and UNOP instructions with resolved typed magic method annotations."""
    changed = False

    for block in fn.blocks:
        for ins in block.instrs:
            if ins.op == "BINOP" and len(ins.args) >= 3:
                binop = str(ins.args[0]).lower()
                left_arg, right_arg = ins.args[1], ins.args[2]
                lt = type_map.get(str(left_arg), INT_TYPE if isinstance(left_arg, int) else (FLOAT_TYPE if isinstance(left_arg, float) else ANY_TYPE))
                rt = type_map.get(str(right_arg), INT_TYPE if isinstance(right_arg, int) else (FLOAT_TYPE if isinstance(right_arg, float) else ANY_TYPE))

                if lt == INT_TYPE and rt == INT_TYPE:
                    method_name = f"int.__typed_{binop}__"
                    ins.args[0] = method_name
                    changed = True
                elif {lt, rt} <= {INT_TYPE, FLOAT_TYPE}:
                    method_name = f"float.__typed_{binop}__"
                    ins.args[0] = method_name
                    changed = True

    return changed


# =============================================================================
# 4. Idiomatic Pattern Fusion
# =============================================================================

def fuse_dictionary_counter_patterns(fn: Function) -> bool:
    """Fuses dictionary counting idioms into direct Lua table increments.

    Pattern:
      _t1 = d.get(k, 0)
      _t2 = _t1 + 1
      d[k] = _t2
    Transforms to fast zero-lookup:
      d[k] = (d[k] or 0) + 1
    """
    changed = False

    for block in fn.blocks:
        i = 0
        while i < len(block.instrs) - 2:
            ins1 = block.instrs[i]
            ins2 = block.instrs[i + 1]
            ins3 = block.instrs[i + 2]

            # Match d.get(k, 0)
            if (ins1.op == "CALL" and len(ins1.args) >= 4 and
                    isinstance(ins1.args[0], str) and "get" in ins1.args[0]):
                d_tmp = ins1.args[1]
                k_tmp = ins1.args[2]
                default_arg = ins1.args[3]
                res_get = ins1.result

                # Match res_get + 1
                if (ins2.op == "BINOP" and len(ins2.args) >= 3 and
                        ins2.args[1] == res_get and
                        (ins2.args[0] in ("add", "int.__typed_add__"))):
                    inc_tmp = ins2.result

                    # Match d[k] = inc_tmp (STORE_SUBSCR)
                    if (ins3.op == "STORE_SUBSCR" and len(ins3.args) >= 3 and
                            ins3.args[0] == d_tmp and ins3.args[1] == k_tmp and ins3.args[2] == inc_tmp):
                        # Replace with fused atomic increment instruction
                        fused_ins = Instr(
                            op="DICT_COUNTER_INC",
                            args=[d_tmp, k_tmp, ins2.args[2]],
                            result=None,
                            src_line=ins1.src_line,
                            src_col=ins1.src_col
                        )
                        block.instrs[i] = fused_ins
                        del block.instrs[i + 1:i + 3]
                        changed = True
            i += 1

    return changed


# =============================================================================
# 5. Call-Site Monomorphization (Specialization)
# =============================================================================

def monomorphize_module(module: Module) -> bool:
    """Scans all call sites across the module and clones specialized functions for scalar types."""
    fn_map = {f.name: f for f in module.functions}
    new_specialized_fns: List[Function] = []
    specialized_names: Set[str] = set()
    changed = False

    for fn in module.functions:
        inferrer = TypeInferrer(fn)
        type_map = inferrer.infer()

        for block in fn.blocks:
            for ins in block.instrs:
                if ins.op == "CALL" and ins.args:
                    callee_name = ins.args[0]
                    if isinstance(callee_name, str) and callee_name in fn_map:
                        target_fn = fn_map[callee_name]
                        # Don't specialize main or already specialized functions
                        if target_fn.name == "main" or "_spec_" in target_fn.name:
                            continue

                        # Check argument types at this call site
                        call_arg_types = []
                        for a in ins.args[1:]:
                            t = type_map.get(str(a), INT_TYPE if isinstance(a, int) else (FLOAT_TYPE if isinstance(a, float) else ANY_TYPE))
                            call_arg_types.append(t)

                        # If all arguments have concrete primitive types (e.g. int or float)
                        if call_arg_types and all(t in PRIMITIVE_TYPES for t in call_arg_types):
                            sig_suffix = "_".join(t.name for t in call_arg_types)
                            spec_name = f"{target_fn.name}_spec_{sig_suffix}"

                            if spec_name not in specialized_names:
                                # Clone target function and infer specialized types
                                spec_fn = copy.deepcopy(target_fn)
                                spec_fn.name = spec_name

                                param_types = {p: t for p, t in zip(spec_fn.params, call_arg_types)}
                                spec_inferrer = TypeInferrer(spec_fn, param_types=param_types)
                                spec_type_map = spec_inferrer.infer()

                                # Optimize specialized clone
                                normalize_to_typed_cir(spec_fn, spec_type_map)
                                fuse_dictionary_counter_patterns(spec_fn)

                                new_specialized_fns.append(spec_fn)
                                specialized_names.add(spec_name)

                            # Rewrite call to invoke the specialized function
                            ins.args[0] = spec_name
                            changed = True

    if new_specialized_fns:
        module.functions.extend(new_specialized_fns)

    return changed


def optimize_cir(module: Module) -> Module:
    """Top-level entry point to execute Phase 17 CIR passes."""
    # 1. Monomorphization
    monomorphize_module(module)

    # 2. Per-function CIR normalization and pattern fusion
    for fn in module.functions:
        inferrer = TypeInferrer(fn)
        type_map = inferrer.infer()
        normalize_to_typed_cir(fn, type_map)
        fuse_dictionary_counter_patterns(fn)

    return module

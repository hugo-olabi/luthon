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


@dataclass(frozen=True)
class ListType(CIRType):
    item_type: CIRType = field(default_factory=lambda: ANY_TYPE)

    def __init__(self, item_type: Optional[CIRType] = None):
        object.__setattr__(self, "name", f"list[{item_type or ANY_TYPE}]")
        object.__setattr__(self, "item_type", item_type or ANY_TYPE)

    def __str__(self) -> str:
        return f"list[{self.item_type}]"


@dataclass(frozen=True)
class DictType(CIRType):
    key_type: CIRType = field(default_factory=lambda: ANY_TYPE)
    value_type: CIRType = field(default_factory=lambda: ANY_TYPE)

    def __init__(self, key_type: Optional[CIRType] = None, value_type: Optional[CIRType] = None):
        object.__setattr__(self, "name", f"dict[{key_type or ANY_TYPE}, {value_type or ANY_TYPE}]")
        object.__setattr__(self, "key_type", key_type or ANY_TYPE)
        object.__setattr__(self, "value_type", value_type or ANY_TYPE)

    def __str__(self) -> str:
        return f"dict[{self.key_type}, {self.value_type}]"


@dataclass(frozen=True)
class TupleType(CIRType):
    item_types: Tuple[CIRType, ...] = field(default_factory=tuple)

    def __init__(self, item_types: Tuple[CIRType, ...] = ()):
        types_str = ", ".join(str(t) for t in item_types)
        object.__setattr__(self, "name", f"tuple[{types_str}]")
        object.__setattr__(self, "item_types", tuple(item_types))

    def __str__(self) -> str:
        types_str = ", ".join(str(t) for t in self.item_types)
        return f"tuple[{types_str}]"


INT_TYPE = CIRType("int")
FLOAT_TYPE = CIRType("float")
BOOL_TYPE = CIRType("bool")
STR_TYPE = CIRType("str")
ANY_TYPE = CIRType("any")
BOTTOM_TYPE = CIRType("bottom")  # Unknown / unassigned

PRIMITIVE_TYPES = {INT_TYPE, FLOAT_TYPE, BOOL_TYPE, STR_TYPE}


def parse_type_annotation(node: Any) -> CIRType:
    """Parses a Python AST type annotation node into a CIRType."""
    if node is None:
        return ANY_TYPE

    if isinstance(node, ast.Name):
        name = node.id.lower()
        if name in ("int", "integer"):
            return INT_TYPE
        if name in ("float", "double"):
            return FLOAT_TYPE
        if name in ("bool", "boolean"):
            return BOOL_TYPE
        if name in ("str", "string"):
            return STR_TYPE
        if name == "list":
            return ListType(ANY_TYPE)
        if name == "dict":
            return DictType(ANY_TYPE, ANY_TYPE)
        if name == "tuple":
            return TupleType(())
        return ANY_TYPE

    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        try:
            parsed = ast.parse(node.value, mode="eval")
            return parse_type_annotation(parsed.body)
        except Exception:
            return ANY_TYPE

    if isinstance(node, ast.Subscript):
        base_t = parse_type_annotation(node.value)
        base_name = getattr(node.value, "id", "").lower()
        sl = node.slice
        if base_name in ("list", "sequence", "iterable"):
            item_t = parse_type_annotation(sl)
            return ListType(item_t)
        elif base_name in ("dict", "mapping"):
            if isinstance(sl, ast.Tuple) and len(sl.elts) == 2:
                kt = parse_type_annotation(sl.elts[0])
                vt = parse_type_annotation(sl.elts[1])
                return DictType(kt, vt)
            return DictType(ANY_TYPE, ANY_TYPE)
        elif base_name == "tuple":
            if isinstance(sl, ast.Tuple):
                elts = tuple(parse_type_annotation(e) for e in sl.elts)
                return TupleType(elts)
            else:
                return TupleType((parse_type_annotation(sl),))
        return base_t

    return ANY_TYPE


# =============================================================================
# 2. Constraint-Based Type Inference (CPA)
# =============================================================================

class TypeInferrer:
    """Performs monotonic constraint-based type propagation across basic blocks (Phase 17 & Phase 34)."""

    def __init__(self, fn: Function, param_types: Optional[Dict[str, CIRType]] = None):
        self.fn = fn
        self.param_types = param_types or {}
        # Variable name -> Set of possible CIRTypes
        self.type_env: Dict[str, Set[CIRType]] = {}
        # Initial seeding: explicit param_types or function signature type annotations
        fn_annots = getattr(fn, "param_annotations", {}) or {}
        for p in fn.params:
            if p in self.param_types:
                self.type_env[p] = {self.param_types[p]}
            elif p in fn_annots:
                ann_type = parse_type_annotation(fn_annots[p])
                self.type_env[p] = {ann_type}
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

        # Parametric Container Operations (Phase 34)
        elif op == "MAKE_LIST":
            if ins.args:
                elem_types = set()
                for a in ins.args:
                    elem_types.add(self._get_type(a))
                if len(elem_types) == 1:
                    return {ListType(next(iter(elem_types)))}
                elif elem_types <= {INT_TYPE, FLOAT_TYPE}:
                    return {ListType(FLOAT_TYPE)}
            return {ListType(ANY_TYPE)}

        elif op == "MAKE_DICT":
            return {DictType(ANY_TYPE, ANY_TYPE)}

        elif op == "MAKE_TUPLE":
            elts = tuple(self._get_type(a) for a in ins.args)
            return {TupleType(elts)}

        elif op == "LIST_APPEND":
            if len(ins.args) >= 2:
                lst_var = str(ins.args[0])
                elem_t = self._get_type(ins.args[1])
                curr_types = self.type_env.get(lst_var, set())
                updated = set()
                for ct in curr_types:
                    if isinstance(ct, ListType):
                        if ct.item_type in (ANY_TYPE, BOTTOM_TYPE):
                            updated.add(ListType(elem_t))
                        elif ct.item_type != elem_t:
                            if {ct.item_type, elem_t} <= {INT_TYPE, FLOAT_TYPE}:
                                updated.add(ListType(FLOAT_TYPE))
                            else:
                                updated.add(ListType(ANY_TYPE))
                        else:
                            updated.add(ct)
                    else:
                        updated.add(ct)
                if updated:
                    self.type_env[lst_var] = updated
            return set()

        elif op in ("SUBSCR", "SUBSCR_DIRECT"):
            if len(ins.args) >= 1:
                cont_t = self._get_type(ins.args[0])
                if isinstance(cont_t, ListType):
                    return {cont_t.item_type}
                elif isinstance(cont_t, DictType):
                    return {cont_t.value_type}
                elif isinstance(cont_t, TupleType):
                    idx = ins.args[1] if len(ins.args) > 1 else None
                    if isinstance(idx, int) and 0 <= idx < len(cont_t.item_types):
                        return {cont_t.item_types[idx]}
                    return set(cont_t.item_types) if cont_t.item_types else {ANY_TYPE}
            return {ANY_TYPE}

        elif op == "NEXT":
            if len(ins.args) >= 1:
                it_t = self._get_type(ins.args[0])
                if isinstance(it_t, ListType):
                    return {it_t.item_type}
                elif isinstance(it_t, TupleType):
                    return set(it_t.item_types) if it_t.item_types else {ANY_TYPE}
            return {ANY_TYPE}

        elif op == "CALL":
            if ins.args:
                callee = str(ins.args[0])
                if callee == "iter" and len(ins.args) > 1:
                    return {self._get_type(ins.args[1])}
            return {ANY_TYPE}

        return {ANY_TYPE}


# =============================================================================
# 3. High-Level Typed Method Normalization (CIR)
# =============================================================================

def normalize_to_typed_cir(fn: Function, type_map: Dict[str, CIRType]) -> bool:
    """Replaces generic BINOP, CMP, and SUBSCR instructions with specialized direct typed operations."""
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

            elif ins.op == "CMP" and len(ins.args) >= 3:
                cmpop = str(ins.args[0]).lower()
                left_arg, right_arg = ins.args[1], ins.args[2]
                lt = type_map.get(str(left_arg), INT_TYPE if isinstance(left_arg, int) else (FLOAT_TYPE if isinstance(left_arg, float) else (BOOL_TYPE if isinstance(left_arg, bool) else (STR_TYPE if isinstance(left_arg, str) else ANY_TYPE))))
                rt = type_map.get(str(right_arg), INT_TYPE if isinstance(right_arg, int) else (FLOAT_TYPE if isinstance(right_arg, float) else (BOOL_TYPE if isinstance(right_arg, bool) else (STR_TYPE if isinstance(right_arg, str) else ANY_TYPE))))

                # Numeric and boolean scalar comparisons can be directly evaluated in Lua
                # without traversing Python metatable chains or calling _luthon_cmp
                if cmpop in ("eq", "ne", "lt", "le", "gt", "ge", "==", "~=", "!=", "<", "<=", ">", ">="):
                    if {lt, rt} <= {INT_TYPE, FLOAT_TYPE} or (lt == BOOL_TYPE and rt == BOOL_TYPE):
                        ins.op = "CMP_DIRECT"
                        changed = True

            elif ins.op == "SUBSCR" and len(ins.args) >= 2:
                cont_arg, idx_arg = ins.args[0], ins.args[1]
                cont_t = type_map.get(str(cont_arg), ANY_TYPE)
                it = type_map.get(str(idx_arg), INT_TYPE if isinstance(idx_arg, int) else ANY_TYPE)
                # If index is known integer and container is homogeneous ListType or constant index
                if (isinstance(idx_arg, int) and idx_arg >= 0) or (isinstance(cont_t, (ListType, TupleType)) and it == INT_TYPE):
                    ins.op = "SUBSCR_DIRECT"
                    changed = True

            elif ins.op == "STORE_SUBSCR" and len(ins.args) >= 3:
                cont_arg, idx_arg = ins.args[0], ins.args[1]
                cont_t = type_map.get(str(cont_arg), ANY_TYPE)
                it = type_map.get(str(idx_arg), INT_TYPE if isinstance(idx_arg, int) else ANY_TYPE)
                if (isinstance(idx_arg, int) and idx_arg >= 0) or (isinstance(cont_t, ListType) and it == INT_TYPE):
                    ins.op = "STORE_SUBSCR_DIRECT"
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

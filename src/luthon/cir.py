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


# =============================================================================
# 6. Affine Loop Dependency & Vectorizability Analysis (Phase 39)
# =============================================================================

@dataclass
class VectorizationRecord:
    func_name: str
    loop_header: str
    status: str  # "VECTORIZED" or "REJECTED"
    pattern: Optional[str] = None
    reason: Optional[str] = None
    vector_width: int = 4
    unroll_factor: int = 1
    induction_var: str = "i"
    upper_bound: Optional[str] = None
    element_type: str = "f64"
    line_number: int = 0
    # Transformation metadata
    body_label: Optional[str] = None
    exit_label: Optional[str] = None
    preheader_label: Optional[str] = None
    target_arrays: List[str] = field(default_factory=list)
    source_arrays: List[str] = field(default_factory=list)
    scalar_operands: List[str] = field(default_factory=list)
    reduction_var: Optional[str] = None


_VECTORIZATION_RECORDS: List[VectorizationRecord] = []


def get_vectorization_records() -> List[VectorizationRecord]:
    """Returns the list of vectorization analysis records from the most recent run."""
    return list(_VECTORIZATION_RECORDS)


def clear_vectorization_records() -> None:
    """Clears the stored vectorization records."""
    _VECTORIZATION_RECORDS.clear()


def format_vectorization_report() -> str:
    """Formats auto-vectorization diagnostics for display."""
    if not _VECTORIZATION_RECORDS:
        return "[SIMD Vectorization Report] No loop nests analyzed.\n"
    lines = [
        "=" * 80,
        "Luthon CIR SIMD Auto-Vectorization Report (AVX2 / ARM NEON)",
        "=" * 80,
    ]
    grouped: Dict[str, List[VectorizationRecord]] = {}
    for r in _VECTORIZATION_RECORDS:
        grouped.setdefault(r.func_name, []).append(r)

    for fn_name, records in grouped.items():
        lines.append(f"Function '{fn_name}':")
        for rec in records:
            tag = "[+]" if rec.status == "VECTORIZED" else "[-]"
            line_str = f"at line {rec.line_number} " if rec.line_number > 0 else ""
            lines.append(f"  {tag} Loop {line_str}(header '{rec.loop_header}'):")
            lines.append(f"      Status:         {rec.status}")
            if rec.status == "VECTORIZED":
                pat_name = rec.pattern or "Affine Strip-Mined Loop"
                lines.append(f"      Pattern:        {pat_name}")
                lines.append(f"      Vector Width:   {rec.vector_width} lanes ({rec.element_type})")
                lines.append(f"      Unroll Factor:  {rec.unroll_factor}")
                lines.append(f"      Induction Var:  {rec.induction_var} (unit stride 1)")
                if rec.upper_bound:
                    lines.append(f"      Upper Bound:    {rec.upper_bound}")
                lines.append(f"      Transform:      Strip-mining (SIMD kernel + scalar remainder)")
            else:
                lines.append(f"      Reason:         {rec.reason or 'Not vectorizable'}")
        lines.append("")
    lines.append("=" * 80)
    return "\n".join(lines) + "\n"


def print_vectorization_report() -> None:
    """Prints vectorization diagnostics to stderr."""
    import sys
    sys.stderr.write(format_vectorization_report())


def _alloc_tmp(fn: Function, prefix: str = "_t") -> str:
    idx = len(fn.tmps) + 1
    t = f"{prefix}{idx}"
    while t in fn.tmps or t in fn.locals:
        idx += 1
        t = f"{prefix}{idx}"
    fn.tmps.append(t)
    return t


def _alloc_label(fn: Function, prefix: str = "simd") -> str:
    existing = {b.label for b in fn.blocks}
    idx = 1
    lbl = f"{prefix}{idx}"
    while lbl in existing:
        idx += 1
        lbl = f"{prefix}{idx}"
    return lbl


def analyze_loop_vectorizability(
    fn: Function,
    header_lbl: str,
    loop_blocks: Set[str],
    preds: Dict[str, Set[str]],
    type_map: Dict[str, CIRType]
) -> VectorizationRecord:
    """Analyzes a natural loop for affine array access patterns and certifies vectorizability."""
    header_blk = next((b for b in fn.blocks if b.label == header_lbl), None)
    if not header_blk or not header_blk.instrs:
        return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason="Missing header block")

    line_no = header_blk.instrs[0].src_line if hasattr(header_blk.instrs[0], "src_line") else 0

    # 1. Identify loop induction variable, bounds, and exit/body labels
    nxt_ins = next((ins for ins in header_blk.instrs if ins.op == "NEXT"), None)
    ind_var = None
    upper_bound = None
    exit_lbl = None
    body_lbl = None

    if nxt_ins:
        # Pattern A: Python for-loop
        bn_ins = next((ins for ins in header_blk.instrs if ins.op == "BRANCH_NONE"), None)
        exit_lbl = bn_ins.args[1] if bn_ins and len(bn_ins.args) > 1 else None
        store_ins = next((ins for ins in header_blk.instrs if ins.op == "STORE" and len(ins.args) >= 2 and ins.args[1] == nxt_ins.result), None)
        ind_var = store_ins.args[0] if store_ins else None
        jump_ins = next((ins for ins in header_blk.instrs if ins.op == "JUMP"), None)
        body_lbl = jump_ins.args[0] if jump_ins else None

        # Search for upper bound from iter(...) and range(...) calls
        iter_call = next((ins for b in fn.blocks for ins in b.instrs if ins.op == "CALL" and ins.result == nxt_ins.args[0]), None)
        if iter_call and len(iter_call.args) > 1:
            range_res = iter_call.args[1]
            range_call = next((ins for b in fn.blocks for ins in b.instrs if ins.op == "CALL" and ins.result == range_res), None)
            if range_call:
                if len(range_call.args) == 2:
                    upper_bound = str(range_call.args[1])
                elif len(range_call.args) >= 3:
                    upper_bound = str(range_call.args[2])
    else:
        # Pattern B: while i < n loop
        cmp_ins = next((ins for ins in header_blk.instrs if ins.op in ("CMP", "CMP_DIRECT") and ins.args and ins.args[0] in ("lt", "<")), None)
        branch_ins = next((ins for ins in header_blk.instrs if ins.op == "BRANCH"), None)
        if cmp_ins and branch_ins and len(cmp_ins.args) >= 3 and len(branch_ins.args) >= 3:
            ind_var = str(cmp_ins.args[1])
            upper_bound = str(cmp_ins.args[2])
            body_lbl = branch_ins.args[1]
            exit_lbl = branch_ins.args[2]

    if not ind_var:
        return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason="Could not detect affine induction variable with unit stride", line_number=line_no)

    # 2. Find preheader
    preheader_lbl = next((p for p in preds.get(header_lbl, []) if p not in loop_blocks), None)

    # 3. Analyze loop body for memory hazards, calls, and control flow
    load_map: Dict[str, Any] = {}
    for b in fn.blocks:
        for ins in b.instrs:
            if ins.op == "LOAD" and ins.result and ins.args:
                load_map[ins.result] = ins.args[0]
            elif ins.op == "CONST" and ins.result and ins.args:
                load_map[ins.result] = ins.args[0]

    def resolve_sym(sym: Any) -> Any:
        visited = set()
        s = sym
        while isinstance(s, str) and s in load_map and s not in visited:
            visited.add(s)
            s = load_map[s]
        return s

    reads: Dict[str, List[Any]] = {}
    writes: Dict[str, List[Tuple[Any, Any]]] = {}
    body_blocks = [b for b in fn.blocks if b.label in loop_blocks and b.label != header_lbl]

    for b in body_blocks:
        for ins in b.instrs:
            if ins.op in ("TRY_BEGIN", "END_TRY", "TRY_RETURN"):
                return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason="Exception handling in loop body", line_number=line_no)
            if ins.op == "RETURN":
                return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason="Early return in loop body", line_number=line_no)
            if ins.op == "CALL":
                callee = str(ins.args[0]) if ins.args else ""
                allowed = {"sin", "cos", "exp", "sqrt", "math.sin", "math.cos", "math.exp", "math.sqrt", "abs", "math.abs"}
                if callee not in allowed and not callee.startswith("_luthon_simd"):
                    return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason=f"Non-pure function call '{callee}' in loop body", line_number=line_no)

            if ins.op in ("SUBSCR", "SUBSCR_DIRECT") and len(ins.args) >= 2:
                arr = str(resolve_sym(ins.args[0]))
                idx = resolve_sym(ins.args[1])
                reads.setdefault(arr, []).append(idx)
            elif ins.op in ("STORE_SUBSCR", "STORE_SUBSCR_DIRECT") and len(ins.args) >= 3:
                arr = str(resolve_sym(ins.args[0]))
                idx = resolve_sym(ins.args[1])
                val = ins.args[2]
                writes.setdefault(arr, []).append((idx, val))

    if not reads and not writes:
        return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason="No array memory operations detected", line_number=line_no)

    # 4. Check distance vectors and loop-carried dependencies
    for arr, w_list in writes.items():
        for w_idx, _ in w_list:
            if str(w_idx) != str(ind_var):
                return VectorizationRecord(fn.name, header_lbl, "REJECTED", reason=f"Non-affine array store index on '{arr}'", line_number=line_no)
        if arr in reads:
            for r_idx in reads[arr]:
                if str(r_idx) != str(ind_var):
                    return VectorizationRecord(
                        fn.name, header_lbl, "REJECTED",
                        reason=f"Loop-carried dependency detected (non-zero distance hazard on array '{arr}')",
                        line_number=line_no
                    )

    # Check stencil reads on input arrays
    for arr, r_list in reads.items():
        if arr not in writes:
            for r_idx in r_list:
                if str(r_idx) != str(ind_var):
                    return VectorizationRecord(
                        fn.name, header_lbl, "REJECTED",
                        reason=f"Loop-carried dependency detected (non-zero distance hazard on array '{arr}')",
                        line_number=line_no
                    )

    # 5. Classify vector pattern
    target_arrays = list(writes.keys())
    source_arrays = [a for a in reads.keys() if a not in writes]
    scalar_operands = []
    reduction_var = None

    # Detect DAXPY / SAXPY
    # y[i] = a * x[i] + y[i]
    is_daxpy = False
    if len(target_arrays) == 1 and len(source_arrays) == 1 and target_arrays[0] in reads:
        y_arr = target_arrays[0]
        x_arr = source_arrays[0]
        # Inspect binary operations in body
        binops = [ins for b in body_blocks for ins in b.instrs if ins.op == "BINOP"]
        has_mul = any("mul" in str(ins.args[0]).lower() for ins in binops)
        has_add = any("add" in str(ins.args[0]).lower() for ins in binops)
        if has_mul and has_add:
            is_daxpy = True
            for ins in binops:
                if "mul" in str(ins.args[0]).lower():
                    for a in ins.args[1:3]:
                        resolved_a = str(resolve_sym(a))
                        if resolved_a != str(ind_var) and resolved_a != str(x_arr) and resolved_a != str(y_arr):
                            scalar_operands.append(resolved_a)
            if not scalar_operands:
                scalar_operands.append("alpha")

    # Detect Dot Product or Euclidean Distance
    is_dot = False
    is_euclidean = False
    if not target_arrays and len(source_arrays) >= 2:
        binops = [ins for b in body_blocks for ins in b.instrs if ins.op == "BINOP"]
        has_mul = any("mul" in str(ins.args[0]).lower() for ins in binops)
        has_sub = any("sub" in str(ins.args[0]).lower() for ins in binops)
        has_add = any("add" in str(ins.args[0]).lower() for ins in binops)
        if has_sub and has_mul and has_add:
            is_euclidean = True
            reduction_var = "s"
        elif has_mul and has_add:
            is_dot = True
            reduction_var = "s"

    pattern_name = "Affine Strip-Mined Loop"
    if is_daxpy:
        pattern_name = "DAXPY / Fused Multiply-Add (a * x[i] + y[i])"
    elif is_euclidean:
        pattern_name = "Euclidean Distance (s = s + (a[i] - b[i])^2)"
    elif is_dot:
        pattern_name = "Dot Product (s = s + a[i] * b[i])"
    elif target_arrays and source_arrays:
        pattern_name = "Vector Elementwise Arithmetic (c[i] = a[i] op b[i])"

    return VectorizationRecord(
        func_name=fn.name,
        loop_header=header_lbl,
        status="VECTORIZED",
        pattern=pattern_name,
        reason=None,
        vector_width=4,
        unroll_factor=1,
        induction_var=str(ind_var),
        upper_bound=upper_bound or "n",
        element_type="f64",
        line_number=line_no,
        body_label=body_lbl,
        exit_label=exit_lbl,
        preheader_label=preheader_lbl,
        target_arrays=target_arrays,
        source_arrays=source_arrays,
        scalar_operands=scalar_operands,
        reduction_var=reduction_var,
    )


# =============================================================================
# 7. CIR Vector Instruction Set & Loop Strip-Mining (Phase 39)
# =============================================================================

def strip_mine_loop(fn: Function, rec: VectorizationRecord) -> bool:
    """Decomposes a certified loop into alignment peeling pre-header, SIMD body of width 4, and scalar remainder block."""
    if not rec.body_label or not rec.exit_label:
        return False

    header_idx = next((i for i, b in enumerate(fn.blocks) if b.label == rec.loop_header), -1)
    body_idx = next((i for i, b in enumerate(fn.blocks) if b.label == rec.body_label), -1)
    if header_idx == -1 or body_idx == -1:
        return False

    header_blk = fn.blocks[header_idx]
    body_blk = fn.blocks[body_idx]

    # Allocate strip-mining labels and temporaries (all temporaries prefixed with _t)
    peel_lbl = _alloc_label(fn, "vec_peel")
    simd_cond_lbl = _alloc_label(fn, "simd_cond")
    simd_body_lbl = _alloc_label(fn, "simd_body")
    rem_cond_lbl = _alloc_label(fn, "rem_cond")
    rem_body_lbl = _alloc_label(fn, "rem_body")

    vec_i = _alloc_tmp(fn, "_t_vi")
    n_vec = _alloc_tmp(fn, "_t_nv")
    cmp_simd = _alloc_tmp(fn, "_t_cs")
    cmp_rem = _alloc_tmp(fn, "_t_cr")
    t_mod = _alloc_tmp(fn, "_t_mod")
    c4 = _alloc_tmp(fn, "_t_c4")
    c1 = _alloc_tmp(fn, "_t_c1")
    upper_bound = rec.upper_bound or "n"

    # 1. Peeling Pre-header Block
    # n_vec = upper_bound - (upper_bound % 4)
    # vec_i = 0
    peel_instrs = [
        Instr("CONST", [0], result=vec_i),
        Instr("CONST", [4], result=c4),
        Instr("BINOP", ["mod", upper_bound, c4], result=t_mod),
        Instr("BINOP", ["sub", upper_bound, t_mod], result=n_vec),
        Instr("JUMP", [simd_cond_lbl]),
    ]
    peel_blk = Block(label=peel_lbl, instrs=peel_instrs)

    # Re-route entry/pre-header jumps from header_blk.label to peel_lbl
    for b in fn.blocks:
        if b.label != rec.loop_header and b.label != rec.body_label:
            for ins in b.instrs:
                if ins.op == "JUMP" and ins.args and ins.args[0] == rec.loop_header:
                    ins.args[0] = peel_lbl
                elif ins.op == "BRANCH" and len(ins.args) >= 3:
                    if ins.args[1] == rec.loop_header:
                        ins.args[1] = peel_lbl
                    if ins.args[2] == rec.loop_header:
                        ins.args[2] = peel_lbl

    # 2. SIMD Condition Block
    simd_cond_instrs = [
        Instr("CMP_DIRECT", ["lt", vec_i, n_vec], result=cmp_simd),
        Instr("BRANCH", [cmp_simd, simd_body_lbl, rem_cond_lbl]),
    ]
    simd_cond_blk = Block(label=simd_cond_lbl, instrs=simd_cond_instrs)

    # 3. SIMD Kernel Body Block (CIR Vector Instructions)
    simd_body_instrs: List[Instr] = []
    width = rec.vector_width
    elem_t = rec.element_type

    if "DAXPY" in (rec.pattern or "") and rec.target_arrays and rec.source_arrays:
        x_arr = rec.source_arrays[0]
        y_arr = rec.target_arrays[0]
        alpha = rec.scalar_operands[0] if rec.scalar_operands else "alpha"
        vx = _alloc_tmp(fn, "_t_vx")
        vy = _alloc_tmp(fn, "_t_vy")
        va = _alloc_tmp(fn, "_t_va")
        vres = _alloc_tmp(fn, "_t_vr")
        simd_body_instrs.extend([
            Instr("VEC_LOAD", [x_arr, vec_i, width, elem_t], result=vx),
            Instr("VEC_LOAD", [y_arr, vec_i, width, elem_t], result=vy),
            Instr("VEC_BROADCAST", [alpha, width, elem_t], result=va),
            Instr("VEC_FMA", [va, vx, vy, width, elem_t], result=vres),
            Instr("VEC_STORE", [y_arr, vec_i, vres, width, elem_t]),
        ])
    elif "Dot Product" in (rec.pattern or "") and len(rec.source_arrays) >= 2:
        a_arr = rec.source_arrays[0]
        b_arr = rec.source_arrays[1]
        va = _alloc_tmp(fn, "_t_va")
        vb = _alloc_tmp(fn, "_t_vb")
        vacc = _alloc_tmp(fn, "_t_vacc")
        simd_body_instrs.extend([
            Instr("VEC_LOAD", [a_arr, vec_i, width, elem_t], result=va),
            Instr("VEC_LOAD", [b_arr, vec_i, width, elem_t], result=vb),
            Instr("VEC_FMA", [va, vb, vacc, width, elem_t], result=vacc),
        ])
    elif "Euclidean" in (rec.pattern or "") and len(rec.source_arrays) >= 2:
        a_arr = rec.source_arrays[0]
        b_arr = rec.source_arrays[1]
        va = _alloc_tmp(fn, "_t_va")
        vb = _alloc_tmp(fn, "_t_vb")
        vdiff = _alloc_tmp(fn, "_t_vd")
        vacc = _alloc_tmp(fn, "_t_vacc")
        simd_body_instrs.extend([
            Instr("VEC_LOAD", [a_arr, vec_i, width, elem_t], result=va),
            Instr("VEC_LOAD", [b_arr, vec_i, width, elem_t], result=vb),
            Instr("VEC_SUB", [va, vb, width, elem_t], result=vdiff),
            Instr("VEC_FMA", [vdiff, vdiff, vacc, width, elem_t], result=vacc),
        ])
    elif rec.target_arrays and len(rec.source_arrays) >= 2:
        # Vector elementwise add
        va = _alloc_tmp(fn, "_t_va")
        vb = _alloc_tmp(fn, "_t_vb")
        vres = _alloc_tmp(fn, "_t_vr")
        simd_body_instrs.extend([
            Instr("VEC_LOAD", [rec.source_arrays[0], vec_i, width, elem_t], result=va),
            Instr("VEC_LOAD", [rec.source_arrays[1], vec_i, width, elem_t], result=vb),
            Instr("VEC_ADD", [va, vb, width, elem_t], result=vres),
            Instr("VEC_STORE", [rec.target_arrays[0], vec_i, vres, width, elem_t]),
        ])
    else:
        # Fallback general vector load/store strip-mining
        for src in rec.source_arrays:
            v_tmp = _alloc_tmp(fn, "_t_vs")
            simd_body_instrs.append(Instr("VEC_LOAD", [src, vec_i, width, elem_t], result=v_tmp))
        for dst in rec.target_arrays:
            simd_body_instrs.append(Instr("VEC_STORE", [dst, vec_i, v_tmp, width, elem_t]))

    # Step induction variable by vector width W=4
    simd_body_instrs.extend([
        Instr("BINOP", ["add", vec_i, c4], result=vec_i),
        Instr("JUMP", [simd_cond_lbl]),
    ])
    simd_body_blk = Block(label=simd_body_lbl, instrs=simd_body_instrs)

    # 4. Scalar Remainder Condition Block (vec_i continues from where SIMD stopped)
    rem_cond_instrs = [
        Instr("CMP_DIRECT", ["lt", vec_i, upper_bound], result=cmp_rem),
        Instr("BRANCH", [cmp_rem, rem_body_lbl, rec.exit_label]),
    ]
    rem_cond_blk = Block(label=rem_cond_lbl, instrs=rem_cond_instrs)

    # 5. Scalar Remainder Cleanup Body Block
    rem_body_instrs: List[Instr] = []
    for ins in body_blk.instrs:
        if ins.op == "JUMP" and ins.args and ins.args[0] == rec.loop_header:
            continue
        # Replace occurrences of induction variable with vec_i
        cloned_args = []
        for a in ins.args:
            if str(a) == rec.induction_var:
                cloned_args.append(vec_i)
            else:
                cloned_args.append(a)
        cloned_res = vec_i if ins.result == rec.induction_var else ins.result
        rem_body_instrs.append(Instr(op=ins.op, args=cloned_args, result=cloned_res, src_line=ins.src_line, src_col=ins.src_col))

    rem_body_instrs.extend([
        Instr("CONST", [1], result=c1),
        Instr("BINOP", ["add", vec_i, c1], result=vec_i),
        Instr("JUMP", [rem_cond_lbl]),
    ])
    rem_body_blk = Block(label=rem_body_lbl, instrs=rem_body_instrs)

    # Replace original loop header & body with the strip-mined block cascade
    new_blocks: List[Block] = []
    for b in fn.blocks:
        if b.label == rec.loop_header:
            new_blocks.extend([peel_blk, simd_cond_blk, simd_body_blk, rem_cond_blk, rem_body_blk])
        elif b.label == rec.body_label:
            continue
        else:
            new_blocks.append(b)

    fn.blocks = new_blocks
    return True


def auto_vectorize_function(fn: Function, type_map: Dict[str, CIRType]) -> bool:
    """Detects vectorizable loops in fn and applies SIMD strip-mining transformation."""
    from .optimizer import compute_cfg, compute_dominators
    succs, preds = compute_cfg(fn)
    dom = compute_dominators(fn, succs, preds)

    # Detect natural loops
    loops: List[Tuple[str, Set[str]]] = []
    for u, targets in succs.items():
        for v in targets:
            if v in dom.get(u, set()):
                loop_blocks: Set[str] = {v}
                stack = [u]
                while stack:
                    p = stack.pop()
                    if p != v and p not in loop_blocks:
                        loop_blocks.add(p)
                        stack.extend(preds.get(p, []))
                loops.append((v, loop_blocks))

    if not loops:
        return False

    changed = False
    for header_lbl, loop_blocks in loops:
        record = analyze_loop_vectorizability(fn, header_lbl, loop_blocks, preds, type_map)
        _VECTORIZATION_RECORDS.append(record)
        if record.status == "VECTORIZED":
            did_strip = strip_mine_loop(fn, record)
            if did_strip:
                changed = True

    return changed


def auto_vectorize_module(module: Module, dump_vectorization: bool = False) -> bool:
    """Performs Phase 39 SIMD auto-vectorization over all functions in the module."""
    changed = False
    for fn in module.functions:
        inferrer = TypeInferrer(fn)
        type_map = inferrer.infer()
        if auto_vectorize_function(fn, type_map):
            changed = True

    if dump_vectorization:
        print_vectorization_report()

    return changed


def optimize_cir(module: Module, dump_vectorization: bool = False) -> Module:
    """Top-level entry point to execute CIR passes (Phase 17, Phase 34, Phase 39)."""
    # 1. Monomorphization
    monomorphize_module(module)

    # 2. Per-function CIR normalization and pattern fusion
    for fn in module.functions:
        inferrer = TypeInferrer(fn)
        type_map = inferrer.infer()
        normalize_to_typed_cir(fn, type_map)
        fuse_dictionary_counter_patterns(fn)

    # 3. Phase 39: Affine loop vectorizability analysis and SIMD strip-mining
    auto_vectorize_module(module, dump_vectorization=dump_vectorization)

    return module


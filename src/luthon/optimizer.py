"""IR Optimizer for Luthon (Phase 8).

Performs:
1. Constant folding and constant propagation.
2. Temporary local variable reduction and copy propagation.
3. Dead code elimination (unreachable instructions, unused dead blocks, unused pure temporaries).
"""

from typing import Any, Dict, List, Set, Tuple, Optional
from .ir import Module, Function, Block, Instr


# Pure binary operations that can be folded at compile time
_LITERAL_TYPES = (int, float, bool)

_BINOP_EVAL = {
    "add": lambda a, b: a + b if (type(a) in (int, float) and type(b) in (int, float)) or (isinstance(a, str) and isinstance(b, str) and not a.startswith("_t") and not b.startswith("_t")) else None,
    "sub": lambda a, b: a - b if type(a) in (int, float) and type(b) in (int, float) else None,
    "mul": lambda a, b: a * b if type(a) in (int, float) and type(b) in (int, float) else None,
    "div": lambda a, b: a / b if type(a) in (int, float) and type(b) in (int, float) and b != 0 else None,
    "floordiv": lambda a, b: a // b if type(a) in (int, float) and type(b) in (int, float) and b != 0 else None,
    "mod": lambda a, b: a % b if type(a) in (int, float) and type(b) in (int, float) and b != 0 else None,
    "pow": lambda a, b: a ** b if (type(a) in (int, float) and type(b) in (int, float) and 0 <= b <= 1000) else None,
    "band": lambda a, b: a & b if type(a) is int and type(b) is int else None,
    "bor": lambda a, b: a | b if type(a) is int and type(b) is int else None,
    "bxor": lambda a, b: a ^ b if type(a) is int and type(b) is int else None,
    "lshift": lambda a, b: a << b if type(a) is int and type(b) is int and 0 <= b < 64 else None,
    "rshift": lambda a, b: a >> b if type(a) is int and type(b) is int and 0 <= b < 64 else None,
}

_UNOP_EVAL = {
    "neg": lambda a: -a if isinstance(a, (int, float)) else None,
    "not": lambda a: not a,
    "invert": lambda a: ~a if isinstance(a, int) else None,
}

_CMP_EVAL = {
    "eq": lambda a, b: a == b,
    "ne": lambda a, b: a != b,
    "lt": lambda a, b: a < b,
    "le": lambda a, b: a <= b,
    "gt": lambda a, b: a > b,
    "ge": lambda a, b: a >= b,
}

# Operations with no side effects whose results can be dropped if unused
_PURE_OPS = {"CONST", "LOAD", "BINOP", "UNOP", "CMP", "GET_ATTR"}


def constant_fold_function(fn: Function) -> bool:
    """Fold constant arithmetic and unary operations within blocks."""
    changed = False
    for block in fn.blocks:
        const_env: Dict[str, Any] = {}
        new_instrs: List[Instr] = []
        for ins in block.instrs:
            op = ins.op
            if op == "CONST" and ins.result:
                val = ins.args[0] if ins.args else None
                const_env[ins.result] = val
                new_instrs.append(ins)
            elif op == "LOAD" and ins.result and len(ins.args) > 0:
                const_env.pop(ins.result, None)
                new_instrs.append(ins)
            elif op == "BINOP" and ins.result and len(ins.args) >= 3:
                raw_binop = ins.args[0].lower()
                binop = raw_binop.split("__typed_")[1].rstrip("_") if "__typed_" in raw_binop else raw_binop
                left, right = ins.args[1], ins.args[2]
                left_c = const_env.get(left, left) if isinstance(left, str) else left
                right_c = const_env.get(right, right) if isinstance(right, str) else right
                folded = False
                if binop in _BINOP_EVAL and isinstance(left_c, (int, float, bool, str)) and isinstance(right_c, (int, float, bool, str)):
                    try:
                        res = _BINOP_EVAL[binop](left_c, right_c)
                        if res is not None:
                            const_env[ins.result] = res
                            new_instrs.append(Instr(op="CONST", args=[res], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                            folded = True
                            changed = True
                    except Exception:
                        pass
                if not folded:
                    const_env.pop(ins.result, None)
                    new_instrs.append(ins)
            elif op == "UNOP" and ins.result and len(ins.args) >= 2:
                unop, operand = ins.args[0].lower(), ins.args[1]
                op_c = const_env.get(operand, operand) if isinstance(operand, str) else operand
                folded = False
                if unop in _UNOP_EVAL and isinstance(op_c, (int, float, bool)):
                    try:
                        res = _UNOP_EVAL[unop](op_c)
                        if res is not None:
                            const_env[ins.result] = res
                            new_instrs.append(Instr(op="CONST", args=[res], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                            folded = True
                            changed = True
                    except Exception:
                        pass
                if not folded:
                    const_env.pop(ins.result, None)
                    new_instrs.append(ins)
            elif op == "CMP" and ins.result and len(ins.args) >= 3:
                cmpop, left, right = ins.args[0].lower(), ins.args[1], ins.args[2]
                left_c = const_env.get(left, None) if isinstance(left, str) and left in const_env else (left if not isinstance(left, str) else None)
                right_c = const_env.get(right, None) if isinstance(right, str) and right in const_env else (right if not isinstance(right, str) else None)
                folded = False
                if cmpop in _CMP_EVAL and left_c is not None and right_c is not None and isinstance(left_c, (int, float, bool, str)) and isinstance(right_c, (int, float, bool, str)):
                    try:
                        res = _CMP_EVAL[cmpop](left_c, right_c)
                        const_env[ins.result] = res
                        new_instrs.append(Instr(op="CONST", args=[res], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        folded = True
                        changed = True
                    except Exception:
                        pass
                if not folded:
                    const_env.pop(ins.result, None)
                    new_instrs.append(ins)
            elif op == "SUBSCR" and ins.result and len(ins.args) >= 2:
                idx_arg = ins.args[1]
                idx_val = const_env.get(idx_arg, idx_arg) if isinstance(idx_arg, str) else idx_arg
                if isinstance(idx_val, int) and idx_val >= 0:
                    ins.op = "SUBSCR_DIRECT"
                    ins.args[1] = idx_val
                    changed = True
                const_env.pop(ins.result, None)
                new_instrs.append(ins)
            elif op == "STORE_SUBSCR" and len(ins.args) >= 3:
                idx_arg = ins.args[1]
                idx_val = const_env.get(idx_arg, idx_arg) if isinstance(idx_arg, str) else idx_arg
                if isinstance(idx_val, int) and idx_val >= 0:
                    ins.op = "STORE_SUBSCR_DIRECT"
                    ins.args[1] = idx_val
                    changed = True
                new_instrs.append(ins)
            else:
                if ins.result:
                    const_env.pop(ins.result, None)
                new_instrs.append(ins)
        block.instrs = new_instrs
    return changed


def copy_propagate_function(fn: Function) -> bool:
    """Propagate simple temporary copies (e.g. _t2 = _t1) and eliminate single-use copies."""
    changed = False
    for block in fn.blocks:
        # Map of tmp -> alias
        aliases: Dict[str, str] = {}
        new_instrs: List[Instr] = []
        for ins in block.instrs:
            # Substitute used args if they are in aliases
            new_args = []
            for a in ins.args:
                if isinstance(a, str) and a in aliases:
                    new_args.append(aliases[a])
                    changed = True
                else:
                    new_args.append(a)
            ins.args = new_args

            # Check for LOAD: _t2 = _t1
            if ins.op == "LOAD" and ins.result and ins.result.startswith("_t"):
                src = ins.args[0]
                if isinstance(src, str) and (src.startswith("_t") or src in aliases):
                    target = aliases.get(src, src)
                    aliases[ins.result] = target
                    # Keep instruction for now; DCE will remove if unused
                    new_instrs.append(ins)
                    continue
            new_instrs.append(ins)
        block.instrs = new_instrs
    return changed


def eliminate_dead_code_function(fn: Function) -> bool:
    """Remove unreachable instructions, unreachable blocks, and unused pure temporaries."""
    changed = False

    # 1. Truncate instructions following unconditional JUMP or RETURN in each block
    # (except block containing structural markers like END_TRY, END_CATCH, END_ALL_CATCH)
    for block in fn.blocks:
        trimmed: List[Instr] = []
        for ins in block.instrs:
            trimmed.append(ins)
            if ins.op in ("JUMP", "RETURN"):
                # If block contains structural try/catch markers, keep them
                remaining_structural = [i for i in block.instrs[len(trimmed):] if i.op in ("END_TRY", "END_CATCH", "END_ALL_CATCH")]
                if remaining_structural:
                    trimmed.extend(remaining_structural)
                if len(trimmed) < len(block.instrs):
                    changed = True
                break
        block.instrs = trimmed

    # 2. Find reachable blocks starting from the entry block
    if fn.blocks:
        block_map = {b.label: b for b in fn.blocks}
        entry_label = fn.blocks[0].label
        reachable: Set[str] = {entry_label}
        queue = [entry_label]
        while queue:
            curr = queue.pop(0)
            blk = block_map.get(curr)
            if not blk:
                continue
            idx = fn.blocks.index(blk) if blk in fn.blocks else -1
            if not blk.instrs and idx != -1 and idx + 1 < len(fn.blocks):
                next_lbl = fn.blocks[idx + 1].label
                if next_lbl not in reachable:
                    reachable.add(next_lbl)
                    queue.append(next_lbl)
            for ins in blk.instrs:
                if ins.op == "JUMP" and ins.args:
                    target = ins.args[0]
                    if target not in reachable and target in block_map:
                        reachable.add(target)
                        queue.append(target)
                elif ins.op in ("BRANCH", "BRANCH_NONE", "BRANCH_TRUE", "BRANCH_FALSE") and len(ins.args) >= 2:
                    for target in ins.args[1:]:
                        if target and target not in reachable and target in block_map:
                            reachable.add(target)
                            queue.append(target)
                elif ins.op == "TRY_BEGIN":
                    # Blocks inside try/except are reachable via exception handlers or fallthrough
                    if idx != -1 and idx + 1 < len(fn.blocks):
                        next_lbl = fn.blocks[idx + 1].label
                        if next_lbl not in reachable:
                            reachable.add(next_lbl)
                            queue.append(next_lbl)
            if blk.instrs and blk.instrs[-1].op not in ("JUMP", "RETURN") and idx != -1 and idx + 1 < len(fn.blocks):
                next_lbl = fn.blocks[idx + 1].label
                if next_lbl not in reachable:
                    reachable.add(next_lbl)
                    queue.append(next_lbl)
        if len(reachable) < len(fn.blocks):
            fn.blocks = [b for b in fn.blocks if b.label in reachable]
            changed = True

    # 3. Eliminate unused pure temporaries
    # Collect all used variables
    used_vars: Set[str] = set()
    for block in fn.blocks:
        for ins in block.instrs:
            for arg in ins.args:
                if isinstance(arg, str):
                    used_vars.add(arg)
                elif isinstance(arg, (list, tuple)):
                    for sub in arg:
                        if isinstance(sub, str):
                            used_vars.add(sub)

    for block in fn.blocks:
        surviving: List[Instr] = []
        for ins in block.instrs:
            if ins.op in _PURE_OPS and ins.result and ins.result.startswith("_t"):
                if ins.result not in used_vars:
                    changed = True
                    continue  # drop dead instruction
            surviving.append(ins)
        block.instrs = surviving

    # Recompute surviving temporaries
    active_tmps = set()
    for block in fn.blocks:
        for ins in block.instrs:
            if ins.result and ins.result.startswith("_t"):
                active_tmps.add(ins.result)
            for a in ins.args:
                if isinstance(a, str) and a.startswith("_t"):
                    active_tmps.add(a)
    fn.tmps = [t for t in fn.tmps if t in active_tmps]

    return changed


def compute_cfg(fn: Function) -> Tuple[Dict[str, Set[str]], Dict[str, Set[str]]]:
    """Compute basic block successors and predecessors for a Function."""
    succs: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}
    preds: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}
    block_map = {b.label: b for b in fn.blocks}

    for idx, b in enumerate(fn.blocks):
        if not b.instrs:
            if idx + 1 < len(fn.blocks):
                succs[b.label].add(fn.blocks[idx + 1].label)
            continue
        for ins in b.instrs:
            if ins.op == "JUMP" and ins.args:
                target = ins.args[0]
                if target in succs:
                    succs[b.label].add(target)
            elif ins.op in ("BRANCH", "BRANCH_NONE", "BRANCH_TRUE", "BRANCH_FALSE") and len(ins.args) >= 2:
                for target in ins.args[1:]:
                    if target and target in succs:
                        succs[b.label].add(target)
        last = b.instrs[-1]
        if last.op not in ("JUMP", "RETURN") and idx + 1 < len(fn.blocks):
            succs[b.label].add(fn.blocks[idx + 1].label)

    for u, targets in succs.items():
        for v in targets:
            preds[v].add(u)
    return succs, preds


def compute_dominators(fn: Function, succs: Dict[str, Set[str]], preds: Dict[str, Set[str]]) -> Dict[str, Set[str]]:
    """Compute dominators for each block in fn: dom[b] is the set of labels dominating b."""
    if not fn.blocks:
        return {}
    all_blocks = {b.label for b in fn.blocks}
    entry = fn.blocks[0].label
    dom: Dict[str, Set[str]] = {b.label: set(all_blocks) for b in fn.blocks}
    dom[entry] = {entry}

    changed = True
    while changed:
        changed = False
        for b in fn.blocks:
            lbl = b.label
            if lbl == entry:
                continue
            if not preds[lbl]:
                new_dom = {lbl}
            else:
                inter = set.intersection(*(dom[p] for p in preds[lbl] if p in dom))
                new_dom = {lbl} | inter
            if new_dom != dom[lbl]:
                dom[lbl] = new_dom
                changed = True
    return dom


def simplify_algebraic_function(fn: Function) -> bool:
    """Algebraic Simplification & Strength Reduction Pass (Phase 31).

    1. Power strength reduction:
       - x ** 2 -> x * x
       - x ** 3 -> (x * x) * x
    2. Arithmetic identity simplifications:
       - x + 0 / 0 + x -> x
       - x - 0 -> x
       - x * 1 / 1 * x -> x
       - x * 0 / 0 * x -> 0
       - x / 1 / x // 1 -> x
       - x & -1 / -1 & x -> x
       - x & 0 / 0 & x -> 0
       - x | 0 / 0 | x -> x
       - x ^ 0 / 0 ^ x -> x
       - x << 0 / x >> 0 -> x
    """
    changed = False
    for block in fn.blocks:
        const_map: Dict[str, Any] = {}
        new_instrs: List[Instr] = []
        for ins in block.instrs:
            if ins.op == "CONST" and ins.result and ins.args:
                const_map[ins.result] = ins.args[0]
                new_instrs.append(ins)
                continue

            if ins.op == "BINOP" and ins.result and len(ins.args) >= 3:
                raw_binop = str(ins.args[0]).lower()
                binop = raw_binop.split("__typed_")[1].rstrip("_") if "__typed_" in raw_binop else raw_binop
                left, right = ins.args[1], ins.args[2]
                left_c = const_map.get(left, left) if isinstance(left, str) else left
                right_c = const_map.get(right, right) if isinstance(right, str) else right

                # 1. Power strength reduction (x ** 2, x ** 3)
                if binop == "pow":
                    mul_op = raw_binop.replace("pow", "mul") if raw_binop.startswith("__typed_") else "mul"
                    if right_c == 2:
                        ins.op = "BINOP"
                        ins.args = [mul_op, left, left]
                        changed = True
                        new_instrs.append(ins)
                        continue
                    elif right_c == 3:
                        sq_tmp = f"{ins.result}_sq"
                        fn.tmps.append(sq_tmp)
                        new_instrs.append(Instr(op="BINOP", args=[mul_op, left, left], result=sq_tmp, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        ins.op = "BINOP"
                        ins.args = [mul_op, sq_tmp, left]
                        changed = True
                        new_instrs.append(ins)
                        continue

                # 2. Arithmetic & bitwise identity operations
                simplified = False
                if binop == "add":
                    if left_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[right], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif right_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                elif binop == "sub":
                    if right_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                elif binop == "mul":
                    if left_c == 1:
                        new_instrs.append(Instr(op="LOAD", args=[right], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif right_c == 1:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif left_c == 0 or right_c == 0:
                        new_instrs.append(Instr(op="CONST", args=[0], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        const_map[ins.result] = 0
                        simplified = True
                elif binop in ("div", "floordiv"):
                    if right_c == 1:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                elif binop == "band":
                    if left_c == -1:
                        new_instrs.append(Instr(op="LOAD", args=[right], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif right_c == -1:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif left_c == 0 or right_c == 0:
                        new_instrs.append(Instr(op="CONST", args=[0], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        const_map[ins.result] = 0
                        simplified = True
                elif binop == "bor":
                    if left_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[right], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif right_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                elif binop == "bxor":
                    if left_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[right], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                    elif right_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True
                elif binop in ("lshift", "rshift"):
                    if right_c == 0:
                        new_instrs.append(Instr(op="LOAD", args=[left], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        simplified = True

                if simplified:
                    changed = True
                    continue

            new_instrs.append(ins)
        block.instrs = new_instrs
    return changed


def common_subexpression_elimination_function(fn: Function) -> bool:
    """Common Subexpression Elimination (CSE & GVN) Pass (Phase 31).

    Identifies duplicate pure subexpressions across instructions and dominator-reachable blocks.
    Replaces redundant computations with references to previously computed results.
    """
    changed = False
    succs, preds = compute_cfg(fn)
    dom = compute_dominators(fn, succs, preds)

    # Commutative operations where operand order does not affect result
    commutative_binops = {"add", "mul", "band", "bor", "bxor"}

    # Track available expressions: expr_key -> (result_var, defining_block_label)
    available: Dict[Tuple, Tuple[str, str]] = {}

    for block in fn.blocks:
        new_instrs: List[Instr] = []
        for ins in block.instrs:
            key = None
            if ins.op == "CONST" and ins.result and ins.args:
                val = ins.args[0]
                if isinstance(val, (int, float, str, bool)):
                    key = ("CONST", type(val).__name__, val)
            elif ins.op == "BINOP" and ins.result and len(ins.args) >= 3:
                raw_binop = str(ins.args[0]).lower()
                binop = raw_binop.split("__typed_")[1].rstrip("_") if "__typed_" in raw_binop else raw_binop
                l, r = ins.args[1], ins.args[2]
                if binop in commutative_binops:
                    sorted_args = tuple(sorted([str(l), str(r)]))
                else:
                    sorted_args = (str(l), str(r))
                key = ("BINOP", raw_binop, sorted_args)
            elif ins.op == "CMP" and ins.result and len(ins.args) >= 3:
                cmpop = str(ins.args[0]).lower()
                l, r = ins.args[1], ins.args[2]
                if cmpop in ("eq", "ne"):
                    sorted_args = tuple(sorted([str(l), str(r)]))
                else:
                    sorted_args = (str(l), str(r))
                key = ("CMP", cmpop, sorted_args)
            elif ins.op == "UNOP" and ins.result and len(ins.args) >= 2:
                key = ("UNOP", str(ins.args[0]), str(ins.args[1]))
            elif ins.op == "GET_ATTR" and ins.result and len(ins.args) >= 2:
                key = ("GET_ATTR", str(ins.args[0]), str(ins.args[1]))
            elif ins.op == "SUBSCR_DIRECT" and ins.result and len(ins.args) >= 2:
                key = ("SUBSCR_DIRECT", str(ins.args[0]), str(ins.args[1]))

            if key is not None:
                if key in available:
                    prev_res, prev_blk = available[key]
                    # Check if defining block dominates current block or is in the same block
                    if prev_blk == block.label or prev_blk in dom.get(block.label, set()):
                        # Replace with LOAD of the previous result
                        new_instrs.append(Instr(op="LOAD", args=[prev_res], result=ins.result, src_line=ins.src_line, src_col=getattr(ins, "src_col", 0)))
                        changed = True
                        continue

                available[key] = (ins.result, block.label)

            # Invalidate any cached expressions if a variable is overwritten
            if ins.op == "STORE" and len(ins.args) >= 1:
                modified = str(ins.args[0])
                keys_to_remove = [k for k in available if modified in str(k)]
                for k in keys_to_remove:
                    available.pop(k, None)
            elif ins.result:
                modified = str(ins.result)
                keys_to_remove = [k for k in available if modified in str(k) and available[k][0] != ins.result]
                for k in keys_to_remove:
                    available.pop(k, None)

            new_instrs.append(ins)
        block.instrs = new_instrs

    return changed


def loop_invariant_code_motion_function(fn: Function) -> bool:
    """Loop-Invariant Code Motion (LICM) Pass (Phase 31).

    Detects natural loops in control flow graph via dominator analysis.
    Hoists constant computations, invariant global loads, and invariant attribute fetches
    out of loop bodies into pre-headers.
    """
    if len(fn.blocks) < 2:
        return False

    changed = False
    succs, preds = compute_cfg(fn)
    dom = compute_dominators(fn, succs, preds)
    block_map = {b.label: b for b in fn.blocks}

    # 1. Identify natural loops from back-edges (u -> v where v dominates u)
    loops: List[Tuple[str, Set[str]]] = []  # (header_label, loop_block_labels)
    for b in fn.blocks:
        u = b.label
        for v in succs.get(u, set()):
            if v in dom.get(u, set()):
                # v is loop header; natural loop consists of v and nodes reaching u without passing through v
                loop_blocks: Set[str] = {v}
                if u != v:
                    loop_blocks.add(u)
                    queue = [u]
                    while queue:
                        curr = queue.pop(0)
                        for p in preds.get(curr, set()):
                            if p != v and p not in loop_blocks:
                                loop_blocks.add(p)
                                queue.append(p)
                loops.append((v, loop_blocks))

    if not loops:
        return False

    for header_lbl, loop_blocks in loops:
        header_blk = block_map.get(header_lbl)
        if not header_blk:
            continue

        # Find or create a pre-header block immediately preceding the header
        header_idx = fn.blocks.index(header_blk)
        pre_header_lbl = f"{header_lbl}_preheader"
        pre_header_blk = block_map.get(pre_header_lbl)

        if not pre_header_blk:
            # Create pre-header block
            pre_header_blk = Block(label=pre_header_lbl, instrs=[Instr(op="JUMP", args=[header_lbl])])
            fn.blocks.insert(header_idx, pre_header_blk)
            block_map[pre_header_lbl] = pre_header_blk

            # Redirect outside predecessors that jumped/branched to header_lbl
            for p_lbl in preds.get(header_lbl, set()):
                if p_lbl not in loop_blocks:
                    p_blk = block_map.get(p_lbl)
                    if p_blk:
                        for ins in p_blk.instrs:
                            if ins.op == "JUMP" and ins.args and ins.args[0] == header_lbl:
                                ins.args[0] = pre_header_lbl
                            elif ins.op in ("BRANCH", "BRANCH_NONE", "BRANCH_TRUE", "BRANCH_FALSE"):
                                ins.args = [pre_header_lbl if a == header_lbl else a for a in ins.args]

        # 2. Collect all variables defined / written within the loop
        loop_defs: Set[str] = set()
        for b_lbl in loop_blocks:
            b = block_map.get(b_lbl)
            if not b:
                continue
            for ins in b.instrs:
                if ins.result:
                    loop_defs.add(ins.result)
                if ins.op in ("STORE", "CELL_SET") and ins.args:
                    loop_defs.add(str(ins.args[0]))

        # 3. Iteratively hoist invariant instructions
        hoist_ops = {"CONST", "LOAD", "BINOP", "UNOP", "CMP", "GET_ATTR", "SUBSCR_DIRECT"}
        hoisted_any = True
        while hoisted_any:
            hoisted_any = False
            for b_lbl in loop_blocks:
                b = block_map.get(b_lbl)
                if not b:
                    continue
                retained: List[Instr] = []
                for ins in b.instrs:
                    if ins.op in hoist_ops and ins.result and ins.result.startswith("_t"):
                        # Check whether all input operands are loop-invariant (not in loop_defs)
                        is_invariant = True
                        if ins.op == "LOAD" and ins.args:
                            # Loaded variable must not be written in the loop
                            if str(ins.args[0]) in loop_defs:
                                is_invariant = False
                        elif ins.op in ("BINOP", "CMP") and len(ins.args) >= 3:
                            for arg in ins.args[1:]:
                                if isinstance(arg, str) and arg in loop_defs:
                                    is_invariant = False
                                    break
                        elif ins.op in ("UNOP", "GET_ATTR", "SUBSCR_DIRECT") and ins.args:
                            for arg in ins.args:
                                if isinstance(arg, str) and arg in loop_defs:
                                    is_invariant = False
                                    break

                        if is_invariant:
                            # Hoist to pre-header before its final jump
                            pre_header_blk.instrs.insert(len(pre_header_blk.instrs) - 1, ins)
                            loop_defs.discard(ins.result)
                            hoisted_any = True
                            changed = True
                            continue

                    retained.append(ins)
                b.instrs = retained

    return changed


def dead_store_elimination_function(fn: Function) -> bool:
    """Dead Store Elimination (DSE) Pass (Phase 31).

    Eliminates variable stores whose values are never subsequently read before reassignment
    or exit, using CFG backward liveness analysis.
    """
    # For module-level entry functions, top-level variable stores represent module exports
    # and must be preserved for external consumers.
    if getattr(fn, "is_entry_point", False):
        return False

    changed = False
    succs, preds = compute_cfg(fn)

    protected: Set[str] = set(fn.params or [])
    protected.update(getattr(fn, "cellvars", []) or [])
    protected.update(getattr(fn, "upvalues", []) or [])
    protected.update(getattr(fn, "freevars", []) or [])
    protected.update(getattr(fn, "nonlocals", []) or [])
    protected.update({"...", "self", "_exc", "_exc_matched", "_luthon_ret_val", "_luthon_has_ret"})

    # 1. Compute per-block def/use
    b_def: Dict[str, Set[str]] = {}
    b_use: Dict[str, Set[str]] = {}
    for b in fn.blocks:
        defs: Set[str] = set()
        uses: Set[str] = set()
        for ins in b.instrs:
            if ins.op == "STORE" and len(ins.args) >= 2:
                target, val = str(ins.args[0]), ins.args[1]
                if isinstance(val, str) and val not in defs:
                    uses.add(val)
                elif isinstance(val, (list, tuple)):
                    for sub in val:
                        if isinstance(sub, str) and sub not in defs:
                            uses.add(sub)
                defs.add(target)
            else:
                for arg in ins.args:
                    if isinstance(arg, str) and arg not in defs:
                        uses.add(arg)
                    elif isinstance(arg, (list, tuple)):
                        for sub in arg:
                            if isinstance(sub, str) and sub not in defs:
                                uses.add(sub)
                if ins.result:
                    defs.add(ins.result)
        b_def[b.label] = defs
        b_use[b.label] = uses

    # 2. Fixed-point backward liveness analysis
    live_in: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}
    live_out: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}

    iter_changed = True
    while iter_changed:
        iter_changed = False
        for b in reversed(fn.blocks):
            lbl = b.label
            out_set: Set[str] = set()
            for s in succs.get(lbl, set()):
                if s in live_in:
                    out_set.update(live_in[s])
            if out_set != live_out[lbl]:
                live_out[lbl] = out_set
                iter_changed = True
            in_set = b_use[lbl] | (live_out[lbl] - b_def[lbl])
            if in_set != live_in[lbl]:
                live_in[lbl] = in_set
                iter_changed = True

    # 3. Eliminate dead stores inside blocks
    for b in fn.blocks:
        live = set(live_out[b.label])
        new_instrs: List[Instr] = []
        for ins in reversed(b.instrs):
            if ins.op == "STORE" and len(ins.args) >= 2:
                target = str(ins.args[0])
                val = ins.args[1]
                if target not in protected and not target.startswith("__"):
                    # If target is not live after this store, it is dead!
                    if target not in live:
                        changed = True
                        continue

                    # Target was live; now it is defined here, so remove from live
                    live.discard(target)
                    if isinstance(val, str):
                        live.add(val)
                    elif isinstance(val, (list, tuple)):
                        for sub in val:
                            if isinstance(sub, str):
                                live.add(sub)
                    new_instrs.append(ins)
                    continue

            # Update liveness for non-STORE instructions
            if ins.result:
                live.discard(ins.result)
            for a in ins.args:
                if isinstance(a, str):
                    live.add(a)
                elif isinstance(a, (list, tuple)):
                    for sub in a:
                        if isinstance(sub, str):
                            live.add(sub)
            new_instrs.append(ins)
        b.instrs = list(reversed(new_instrs))

    return changed


def allocate_registers_function(fn: Function, max_local_registers: int = 140) -> bool:
    """Pool virtual temporaries and local variables into a bounded set of registers via CFG liveness analysis.

    Prevents large functions from exceeding LuaJIT's 200 local variable limit (LUAI_MAXVARS = 200).
    Guarantees 0 global variable leaks by reusing register slots across disjoint live ranges.
    If the chromatic number exceeds max_local_registers, extra slots spill into `_spill[...]`.
    """
    # 0. Identify candidate variables for pooling
    # Parameters, cellvars, upvalues, and nonlocals must retain fixed lexical bindings.
    protected: Set[str] = set(fn.params or [])
    protected.update(getattr(fn, "cellvars", []) or [])
    protected.update(getattr(fn, "upvalues", []) or [])
    protected.update(getattr(fn, "freevars", []) or [])
    protected.update(getattr(fn, "nonlocals", []) or [])
    protected.update({"...", "self", "_exc", "_exc_matched", "_luthon_ret_val", "_luthon_has_ret"})

    # Collect temporaries and eligible locals
    poolable: Set[str] = set()
    for t in getattr(fn, "tmps", []):
        if t not in protected:
            poolable.add(t)

    # For functions (except entry point / main when module-level globals are used),
    # local variables can also be pooled if not protected.
    if not getattr(fn, "is_entry_point", False):
        for l in getattr(fn, "locals", []):
            if l not in protected and not l.startswith("__"):
                poolable.add(l)

    # Also scan instructions for any undeclared _t... or _r... temporaries
    for b in fn.blocks:
        for ins in b.instrs:
            if ins.result and (ins.result.startswith("_t") or ins.result.startswith("_r")) and ins.result not in protected:
                poolable.add(ins.result)
            for a in ins.args:
                if isinstance(a, str) and (a.startswith("_t") or a.startswith("_r")) and a not in protected:
                    poolable.add(a)

    if not poolable:
        return False

    # 1. Build CFG successor graph
    succs: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}
    for idx, b in enumerate(fn.blocks):
        if not b.instrs:
            if idx + 1 < len(fn.blocks):
                succs[b.label].add(fn.blocks[idx + 1].label)
            continue
        last = b.instrs[-1]
        for ins in b.instrs:
            if ins.op == "JUMP" and ins.args:
                succs[b.label].add(ins.args[0])
            elif ins.op == "BRANCH" and len(ins.args) >= 3:
                succs[b.label].add(ins.args[1])
                succs[b.label].add(ins.args[2])
            elif ins.op == "BRANCH_NONE" and len(ins.args) >= 2:
                succs[b.label].add(ins.args[1])
                if idx + 1 < len(fn.blocks):
                    succs[b.label].add(fn.blocks[idx + 1].label)
            elif ins.op in ("BRANCH_TRUE", "BRANCH_FALSE") and len(ins.args) >= 2:
                succs[b.label].add(ins.args[1])
                if idx + 1 < len(fn.blocks):
                    succs[b.label].add(fn.blocks[idx + 1].label)
        if last.op not in ("JUMP", "RETURN") and idx + 1 < len(fn.blocks):
            succs[b.label].add(fn.blocks[idx + 1].label)

    # 2. Compute per-block def and use sets
    b_def: Dict[str, Set[str]] = {}
    b_use: Dict[str, Set[str]] = {}
    for b in fn.blocks:
        defs: Set[str] = set()
        uses: Set[str] = set()
        for ins in b.instrs:
            # STORE: args[0] is defined, args[1] is used
            if ins.op == "STORE" and len(ins.args) >= 2:
                target, val = ins.args[0], ins.args[1]
                if isinstance(val, str) and val in poolable and val not in defs:
                    uses.add(val)
                elif isinstance(val, (list, tuple)):
                    for sub in val:
                        if isinstance(sub, str) and sub in poolable and sub not in defs:
                            uses.add(sub)
                if isinstance(target, str) and target in poolable:
                    defs.add(target)
            elif ins.op in ("BINOP", "CMP", "UNOP") and ins.args:
                # args[0] is operator name (not a variable)
                for arg in ins.args[1:]:
                    if isinstance(arg, str) and arg in poolable and arg not in defs:
                        uses.add(arg)
                    elif isinstance(arg, (list, tuple)):
                        for sub in arg:
                            if isinstance(sub, str) and sub in poolable and sub not in defs:
                                uses.add(sub)
                if ins.result and ins.result in poolable:
                    defs.add(ins.result)
            elif ins.op == "GET_ATTR" and len(ins.args) >= 2:
                # args[0] is obj (used), args[1] is attribute name literal
                obj_arg = ins.args[0]
                if isinstance(obj_arg, str) and obj_arg in poolable and obj_arg not in defs:
                    uses.add(obj_arg)
                if ins.result and ins.result in poolable:
                    defs.add(ins.result)
            elif ins.op == "SET_ATTR" and len(ins.args) >= 3:
                # args[0] is obj (used), args[1] is attribute name literal, args[2] is val (used)
                obj_arg, val_arg = ins.args[0], ins.args[2]
                if isinstance(obj_arg, str) and obj_arg in poolable and obj_arg not in defs:
                    uses.add(obj_arg)
                if isinstance(val_arg, str) and val_arg in poolable and val_arg not in defs:
                    uses.add(val_arg)
            else:
                for arg in ins.args:
                    if isinstance(arg, str) and arg in poolable:
                        if arg not in defs:
                            uses.add(arg)
                    elif isinstance(arg, (list, tuple)):
                        for sub in arg:
                            if isinstance(sub, str) and sub in poolable and sub not in defs:
                                uses.add(sub)
                if ins.result and ins.result in poolable:
                    defs.add(ins.result)
        b_def[b.label] = defs
        b_use[b.label] = uses

    # 3. Fixed-point backward liveness analysis
    live_in: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}
    live_out: Dict[str, Set[str]] = {b.label: set() for b in fn.blocks}
    changed = True
    iterations = 0
    while changed and iterations < 100:
        iterations += 1
        changed = False
        for b in reversed(fn.blocks):
            lbl = b.label
            out_set: Set[str] = set()
            for s in succs[lbl]:
                if s in live_in:
                    out_set.update(live_in[s])
            if out_set != live_out[lbl]:
                live_out[lbl] = out_set
                changed = True
            in_set = b_use[lbl] | (live_out[lbl] - b_def[lbl])
            if in_set != live_in[lbl]:
                live_in[lbl] = in_set
                changed = True

    # 4. Build interference graph
    adj: Dict[str, Set[str]] = {t: set() for t in poolable}
    for b in fn.blocks:
        live = set(live_out[b.label])
        for ins in reversed(b.instrs):
            if ins.op == "STORE" and len(ins.args) >= 2:
                target, val = ins.args[0], ins.args[1]
                if isinstance(target, str) and target in poolable:
                    live.discard(target)
                    for other in live:
                        if other in poolable and other != target:
                            adj[target].add(other)
                            adj[other].add(target)
                if isinstance(val, str) and val in poolable:
                    live.add(val)
                elif isinstance(val, (list, tuple)):
                    for sub in val:
                        if isinstance(sub, str) and sub in poolable:
                            live.add(sub)
            elif ins.op in ("BINOP", "CMP", "UNOP") and ins.args:
                if ins.result and ins.result in poolable:
                    live.discard(ins.result)
                    for other in live:
                        if other in poolable and other != ins.result:
                            adj[ins.result].add(other)
                            adj[other].add(ins.result)
                for arg in ins.args[1:]:
                    if isinstance(arg, str) and arg in poolable:
                        live.add(arg)
                    elif isinstance(arg, (list, tuple)):
                        for sub in arg:
                            if isinstance(sub, str) and sub in poolable:
                                live.add(sub)
            elif ins.op == "GET_ATTR" and len(ins.args) >= 2:
                if ins.result and ins.result in poolable:
                    live.discard(ins.result)
                    for other in live:
                        if other in poolable and other != ins.result:
                            adj[ins.result].add(other)
                            adj[other].add(ins.result)
                obj_arg = ins.args[0]
                if isinstance(obj_arg, str) and obj_arg in poolable:
                    live.add(obj_arg)
            elif ins.op == "SET_ATTR" and len(ins.args) >= 3:
                obj_arg, val_arg = ins.args[0], ins.args[2]
                if isinstance(obj_arg, str) and obj_arg in poolable:
                    live.add(obj_arg)
                if isinstance(val_arg, str) and val_arg in poolable:
                    live.add(val_arg)
            else:
                if ins.result and ins.result in poolable:
                    live.discard(ins.result)
                    for other in live:
                        if other in poolable and other != ins.result:
                            adj[ins.result].add(other)
                            adj[other].add(ins.result)
                for arg in ins.args:
                    if isinstance(arg, str) and arg in poolable:
                        live.add(arg)
                    elif isinstance(arg, (list, tuple)):
                        for sub in arg:
                            if isinstance(sub, str) and sub in poolable:
                                live.add(sub)

    # 5. Greedy graph coloring (Welsh-Powell degree ordering)
    colors: Dict[str, int] = {}
    for t in sorted(poolable, key=lambda x: (len(adj[x]), x), reverse=True):
        neighbor_colors = {colors[nbr] for nbr in adj[t] if nbr in colors}
        color = 1
        while color in neighbor_colors:
            color += 1
        colors[t] = color

    # 6. Map colored variables to physical Lua registers (_r1 .. _rK) or spill slots
    reg_map: Dict[str, str] = {}
    has_spill = False
    for t, color in colors.items():
        if color <= max_local_registers:
            reg_map[t] = f"_r{color}"
        else:
            has_spill = True
            spill_idx = color - max_local_registers
            reg_map[t] = f"_spill[{spill_idx}]"

    # 7. Rewrite instructions to use pooled registers / spill slots
    for b in fn.blocks:
        for ins in b.instrs:
            if ins.op == "STORE" and len(ins.args) >= 2:
                target = ins.args[0]
                val = ins.args[1]
                new_target = reg_map.get(target, target) if isinstance(target, str) else target
                new_val = reg_map.get(val, val) if isinstance(val, str) else val
                ins.args[0] = new_target
                ins.args[1] = new_val
            elif ins.op in ("BINOP", "CMP", "UNOP") and ins.args:
                # In BINOP/CMP/UNOP, args[0] is the operator name (e.g. "add", "eq", "neg").
                # It must NOT be rewritten even if it happens to match a variable name!
                if ins.result and ins.result in reg_map:
                    ins.result = reg_map[ins.result]
                new_args = [ins.args[0]]
                for arg in ins.args[1:]:
                    if isinstance(arg, str) and arg in reg_map:
                        new_args.append(reg_map[arg])
                    elif isinstance(arg, (list, tuple)):
                        new_args.append([reg_map.get(sub, sub) if isinstance(sub, str) else sub for sub in arg])
                    else:
                        new_args.append(arg)
                ins.args = new_args
            elif ins.op == "GET_ATTR" and len(ins.args) >= 2:
                # In GET_ATTR, args[0] is obj, args[1] is attribute name (literal identifier).
                # args[1] must NOT be rewritten!
                if ins.result and ins.result in reg_map:
                    ins.result = reg_map[ins.result]
                obj_arg = ins.args[0]
                new_obj = reg_map.get(obj_arg, obj_arg) if isinstance(obj_arg, str) else obj_arg
                ins.args[0] = new_obj
            elif ins.op == "SET_ATTR" and len(ins.args) >= 3:
                # In SET_ATTR, args[0] is obj, args[1] is attribute name (literal identifier), args[2] is val.
                # args[1] must NOT be rewritten!
                obj_arg = ins.args[0]
                val_arg = ins.args[2]
                new_obj = reg_map.get(obj_arg, obj_arg) if isinstance(obj_arg, str) else obj_arg
                new_val = reg_map.get(val_arg, val_arg) if isinstance(val_arg, str) else val_arg
                ins.args[0] = new_obj
                ins.args[2] = new_val
            else:
                if ins.result and ins.result in reg_map:
                    ins.result = reg_map[ins.result]
                new_args = []
                for arg in ins.args:
                    if isinstance(arg, str) and arg in reg_map:
                        new_args.append(reg_map[arg])
                    elif isinstance(arg, (list, tuple)):
                        new_args.append([reg_map.get(sub, sub) if isinstance(sub, str) else sub for sub in arg])
                    else:
                        new_args.append(arg)
                ins.args = new_args

    max_c = min(max(colors.values()) if colors else 0, max_local_registers)
    fn.tmps = [f"_r{i}" for i in range(1, max_c + 1)]
    if has_spill:
        fn.tmps.append("_spill")
        # Initialize _spill = {} at entry block if spilled
        if fn.blocks and fn.blocks[0].instrs:
            fn.blocks[0].instrs.insert(0, Instr(op="MAKE_TABLE", args=[], result="_spill"))

    # Remove remapped variables from fn.locals so they don't produce redundant local declarations
    fn.locals = [l for l in getattr(fn, "locals", []) if l not in reg_map]
    return True


def optimize_function(fn: Function, max_iterations: int = 5) -> None:
    """Run iterative classical optimization passes and register allocation on a Function (Phase 31)."""
    # 1. Loop-Invariant Code Motion (hoist loop-invariant calculations into pre-headers)
    loop_invariant_code_motion_function(fn)

    # 2. Iterative optimization pipeline
    for _ in range(max_iterations):
        c1 = constant_fold_function(fn)
        c2 = simplify_algebraic_function(fn)
        c3 = common_subexpression_elimination_function(fn)
        c4 = copy_propagate_function(fn)
        c5 = eliminate_dead_code_function(fn)
        c6 = dead_store_elimination_function(fn)
        if not (c1 or c2 or c3 or c4 or c5 or c6):
            break

    # 3. Live-range register allocation (LuaJIT 200 local limit guarantee)
    allocate_registers_function(fn)


def optimize(module: Module) -> Module:
    """Run optimizer passes over all functions in the IR module."""
    try:
        from .cir import optimize_cir
        optimize_cir(module)
    except Exception:
        pass
    try:
        from .nyi import eliminate_loop_invariant_allocations
        for fn in module.functions:
            eliminate_loop_invariant_allocations(fn)
    except Exception:
        pass
    for fn in module.functions:
        optimize_function(fn)
    return module

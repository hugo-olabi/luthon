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


def allocate_registers_function(fn: Function) -> bool:
    """Pool virtual temporaries into a bounded set of registers via CFG liveness analysis.

    Prevents large functions from exceeding LuaJIT's 200 local variable limit (LUAI_MAXVARS).
    """
    all_tmps = set(fn.tmps)
    if not all_tmps:
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
        if last.op not in ("JUMP", "RETURN") and idx + 1 < len(fn.blocks):
            succs[b.label].add(fn.blocks[idx + 1].label)

    # 2. Compute per-block def and use sets
    b_def: Dict[str, Set[str]] = {}
    b_use: Dict[str, Set[str]] = {}
    for b in fn.blocks:
        defs: Set[str] = set()
        uses: Set[str] = set()
        for ins in b.instrs:
            for arg in ins.args:
                if isinstance(arg, str) and arg in all_tmps:
                    if arg not in defs:
                        uses.add(arg)
                elif isinstance(arg, (list, tuple)):
                    for sub in arg:
                        if isinstance(sub, str) and sub in all_tmps and sub not in defs:
                            uses.add(sub)
            if ins.result and ins.result in all_tmps:
                defs.add(ins.result)
        b_def[b.label] = defs
        b_use[b.label] = uses

    # 3. Fixed-point liveness analysis
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
    adj: Dict[str, Set[str]] = {t: set() for t in all_tmps}
    for b in fn.blocks:
        live = set(live_out[b.label])
        for ins in reversed(b.instrs):
            if ins.result and ins.result in all_tmps:
                live.discard(ins.result)
                for other in live:
                    if other in all_tmps:
                        adj[ins.result].add(other)
                        adj[other].add(ins.result)
            for arg in ins.args:
                if isinstance(arg, str) and arg in all_tmps:
                    live.add(arg)
                elif isinstance(arg, (list, tuple)):
                    for sub in arg:
                        if isinstance(sub, str) and sub in all_tmps:
                            live.add(sub)

    # 5. Greedy graph coloring
    colors: Dict[str, int] = {}
    for t in sorted(all_tmps, key=lambda x: (len(adj[x]), x), reverse=True):
        neighbor_colors = {colors[nbr] for nbr in adj[t] if nbr in colors}
        color = 1
        while color in neighbor_colors:
            color += 1
        colors[t] = color

    reg_map = {t: f"_r{color}" for t, color in colors.items()}

    # 6. Rewrite instructions to use pooled registers
    for b in fn.blocks:
        for ins in b.instrs:
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

    max_c = max(colors.values()) if colors else 0
    fn.tmps = [f"_r{i}" for i in range(1, max_c + 1)]
    return True


def optimize_function(fn: Function, max_iterations: int = 5) -> None:
    """Run iterative optimization and register allocation on a Function."""
    for _ in range(max_iterations):
        c1 = constant_fold_function(fn)
        c2 = copy_propagate_function(fn)
        c3 = eliminate_dead_code_function(fn)
        if not (c1 or c2 or c3):
            break
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

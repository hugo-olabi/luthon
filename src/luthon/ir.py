"""IR for Luthon (Phase 3): instruction-level lowering with control flow.

Lowerer walks a Python AST and produces a Module of Functions, each with
basic blocks of instructions. Conditionals/loops become branch + label blocks.
"""

from dataclasses import dataclass, field
import ast
from typing import List, Optional, Tuple


@dataclass
class Instr:
    op: str
    args: list = field(default_factory=list)
    result: Optional[str] = None
    src_line: int = 0
    src_col: int = 0


@dataclass
class Block:
    label: str
    instrs: List[Instr] = field(default_factory=list)


@dataclass
class Function:
    name: str
    params: List[str] = field(default_factory=list)
    blocks: List[Block] = field(default_factory=list)
    locals: List[str] = field(default_factory=list)
    tmps: List[str] = field(default_factory=list)
    freevars: List[str] = field(default_factory=list)
    cellvars: List[str] = field(default_factory=list)
    upvalues: List[str] = field(default_factory=list)
    nonlocals: List[str] = field(default_factory=list)
    is_entry_point: bool = False
    is_nested: bool = False
    param_annotations: dict = field(default_factory=dict)
    param_types: dict = field(default_factory=dict)


@dataclass
class Module:
    name: str
    functions: List[Function] = field(default_factory=list)
    globals: List[str] = field(default_factory=list)
    instrs: List[Instr] = field(default_factory=list)
    blocks: List[Block] = field(default_factory=list)
    native_structs: List[Tuple[str, str, List[str]]] = field(default_factory=list)


LUA_RESERVED_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}


def _safe_var(name: str) -> str:
    if name in LUA_RESERVED_KEYWORDS:
        return f"_py_{name}"
    return name


def _has_yield(node: ast.AST) -> bool:
    for child in ast.iter_child_nodes(node):
        if isinstance(child, (ast.Yield, ast.YieldFrom)):
            return True
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if _has_yield(child):
            return True
    return False


class IRLowerer:
    def __init__(self, package: str = ""):
        self._tmp = 0
        self.module = Module(name="<module>")
        self.package = package or ""
        self._cur_fn: Optional[Function] = None
        self._cur_block: Optional[Block] = None
        self._cur_node: Optional[ast.AST] = None
        self._label_counter = 0
        self._fn_counter = {}
        self._break_stack = []
        self._continue_stack = []
        self._try_depth = 0
        self._imported_modules = set()

    def _new_tmp(self):
        self._tmp += 1
        t = f"_t{self._tmp}"
        if self._cur_fn is not None:
            self._cur_fn.tmps.append(t)
        return t

    def _new_label(self, prefix="L"):
        self._label_counter += 1
        return f"{prefix}{self._label_counter}"

    def _emit(self, op, args=None, result=None, src_line=0, src_col=0):
        if src_line == 0 and hasattr(self, "_cur_node") and self._cur_node is not None:
            src_line = getattr(self._cur_node, "lineno", 0)
            src_col = getattr(self._cur_node, "col_offset", 0)
        ins = Instr(op=op, args=list(args or []), result=result, src_line=src_line, src_col=src_col)
        self._cur_block.instrs.append(ins)
        return ins

    def _new_block(self, label):
        b = Block(label=label)
        self._cur_fn.blocks.append(b)
        return b

    def lower_module(self, node, scope=None):
        # module-level instructions go into a synthetic function? Keep as module instrs/blocks
        fn = Function(name="main", is_entry_point=True)
        self._cur_fn = fn
        b = Block(label="entry")
        fn.blocks.append(b)
        self._cur_block = b
        for stmt in node.body:
            self.lower_stmt(stmt)
        self.module.functions.append(fn)
        if scope is not None:
            fn.locals = sorted(scope.locals.keys())
            self.module.globals = sorted(scope.locals.keys())
        return self.module

    def lower_stmt(self, node):
        prev_node = self._cur_node
        self._cur_node = node
        try:
            self._lower_stmt_impl(node)
        finally:
            self._cur_node = prev_node

    def _lower_target(self, tgt, val_tmp):
        if isinstance(tgt, (ast.Tuple, ast.List)):
            has_starred = any(isinstance(e, ast.Starred) for e in tgt.elts)
            if not has_starred:
                for i, e in enumerate(tgt.elts):
                    idx_tmp = self._new_tmp()
                    self._emit("CONST", [i], result=idx_tmp)
                    elem_tmp = self._new_tmp()
                    self._emit("SUBSCR", [val_tmp, idx_tmp], result=elem_tmp)
                    self._lower_target(e, elem_tmp)
            else:
                star_idx = next(i for i, e in enumerate(tgt.elts) if isinstance(e, ast.Starred))
                num_trail = len(tgt.elts) - 1 - star_idx
                for i in range(star_idx):
                    idx_tmp = self._new_tmp()
                    self._emit("CONST", [i], result=idx_tmp)
                    elem_tmp = self._new_tmp()
                    self._emit("SUBSCR", [val_tmp, idx_tmp], result=elem_tmp)
                    self._lower_target(tgt.elts[i], elem_tmp)
                for j in range(1, num_trail + 1):
                    idx_tmp = self._new_tmp()
                    self._emit("CONST", [-j], result=idx_tmp)
                    elem_tmp = self._new_tmp()
                    self._emit("SUBSCR", [val_tmp, idx_tmp], result=elem_tmp)
                    self._lower_target(tgt.elts[len(tgt.elts) - j], elem_tmp)
                star_elem = tgt.elts[star_idx]
                slice_tmp = self._new_tmp()
                if num_trail > 0:
                    self._emit("CALL", ["_luthon_slice", val_tmp, str(star_idx), str(-num_trail)], result=slice_tmp)
                else:
                    self._emit("CALL", ["_luthon_slice", val_tmp, str(star_idx)], result=slice_tmp)
                self._lower_target(star_elem.value, slice_tmp)
        elif isinstance(tgt, ast.Starred):
            self._lower_target(tgt.value, val_tmp)
        elif isinstance(tgt, ast.Name):
            safe_name = _safe_var(tgt.id)
            if self._cur_fn is not None and (tgt.id in getattr(self._cur_fn, "cellvars", []) or tgt.id in getattr(self._cur_fn, "freevars", [])):
                self._emit("CELL_SET", [safe_name, val_tmp])
            else:
                self._emit("STORE", [safe_name, val_tmp])
        elif isinstance(tgt, ast.Subscript):
            base = self.lower_expr(tgt.value)
            sl = self.lower_expr(tgt.slice)
            self._emit("STORE_SUBSCR", [base, sl, val_tmp])
        elif isinstance(tgt, ast.Attribute):
            obj = self.lower_expr(tgt.value)
            attr = tgt.attr
            if attr in LUA_RESERVED_KEYWORDS:
                self._emit("STORE_SUBSCR", [obj, f'"{attr}"', val_tmp])
            else:
                self._emit("SET_ATTR", [obj, attr, val_tmp])

    def _lower_stmt_impl(self, node):
        if isinstance(node, ast.Expr):
            if isinstance(node.value, ast.YieldFrom):
                it_tmp = self.lower_expr(node.value.value)
                iter_fn = self._new_tmp()
                self._emit("LOAD", ["iter"], result=iter_fn)
                nxt_iter = self._new_tmp()
                self._emit("CALL", [iter_fn, it_tmp], result=nxt_iter)
                loop_lbl = self._new_label("yfrom_loop")
                body_lbl = self._new_label("yfrom_body")
                end_lbl = self._new_label("yfrom_end")
                self._emit("JUMP", [loop_lbl])
                self._cur_block = self._new_block(loop_lbl)
                val = self._new_tmp()
                self._emit("NEXT", [nxt_iter], result=val)
                self._emit("BRANCH_NONE", [val, end_lbl])
                self._cur_block = self._new_block(body_lbl)
                self._emit("CALL", ["coroutine.yield", val], result=self._new_tmp())
                self._emit("JUMP", [loop_lbl])
                self._cur_block = self._new_block(end_lbl)
            else:
                self.lower_expr(node.value)
        elif isinstance(node, ast.Assign):
            val = self.lower_expr(node.value)
            for t in node.targets:
                self._lower_target(t, val)
        elif isinstance(node, ast.AugAssign):
            lhs = self.lower_expr(node.target)
            rhs = self.lower_expr(node.value)
            res = self._new_tmp()
            self._emit("BINOP", [self._binop(node.op), lhs, rhs], result=res)
            if isinstance(node.target, ast.Name):
                self._emit("STORE", [_safe_var(node.target.id), res])
            elif isinstance(node.target, ast.Attribute):
                val = self.lower_expr(node.target.value)
                self._emit("SET_ATTR", [val, node.target.attr, res])
            elif isinstance(node.target, ast.Subscript):
                val = self.lower_expr(node.target.value)
                idx = self.lower_expr(node.target.slice)
                self._emit("STORE_SUBSCR", [val, idx, res])
        elif isinstance(node, ast.Return):
            val = self.lower_expr(node.value) if node.value else None
            if self._try_depth > 0:
                self._emit("TRY_RETURN", [val] if val else [])
            else:
                self._emit("RETURN", [val] if val else [])
        elif isinstance(node, ast.If):
            cond = self.lower_expr(node.test)
            # Ensure boolean truthiness check if cond is not already boolean
            chk_cond = self._new_tmp()
            self._emit("CALL", ["bool", cond], result=chk_cond)
            then_lbl = self._new_label("then")
            else_lbl = self._new_label("else")
            end_lbl = self._new_label("endif")
            self._emit("BRANCH", [chk_cond, then_lbl, else_lbl])
            # then
            self._cur_block = self._new_block(then_lbl)
            for s in node.body:
                self.lower_stmt(s)
            if not node.body or not isinstance(node.body[-1], ast.Return):
                self._emit("JUMP", [end_lbl])
            # else
            self._cur_block = self._new_block(else_lbl)
            for s in node.orelse:
                self.lower_stmt(s)
            if not node.orelse or not isinstance(node.orelse[-1], ast.Return):
                self._emit("JUMP", [end_lbl])
            self._cur_block = self._new_block(end_lbl)
        elif isinstance(node, ast.While):
            cond_lbl = self._new_label("whilecond")
            body_lbl = self._new_label("whilebody")
            end_lbl = self._new_label("whileend")
            self._break_stack.append(end_lbl)
            self._continue_stack.append(cond_lbl)
            self._emit("JUMP", [cond_lbl])
            self._cur_block = self._new_block(cond_lbl)
            cond = self.lower_expr(node.test)
            self._emit("BRANCH", [cond, body_lbl, end_lbl])
            self._cur_block = self._new_block(body_lbl)
            for s in node.body:
                self.lower_stmt(s)
            self._emit("JUMP", [cond_lbl])
            if self._break_stack:
                self._break_stack.pop()
            if self._continue_stack:
                self._continue_stack.pop()
            self._cur_block = self._new_block(end_lbl)
        elif isinstance(node, (ast.For, ast.AsyncFor)):
            iter_tmp = self._new_tmp()
            self._emit("CALL", ["iter", self.lower_expr(node.iter)], result=iter_tmp)
            cond_lbl = self._new_label("forcond")
            body_lbl = self._new_label("forbody")
            end_lbl = self._new_label("forend")
            self._break_stack.append(end_lbl)
            self._continue_stack.append(cond_lbl)
            self._emit("JUMP", [cond_lbl])
            self._cur_block = self._new_block(cond_lbl)
            nxt = self._new_tmp()
            self._emit("NEXT", [iter_tmp], result=nxt)
            self._emit("BRANCH_NONE", [nxt, end_lbl])
            if isinstance(node.target, ast.Name):
                safe_target = _safe_var(node.target.id)
                if self._cur_fn is not None and (node.target.id in getattr(self._cur_fn, "cellvars", []) or node.target.id in getattr(self._cur_fn, "freevars", [])):
                    self._emit("CELL_SET", [safe_target, nxt])
                else:
                    self._emit("STORE", [safe_target, nxt])
            elif isinstance(node.target, (ast.Tuple, ast.List)):
                for i, t in enumerate(node.target.elts):
                    if isinstance(t, ast.Name):
                        safe_t = _safe_var(t.id)
                        idx_tmp = self._new_tmp()
                        self._emit("CONST", [i], result=idx_tmp)
                        elem_tmp = self._new_tmp()
                        self._emit("SUBSCR", [nxt, idx_tmp], result=elem_tmp)
                        if self._cur_fn is not None and (t.id in getattr(self._cur_fn, "cellvars", []) or t.id in getattr(self._cur_fn, "freevars", [])):
                            self._emit("CELL_SET", [safe_t, elem_tmp])
                        else:
                            self._emit("STORE", [safe_t, elem_tmp])
            self._emit("JUMP", [body_lbl])
            self._cur_block = self._new_block(body_lbl)
            for s in node.body:
                self.lower_stmt(s)
            self._emit("JUMP", [cond_lbl])
            if self._break_stack:
                self._break_stack.pop()
            if self._continue_stack:
                self._continue_stack.pop()
            self._cur_block = self._new_block(end_lbl)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fn_sym = node.name
            count = self._fn_counter.get(node.name, 0) + 1
            self._fn_counter[node.name] = count
            unique_fn_name = node.name if count == 1 else f"{node.name}_{count}"
            params = [_safe_var(a.arg) for a in node.args.args]
            if node.args.vararg or node.args.kwarg:
                params.append("...")
            is_nested = (self._cur_fn is not None and not getattr(self._cur_fn, "is_entry_point", False))
            fn = Function(name=unique_fn_name, params=params)
            fn.is_nested = is_nested
            fn.param_annotations = {_safe_var(a.arg): a.annotation for a in node.args.args if getattr(a, "annotation", None) is not None}
            sc = getattr(node, "_scope", None)
            if sc is not None:
                fn.locals = sorted(_safe_var(k) for k in sc.locals.keys())
                fn.freevars = sorted(_safe_var(k) for k in getattr(sc, "freevars", set()))
                fn.cellvars = sorted(_safe_var(k) for k in getattr(sc, "cellvars", set()))
                fn.upvalues = list(fn.freevars)
            # Find nonlocal declarations in function body
            fn_nonlocals = set()
            for stmt in node.body:
                if isinstance(stmt, ast.Nonlocal):
                    fn_nonlocals.update(stmt.names)
            fn.nonlocals = sorted(fn_nonlocals)
            prev_fn = self._cur_fn
            prev_block = self._cur_block
            prev_try_depth = self._try_depth
            self._try_depth = 0
            self._cur_fn = fn
            b = Block(label="entry")
            fn.blocks.append(b)
            self._cur_block = b
            # If vararg is present, pack into a table
            if node.args.vararg:
                vararg_name = _safe_var(node.args.vararg.arg)
                t_dots = self._new_tmp()
                self._emit("CALL", ["_tuple_pack", "..."], result=t_dots)
                self._emit("STORE", [vararg_name, t_dots])
            # If kwarg is present, initialize table
            if node.args.kwarg:
                kwarg_name = _safe_var(node.args.kwarg.arg)
                t_kw = self._new_tmp()
                self._emit("CALL", ["_luthon_extract_kwargs", "..."], result=t_kw)
                self._emit("STORE", [kwarg_name, t_kw])
            # initialize cell boxes for captured variables
            for cv in getattr(fn, "cellvars", []):
                cell = self._new_tmp()
                self._emit("MAKE_CELL", [cv], result=cell)
                self._emit("STORE", [cv, cell])

            # Unpack default parameter values
            args_list = node.args.args
            defaults = node.args.defaults
            if defaults:
                offset = len(args_list) - len(defaults)
                for i, default in enumerate(defaults):
                    param_name = _safe_var(args_list[offset + i].arg)
                    def_tmp = self.lower_expr(default)
                    is_nil_lbl = self._new_label("def_set")
                    skip_lbl = self._new_label("def_skip")
                    chk_tmp = self._new_tmp()
                    self._emit("CMP", ["eq", param_name, "nil"], result=chk_tmp)
                    self._emit("BRANCH", [chk_tmp, is_nil_lbl, skip_lbl])
                    self._cur_block = self._new_block(is_nil_lbl)
                    self._emit("STORE", [param_name, def_tmp])
                    self._emit("JUMP", [skip_lbl])
                    self._cur_block = self._new_block(skip_lbl)

            for s in node.body:
                self.lower_stmt(s)
            if not node.body or not isinstance(node.body[-1], ast.Return):
                self._emit("RETURN", [])
            is_gen = _has_yield(node)
            is_async = isinstance(node, ast.AsyncFunctionDef)

            if is_gen or is_async:
                wrapper_type = "make_generator" if is_gen else "make_coroutine"
                impl_name = fn.name + "_impl"
                fn.name = impl_name
                fn.is_nested = is_nested
                self.module.functions.append(fn)

                # Create wrapper function that returns a generator or coroutine thread
                wrapper_params = [_safe_var(a.arg) for a in node.args.args]
                if node.args.vararg:
                    wrapper_params.append("...")
                wrapper_fn = Function(name=unique_fn_name, params=wrapper_params)
                wrapper_fn.is_nested = is_nested
                sc = getattr(node, "_scope", None)
                if sc is not None:
                    wrapper_fn.freevars = sorted(getattr(sc, "freevars", set()))
                    wrapper_fn.cellvars = sorted(getattr(sc, "cellvars", set()))
                    wrapper_fn.upvalues = list(wrapper_fn.freevars)
                wrapper_block = Block(label="entry")
                wrapper_fn.blocks.append(wrapper_block)
                self._cur_fn = wrapper_fn
                self._cur_block = wrapper_block

                # Call make_generator/make_coroutine(impl_name, arg1, arg2, ...)
                res_tmp = self._new_tmp()
                call_args = [wrapper_type, impl_name] + [p for p in wrapper_params]
                self._emit("CALL", call_args, result=res_tmp)
                self._emit("RETURN", [res_tmp])
                self.module.functions.append(wrapper_fn)

                self._cur_fn = prev_fn
                self._cur_block = prev_block
            else:
                self.module.functions.append(fn)
                self._cur_fn = prev_fn
                self._cur_block = prev_block
            self._try_depth = prev_try_depth

            if is_nested:
                fn_tmp = self._new_tmp()
                self._emit("MAKE_FUNCTION", [unique_fn_name], result=fn_tmp)
                self._emit("STORE", [_safe_var(fn_sym), fn_tmp])
                fn_ref = fn_tmp
            else:
                self._emit("STORE", [_safe_var(fn_sym), unique_fn_name])
                fn_ref = unique_fn_name

            clean_params = [p for p in params if p != "..."]
            if clean_params:
                param_tuple = self._new_tmp()
                self._emit("MAKE_TUPLE", [f'"{p}"' for p in clean_params], result=param_tuple)
                self._emit("CALL", ["_luthon_reg_fn", fn_ref, param_tuple])
            # Apply decorators (innermost first)
            for dec in reversed(node.decorator_list):
                dec_tmp = self.lower_expr(dec)
                dec_target = self._new_tmp()
                self._emit("LOAD", [_safe_var(fn_sym)], result=dec_target)
                result_tmp = self._new_tmp()
                self._emit("CALL", [dec_tmp, dec_target], result=result_tmp)
                self._emit("STORE", [_safe_var(fn_sym), result_tmp])
        elif isinstance(node, ast.Import):
            for alias in node.names:
                name = alias.asname or alias.name.split(".")[0]
                self._imported_modules.add(name)
                self._imported_modules.add(alias.name)
                if alias.asname:
                    # Explicit alias: import a.b as c -> c = _luthon_import("a.b")
                    self._emit("IMPORT", [name, alias.name])
                else:
                    # Dotted without alias: import a.b -> a = _luthon_import("a", "a.b")
                    self._emit("IMPORT", [name, name, alias.name])
        elif isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            level = getattr(node, "level", 0) or 0
            if level > 0 and self.package:
                pkg_parts = self.package.split(".")
                if level <= len(pkg_parts):
                    base = pkg_parts[:len(pkg_parts) - (level - 1)]
                    if mod:
                        base.append(mod)
                    mod = ".".join(base)
                elif mod:
                    mod = f"{self.package}.{mod}"
            elif level > 0 and not mod:
                mod = self.package
            for alias in node.names:
                name = alias.asname or alias.name
                self._imported_modules.add(name)
                self._emit("IMPORT_FROM", [name, mod, alias.name])
        elif isinstance(node, ast.Pass):
            pass
        elif isinstance(node, ast.Try):
            if node.finalbody and (node.handlers or node.orelse):
                inner = ast.Try(body=node.body, handlers=node.handlers, orelse=node.orelse, finalbody=[])
                outer = ast.Try(body=[inner], handlers=[], orelse=[], finalbody=node.finalbody)
                self.lower_stmt(outer)
                return

            if node.finalbody:
                try_label = self._new_label("try")
                try_block = self._new_block(try_label)
                self._cur_block = try_block
                self._emit("TRY_BEGIN", [], result=self._new_tmp())
                self._try_depth += 1
                for s in node.body:
                    self.lower_stmt(s)
                self._try_depth -= 1
                self._emit("FINALLY_BEGIN", [], result=self._new_tmp())
                finally_label = self._new_label("finally")
                self._cur_block = self._new_block(finally_label)
                for s in node.finalbody:
                    self.lower_stmt(s)
                self._emit("FINALLY_END", [], result=self._new_tmp())
                end_label = self._new_label("end_try")
                self._cur_block = self._new_block(end_label)
                self._emit("TRY_UNWIND", [str(self._try_depth)])
                return

            try_label = self._new_label("try")
            try_block = self._new_block(try_label)
            self._cur_block = try_block
            self._emit("TRY_BEGIN", [], result=self._new_tmp())
            self._try_depth += 1
            for s in node.body:
                self.lower_stmt(s)
            self._try_depth -= 1
            self._emit("END_TRY", [], result=self._new_tmp())
            for h in node.handlers:
                handler_lbl = self._new_label("except")
                self._cur_block = self._new_block(handler_lbl)
                if h.type is not None:
                    type_tmp = self.lower_expr(h.type)
                    self._emit("CATCH_BEGIN", [type_tmp], result=self._new_tmp())
                else:
                    self._emit("CATCH_BEGIN", [], result=self._new_tmp())
                if h.name:
                    self._emit("STORE", [h.name, "_exc"])
                prev_exc = getattr(self, "_active_exc", None)
                self._active_exc = "_exc"
                for s in h.body:
                    self.lower_stmt(s)
                self._active_exc = prev_exc
                self._emit("END_CATCH", [], result=self._new_tmp())
            self._emit("END_ALL_CATCH", [], result=self._new_tmp())
            if node.orelse:
                self._emit("TRY_ELSE", [], result=self._new_tmp())
                for s in node.orelse:
                    self.lower_stmt(s)
                self._emit("END_TRY_ELSE", [], result=self._new_tmp())
            self._emit("TRY_CLOSE", [], result=self._new_tmp())
            end_label = self._new_label("end_try")
            self._cur_block = self._new_block(end_label)
            self._emit("TRY_UNWIND", [str(self._try_depth)])
        elif isinstance(node, ast.ClassDef):
            # Check for @dataclass or @struct / @native_struct decorator
            is_dataclass = False
            is_native_struct = False
            for dec in node.decorator_list:
                dec_id = dec.id if isinstance(dec, ast.Name) else (dec.attr if isinstance(dec, ast.Attribute) else None)
                if isinstance(dec, ast.Call):
                    dec_id = dec.func.id if isinstance(dec.func, ast.Name) else (dec.func.attr if isinstance(dec.func, ast.Attribute) else None)
                if dec_id == "dataclass":
                    is_dataclass = True
                elif dec_id in ("struct", "native_struct", "cstruct"):
                    is_native_struct = True
                    is_dataclass = True

            # Collect fields from annotated assignments
            fields = []  # list of dicts: {"name": str, "default_tmp": tmp or None, "has_default": bool}
            for stmt in node.body:
                if isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
                    field_name = stmt.target.id
                    default_tmp = None
                    has_default = False
                    if stmt.value is not None:
                        default_tmp = self.lower_expr(stmt.value)
                        has_default = True
                    fields.append({"name": field_name, "default_tmp": default_tmp, "has_default": has_default})

            # create class table
            cls = self._new_tmp()
            self._emit("MAKE_CLASS", [node.name], result=cls)

            # Set base class if inheritance is used
            if node.bases:
                base_tmp = self.lower_expr(node.bases[0])
                self._emit("SET_ATTR", [node.name, "__base__", base_tmp])

            # Set __name__ and __dataclass_fields__ on class
            name_tmp = self._new_tmp()
            self._emit("CONST", [node.name], result=name_tmp)
            self._emit("SET_ATTR", [node.name, "__name__", name_tmp])
            if is_dataclass and fields:
                fields_list = [f["name"] for f in fields]
                fields_tmp = self._new_tmp()
                self._emit("MAKE_LIST", fields_list, result=fields_tmp)
                self._emit("SET_ATTR", [node.name, "__dataclass_fields__", fields_tmp])

            # Lower class-level variable assignments
            for stmt in node.body:
                if isinstance(stmt, ast.Assign):
                    val = self.lower_expr(stmt.value)
                    for t in stmt.targets:
                        if isinstance(t, ast.Name):
                            self._emit("SET_ATTR", [node.name, _safe_var(t.id), val])
                elif isinstance(stmt, ast.AnnAssign) and stmt.value is not None:
                    if isinstance(stmt.target, ast.Name):
                        val = self.lower_expr(stmt.value)
                        self._emit("SET_ATTR", [node.name, _safe_var(stmt.target.id), val])

            # lower existing methods and track which dunder methods exist
            has_init = False
            has_repr = False
            has_eq = False
            prev_cur_class = getattr(self, "_cur_class", None)
            self._cur_class = node.name
            method_counts = {}
            for stmt in node.body:
                if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    method_counts[stmt.name] = method_counts.get(stmt.name, 0) + 1
                    count = method_counts[stmt.name]
                    fn_subname = stmt.name if count == 1 else f"{stmt.name}_{count}"
                    if stmt.name == "__init__":
                        has_init = True
                    if stmt.name == "__repr__":
                        has_repr = True
                    if stmt.name == "__eq__":
                        has_eq = True
                    prev_method_first_arg = getattr(self, "_cur_method_first_arg", None)
                    self._cur_method_first_arg = stmt.args.args[0].arg if stmt.args.args else None
                    params = [_safe_var(a.arg) for a in stmt.args.args]
                    if stmt.args.vararg or stmt.args.kwarg:
                        params.append("...")
                    fn = Function(name=node.name + "." + fn_subname, params=params)
                    sc = getattr(stmt, "_scope", None)
                    if sc is not None:
                        fn.locals = sorted(_safe_var(k) for k in sc.locals.keys())
                        fn.freevars = sorted(_safe_var(k) for k in getattr(sc, "freevars", set()))
                        fn.cellvars = sorted(_safe_var(k) for k in getattr(sc, "cellvars", set()))
                        fn.upvalues = list(fn.freevars)
                    prev_fn = self._cur_fn
                    prev_block = self._cur_block
                    prev_try_depth = self._try_depth
                    self._try_depth = 0
                    self._cur_fn = fn
                    b = Block(label="entry")
                    fn.blocks.append(b)
                    self._cur_block = b
                    # initialize cell boxes for captured variables
                    for cv in getattr(fn, "cellvars", []):
                        cell = self._new_tmp()
                        self._emit("MAKE_CELL", [cv], result=cell)
                        self._emit("STORE", [cv, cell])
                    # If vararg is present, pack into a table
                    if stmt.args.vararg:
                        vararg_name = _safe_var(stmt.args.vararg.arg)
                        t_dots = self._new_tmp()
                        self._emit("CALL", ["_tuple_pack", "..."], result=t_dots)
                        self._emit("STORE", [vararg_name, t_dots])
                    # If kwarg is present, initialize table
                    if stmt.args.kwarg:
                        kwarg_name = _safe_var(stmt.args.kwarg.arg)
                        t_kw = self._new_tmp()
                        self._emit("CALL", ["_luthon_extract_kwargs", "..."], result=t_kw)
                        self._emit("STORE", [kwarg_name, t_kw])
                    for s2 in stmt.body:
                        self.lower_stmt(s2)
                    if not stmt.body or not isinstance(stmt.body[-1], ast.Return):
                        self._emit("RETURN", [])

                    is_gen = _has_yield(stmt)
                    is_async = isinstance(stmt, ast.AsyncFunctionDef)

                    if is_gen or is_async:
                        wrapper_type = "make_generator" if is_gen else "make_coroutine"
                        impl_name = node.name + "." + fn_subname + "_impl"
                        fn.name = impl_name
                        self.module.functions.append(fn)

                        wrapper_fn = Function(name=node.name + "." + fn_subname, params=list(params))
                        if sc is not None:
                            wrapper_fn.freevars = sorted(getattr(sc, "freevars", set()))
                            wrapper_fn.cellvars = sorted(getattr(sc, "cellvars", set()))
                            wrapper_fn.upvalues = list(wrapper_fn.freevars)
                        wrapper_block = Block(label="entry")
                        wrapper_fn.blocks.append(wrapper_block)
                        self._cur_fn = wrapper_fn
                        self._cur_block = wrapper_block

                        res_tmp = self._new_tmp()
                        call_args = [wrapper_type, impl_name] + [p for p in params]
                        self._emit("CALL", call_args, result=res_tmp)
                        self._emit("RETURN", [res_tmp])
                        self.module.functions.append(wrapper_fn)

                        self._cur_fn = prev_fn
                        self._cur_block = prev_block
                    else:
                        self.module.functions.append(fn)
                        self._cur_fn = prev_fn
                        self._cur_block = prev_block
                    self._try_depth = prev_try_depth
                    self._cur_method_first_arg = prev_method_first_arg

                    # Register method parameters for keyword call resolution
                    clean_params = [p for p in params if p != "..."]
                    if clean_params:
                        param_tuple = self._new_tmp()
                        self._emit("MAKE_TUPLE", [f'"{p}"' for p in clean_params], result=param_tuple)
                        self._emit("CALL", ["_luthon_reg_fn", f"{node.name}.{fn_subname}", param_tuple])
                    if stmt.name == "__init__":
                        init_params = [p for p in clean_params[1:]]
                        if init_params:
                            cls_param_tuple = self._new_tmp()
                            self._emit("MAKE_TUPLE", [f'"{p}"' for p in init_params], result=cls_param_tuple)
                            self._emit("CALL", ["_luthon_reg_fn", node.name, cls_param_tuple])

                    # Apply decorators on class method (innermost first)
                    if stmt.decorator_list:
                        for dec in reversed(stmt.decorator_list):
                            if isinstance(dec, ast.Name) and dec.id == "property":
                                prop_tmp = self._new_tmp()
                                prop_ref = f'{node.name}["{fn_subname}"]' if fn_subname in LUA_RESERVED_KEYWORDS else f"{node.name}.{fn_subname}"
                                self._emit("CALL", ["property", prop_ref], result=prop_tmp)
                                if stmt.name in LUA_RESERVED_KEYWORDS:
                                    self._emit("STORE_SUBSCR", [node.name, f'"{stmt.name}"', prop_tmp])
                                else:
                                    self._emit("SET_ATTR", [node.name, stmt.name, prop_tmp])
                            elif isinstance(dec, ast.Attribute) and isinstance(dec.value, ast.Name) and dec.attr in ("setter", "deleter", "getter"):
                                base_prop = self._new_tmp()
                                if dec.value.id in LUA_RESERVED_KEYWORDS:
                                    self._emit("SUBSCR", [node.name, f'"{dec.value.id}"'], result=base_prop)
                                else:
                                    self._emit("GET_ATTR", [node.name, dec.value.id], result=base_prop)
                                dec_fn = self._new_tmp()
                                self._emit("GET_ATTR", [base_prop, dec.attr], result=dec_fn)
                                m_tmp = self._new_tmp()
                                if fn_subname in LUA_RESERVED_KEYWORDS:
                                    self._emit("SUBSCR", [node.name, f'"{fn_subname}"'], result=m_tmp)
                                else:
                                    self._emit("GET_ATTR", [node.name, fn_subname], result=m_tmp)
                                res_tmp = self._new_tmp()
                                self._emit("CALL", [dec_fn, m_tmp], result=res_tmp)
                                if stmt.name in LUA_RESERVED_KEYWORDS:
                                    self._emit("STORE_SUBSCR", [node.name, f'"{stmt.name}"', res_tmp])
                                else:
                                    self._emit("SET_ATTR", [node.name, stmt.name, res_tmp])
                            else:
                                dec_tmp = self.lower_expr(dec)
                                m_tmp = self._new_tmp()
                                if fn_subname in LUA_RESERVED_KEYWORDS:
                                    self._emit("SUBSCR", [node.name, f'"{fn_subname}"'], result=m_tmp)
                                else:
                                    self._emit("GET_ATTR", [node.name, fn_subname], result=m_tmp)
                                res_tmp = self._new_tmp()
                                self._emit("CALL", [dec_tmp, m_tmp], result=res_tmp)
                                if stmt.name in LUA_RESERVED_KEYWORDS:
                                    self._emit("STORE_SUBSCR", [node.name, f'"{stmt.name}"', res_tmp])
                                else:
                                    self._emit("SET_ATTR", [node.name, stmt.name, res_tmp])
                    elif count > 1:
                        m_tmp = self._new_tmp()
                        if fn_subname in LUA_RESERVED_KEYWORDS:
                            self._emit("SUBSCR", [node.name, f'"{fn_subname}"'], result=m_tmp)
                        else:
                            self._emit("GET_ATTR", [node.name, fn_subname], result=m_tmp)
                        if stmt.name in LUA_RESERVED_KEYWORDS:
                            self._emit("STORE_SUBSCR", [node.name, f'"{stmt.name}"', m_tmp])
                        else:
                            self._emit("SET_ATTR", [node.name, stmt.name, m_tmp])
            self._cur_class = prev_cur_class

            # Auto-generate __init__ if dataclass and not defined
            if is_dataclass and not has_init and fields:
                params = ["self"] + [f["name"] for f in fields]
                fn = Function(name=node.name + ".__init__", params=params)
                prev_fn = self._cur_fn
                prev_block = self._cur_block
                self._cur_fn = fn
                b = Block(label="entry")
                fn.blocks.append(b)
                self._cur_block = b
                for f in fields:
                    self._emit("SET_ATTR", ["self", f["name"], f["name"]])
                self._emit("RETURN", [])
                self.module.functions.append(fn)
                self._cur_fn = prev_fn
                self._cur_block = prev_block

            # Auto-generate __repr__ if dataclass and not defined
            if is_dataclass and not has_repr:
                fn = Function(name=node.name + ".__repr__", params=["self"])
                prev_fn = self._cur_fn
                prev_block = self._cur_block
                self._cur_fn = fn
                b = Block(label="entry")
                fn.blocks.append(b)
                self._cur_block = b
                fields_tmp = self._new_tmp()
                self._emit("GET_ATTR", [node.name, "__dataclass_fields__"], result=fields_tmp)
                repr_tmp = self._new_tmp()
                self._emit("CALL", ["dataclasses_repr", "self", fields_tmp], result=repr_tmp)
                self._emit("RETURN", [repr_tmp])
                self.module.functions.append(fn)
                self._cur_fn = prev_fn
                self._cur_block = prev_block

            # Auto-generate __eq__ if dataclass and not defined
            if is_dataclass and not has_eq and fields:
                fn = Function(name=node.name + ".__eq__", params=["self", "other"])
                prev_fn = self._cur_fn
                prev_block = self._cur_block
                self._cur_fn = fn
                b = Block(label="entry")
                fn.blocks.append(b)
                self._cur_block = b
                fields_tmp = self._new_tmp()
                self._emit("GET_ATTR", [node.name, "__dataclass_fields__"], result=fields_tmp)
                eq_tmp = self._new_tmp()
                self._emit("CALL", ["dataclasses_eq", "self", "other", fields_tmp], result=eq_tmp)
                self._emit("RETURN", [eq_tmp])
                self.module.functions.append(fn)
                self._cur_fn = prev_fn
                self._cur_block = prev_block

            if is_native_struct and fields:
                # Mark module with native C-struct definition
                c_fields = []
                for f in fields:
                    # Map field to C type (default to double for numeric attributes)
                    c_fields.append(f"double {f['name']};")
                struct_cdef = f"typedef struct {{ {' '.join(c_fields)} }} {node.name}_t;"
                self.module.native_structs.append((node.name, struct_cdef, [f["name"] for f in fields]))

            self._emit("STORE", [node.name, cls])
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            mgrs = []
            for item in node.items:
                ctx_tmp = self.lower_expr(item.context_expr)
                mgr_tmp = self._new_tmp()
                self._emit("LOAD", [ctx_tmp], result=mgr_tmp)
                enter_ret = self._new_tmp()
                self._emit("CALL", ["_luthon_with_enter", mgr_tmp], result=enter_ret)
                if item.optional_vars:
                    self._lower_target(item.optional_vars, enter_ret)
                mgrs.append(mgr_tmp)
                self._emit("WITH_BEGIN", [])

            self._try_depth += len(mgrs)
            for s in node.body:
                self.lower_stmt(s)
            self._try_depth -= len(mgrs)

            for mgr_tmp in reversed(mgrs):
                self._emit("WITH_END", [mgr_tmp])
            self._emit("TRY_UNWIND", [str(self._try_depth)])
        elif isinstance(node, ast.Raise):
            if node.exc:
                exc_tmp = self.lower_expr(node.exc)
                self._emit("CALL", ["error", exc_tmp], result=self._new_tmp())
            else:
                active_exc = getattr(self, "_active_exc", None)
                if active_exc:
                    self._emit("CALL", ["error", active_exc], result=self._new_tmp())
                else:
                    self._emit("CALL", ["error", '"RuntimeError"'], result=self._new_tmp())
        elif isinstance(node, ast.Assert):
            cond_tmp = self.lower_expr(node.test)
            pass_lbl = self._new_label("assert_ok")
            fail_lbl = self._new_label("assert_fail")
            self._emit("BRANCH", [cond_tmp, pass_lbl, fail_lbl])
            self._cur_block = self._new_block(fail_lbl)
            msg_tmp = self.lower_expr(node.msg) if node.msg else None
            if msg_tmp:
                self._emit("CALL", ["error", msg_tmp], result=self._new_tmp())
            else:
                self._emit("CALL", ["error", '"AssertionError"'], result=self._new_tmp())
            self._cur_block = self._new_block(pass_lbl)
        elif isinstance(node, ast.Break):
            if self._break_stack:
                self._emit("JUMP", [self._break_stack[-1]])
        elif isinstance(node, ast.Continue):
            if self._continue_stack:
                self._emit("JUMP", [self._continue_stack[-1]])
        elif isinstance(node, ast.Yield):
            val_tmp = self.lower_expr(node.value) if node.value else None
            args = [val_tmp] if val_tmp else []
            self._emit("CALL", ["coroutine.yield"] + args, result=self._new_tmp())
        elif isinstance(node, ast.YieldFrom):
            it_tmp = self.lower_expr(node.value)
            iter_fn = self._new_tmp()
            self._emit("LOAD", ["iter"], result=iter_fn)
            nxt_iter = self._new_tmp()
            self._emit("CALL", [iter_fn, it_tmp], result=nxt_iter)
            loop_lbl = self._new_label("yfrom_loop")
            body_lbl = self._new_label("yfrom_body")
            end_lbl = self._new_label("yfrom_end")
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(loop_lbl)
            val = self._new_tmp()
            self._emit("NEXT", [nxt_iter], result=val)
            self._emit("BRANCH_NONE", [val, end_lbl])
            self._cur_block = self._new_block(body_lbl)
            self._emit("CALL", ["coroutine.yield", val], result=self._new_tmp())
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(end_lbl)
        elif isinstance(node, ast.Delete):
            for t in node.targets:
                if isinstance(t, ast.Subscript):
                    t_tmp = self.lower_expr(t.value)
                    idx_tmp = self.lower_expr(t.slice)
                    self._emit("CALL", ["__luthon_delitem", t_tmp, idx_tmp], result=self._new_tmp())
                elif isinstance(t, ast.Attribute):
                    t_tmp = self.lower_expr(t.value)
                    self._emit("SET_ATTR", [t_tmp, t.attr, "nil"])
                elif isinstance(t, ast.Name):
                    self._emit("STORE", [_safe_var(t.id), "nil"])
        elif hasattr(ast, "Match") and isinstance(node, ast.Match):
            self._lower_match(node)
        else:
            # fallback: record unsupported
            self._emit("NOP", [type(node).__name__])

    def _lower_match(self, node):
        """Lower ast.Match statement into decision tree with branch tests (Phase 36)."""
        subj = self.lower_expr(node.subject)
        end_lbl = self._new_label("matchend")

        for case_idx, case in enumerate(node.cases):
            next_case_lbl = self._new_label(f"cnext_{case_idx}")
            body_lbl = self._new_label(f"cbody_{case_idx}")

            # 1. Pattern test
            self._lower_pattern_test(case.pattern, subj, fail_lbl=next_case_lbl)

            # 2. Guard test if present
            if case.guard:
                guard_val = self.lower_expr(case.guard)
                guard_ok_lbl = self._new_label(f"guard_ok_{case_idx}")
                self._emit("BRANCH", [guard_val, guard_ok_lbl, next_case_lbl])
                self._cur_block = self._new_block(guard_ok_lbl)

            # 3. Case body
            self._emit("JUMP", [body_lbl])
            self._cur_block = self._new_block(body_lbl)
            for stmt in case.body:
                self.lower_stmt(stmt)
            if not case.body or not isinstance(case.body[-1], (ast.Return, ast.Break, ast.Continue)):
                self._emit("JUMP", [end_lbl])

            self._cur_block = self._new_block(next_case_lbl)

        self._emit("JUMP", [end_lbl])
        self._cur_block = self._new_block(end_lbl)

    def _lower_pattern_test(self, pat, subj, fail_lbl):
        """Recursively lower pattern matching test against subject variable."""
        if hasattr(ast, "MatchValue") and isinstance(pat, ast.MatchValue):
            val = self.lower_expr(pat.value)
            cmp_res = self._new_tmp()
            self._emit("CMP", ["eq", subj, val], result=cmp_res)
            ok_lbl = self._new_label("val_ok")
            self._emit("BRANCH", [cmp_res, ok_lbl, fail_lbl])
            self._cur_block = self._new_block(ok_lbl)

        elif hasattr(ast, "MatchSingleton") and isinstance(pat, ast.MatchSingleton):
            val = self._new_tmp()
            self._emit("CONST", [pat.value], result=val)
            cmp_res = self._new_tmp()
            self._emit("CMP", ["is", subj, val], result=cmp_res)
            ok_lbl = self._new_label("sing_ok")
            self._emit("BRANCH", [cmp_res, ok_lbl, fail_lbl])
            self._cur_block = self._new_block(ok_lbl)

        elif hasattr(ast, "MatchAs") and isinstance(pat, ast.MatchAs):
            if pat.pattern is not None:
                self._lower_pattern_test(pat.pattern, subj, fail_lbl)
            if pat.name is not None:
                self._emit("STORE", [_safe_var(pat.name), subj])

        elif hasattr(ast, "MatchOr") and isinstance(pat, ast.MatchOr):
            or_match_lbl = self._new_label("or_matched")
            for sub in pat.patterns[:-1]:
                sub_fail_lbl = self._new_label("or_fail")
                self._lower_pattern_test(sub, subj, fail_lbl=sub_fail_lbl)
                self._emit("JUMP", [or_match_lbl])
                self._cur_block = self._new_block(sub_fail_lbl)
            self._lower_pattern_test(pat.patterns[-1], subj, fail_lbl=fail_lbl)
            self._emit("JUMP", [or_match_lbl])
            self._cur_block = self._new_block(or_match_lbl)

        elif hasattr(ast, "MatchSequence") and isinstance(pat, ast.MatchSequence):
            len_fn = self._new_tmp()
            self._emit("LOAD", ["len"], result=len_fn)
            len_val = self._new_tmp()
            self._emit("CALL", [len_fn, subj], result=len_val)
            exp_len = self._new_tmp()
            self._emit("CONST", [len(pat.patterns)], result=exp_len)
            cmp_len = self._new_tmp()
            self._emit("CMP", ["eq", len_val, exp_len], result=cmp_len)
            seq_ok_lbl = self._new_label("seq_len_ok")
            self._emit("BRANCH", [cmp_len, seq_ok_lbl, fail_lbl])
            self._cur_block = self._new_block(seq_ok_lbl)

            for idx, sub in enumerate(pat.patterns):
                idx_tmp = self._new_tmp()
                self._emit("CONST", [idx], result=idx_tmp)
                elem_tmp = self._new_tmp()
                self._emit("SUBSCR", [subj, idx_tmp], result=elem_tmp)
                self._lower_pattern_test(sub, elem_tmp, fail_lbl=fail_lbl)

        elif hasattr(ast, "MatchMapping") and isinstance(pat, ast.MatchMapping):
            for k, sub in zip(pat.keys, pat.patterns):
                k_val = self.lower_expr(k)
                in_res = self._new_tmp()
                self._emit("CMP", ["in", k_val, subj], result=in_res)
                map_k_ok = self._new_label("map_k_ok")
                self._emit("BRANCH", [in_res, map_k_ok, fail_lbl])
                self._cur_block = self._new_block(map_k_ok)

                val_tmp = self._new_tmp()
                self._emit("SUBSCR", [subj, k_val], result=val_tmp)
                self._lower_pattern_test(sub, val_tmp, fail_lbl=fail_lbl)
            if getattr(pat, "rest", None):
                self._emit("STORE", [_safe_var(pat.rest), subj])

    def _lower_call_keywords(self, node):
        """Lower keyword arguments into a table and return its tmp name, or None."""
        if not node.keywords:
            return None
        kw_table = self._new_tmp()
        self._emit("MAKE_TABLE", [], result=kw_table)
        for kw in node.keywords:
            if kw.arg is None:
                # **kwargs dictionary unpacking: copy all key-values into kw_table
                dict_tmp = self.lower_expr(kw.value)
                # Call helper or iterate
                self._emit("CALL", ["_dict_update", kw_table, dict_tmp])
            else:
                key_tmp = self._new_tmp()
                self._emit("CONST", [kw.arg], result=key_tmp)
                val_tmp = self.lower_expr(kw.value)
                self._emit("STORE_SUBSCR", [kw_table, key_tmp, val_tmp])
        return kw_table

    def _emit_call(self, fn, args, kw_table=None):
        """Emit a CALL instruction with positional args and optional keyword table."""
        t = self._new_tmp()
        if kw_table is not None:
            self._emit("CALL", ["_luthon_call_kw", fn, kw_table] + list(args), result=t)
        else:
            self._emit("CALL", [fn] + list(args), result=t)
        return t

    def lower_expr(self, node):
        if node is None:
            return None
        prev_node = self._cur_node
        if hasattr(node, "lineno"):
            self._cur_node = node
        try:
            return self._lower_expr_impl(node)
        finally:
            self._cur_node = prev_node

    def _lower_expr_impl(self, node):
        if node is None:
            return None
        if isinstance(node, ast.Constant):
            t = self._new_tmp()
            v = node.value
            if isinstance(v, bytes):
                v = v.decode('latin-1')  # bytes -> string for Lua
            if v is True:
                self._emit("CONST", [True], result=t)
            elif v is False:
                self._emit("CONST", [False], result=t)
            elif v is None:
                self._emit("CONST", [None], result=t)
            else:
                self._emit("CONST", [v], result=t)
            return t
        if isinstance(node, ast.Subscript):
            v = self.lower_expr(node.value)
            if isinstance(node.slice, ast.Slice):
                lower_tmp = self.lower_expr(node.slice.lower) if node.slice.lower is not None else None
                upper_tmp = self.lower_expr(node.slice.upper) if node.slice.upper is not None else None
                step_tmp = self.lower_expr(node.slice.step) if node.slice.step is not None else None
                args = [v]
                args.append(lower_tmp if lower_tmp is not None else "nil")
                args.append(upper_tmp if upper_tmp is not None else "nil")
                if step_tmp is not None:
                    args.append(step_tmp)
                t = self._new_tmp()
                self._emit("CALL", ["_luthon_slice"] + args, result=t)
                return t
            else:
                sl = self.lower_expr(node.slice)
                t = self._new_tmp()
                self._emit("SUBSCR", [v, sl], result=t)
                return t
        if isinstance(node, ast.Attribute):
            obj = self.lower_expr(node.value)
            t = self._new_tmp()
            attr = node.attr
            if attr in LUA_RESERVED_KEYWORDS:
                self._emit("SUBSCR", [obj, f'"{attr}"'], result=t)
            else:
                self._emit("GET_ATTR", [obj, attr], result=t)
            return t
        if isinstance(node, ast.Name):
            if node.id == "True":
                t = self._new_tmp()
                self._emit("CONST", [True], result=t)
                return t
            elif node.id == "False":
                t = self._new_tmp()
                self._emit("CONST", [False], result=t)
                return t
            elif node.id == "None":
                t = self._new_tmp()
                self._emit("CONST", [None], result=t)
                return t
            safe_name = _safe_var(node.id)
            if self._cur_fn is not None and (node.id in getattr(self._cur_fn, "cellvars", []) or node.id in getattr(self._cur_fn, "freevars", [])):
                t = self._new_tmp()
                self._emit("CELL_GET", [safe_name], result=t)
                return t
            t = self._new_tmp()
            if node.id == "type" and (self._cur_fn is None or (node.id not in getattr(self._cur_fn, "params", []) and node.id not in getattr(self._cur_fn, "locals", []))):
                self._emit("LOAD", ["_luthon_type"], result=t)
            else:
                self._emit("LOAD", [safe_name], result=t)
            return t
        if isinstance(node, ast.BinOp) and isinstance(node.left, ast.List) and isinstance(node.op, ast.Mult):
            l = self.lower_expr(node.left)
            r = self.lower_expr(node.right)
            t = self._new_tmp()
            self._emit("LIST_REPEAT", [l, r], result=t)
            return t
        if isinstance(node, ast.BinOp):
            l = self.lower_expr(node.left)
            r = self.lower_expr(node.right)
            t = self._new_tmp()
            self._emit("BINOP", [self._binop(node.op), l, r], result=t)
            return t
        if isinstance(node, ast.UnaryOp):
            v = self.lower_expr(node.operand)
            t = self._new_tmp()
            self._emit("UNOP", [self._unop(node.op), v], result=t)
            return t
        if isinstance(node, ast.Compare):
            l = self.lower_expr(node.left)
            r = self.lower_expr(node.comparators[0])
            t = self._new_tmp()
            self._emit("CMP", [self._cmpop(node.ops[0]), l, r], result=t)
            return t
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id == "super" and not node.args:
                cur_cls = getattr(self, "_cur_class", None)
                first_arg = getattr(self, "_cur_method_first_arg", None)
                if cur_cls and first_arg:
                    node.args = [ast.Name(id=cur_cls, ctx=ast.Load()), ast.Name(id=first_arg, ctx=ast.Load())]

            kw_table = self._lower_call_keywords(node)
            has_starred = any(isinstance(a, ast.Starred) for a in node.args)

            target_fn = None
            pos_args = []
            if isinstance(node.func, ast.Attribute):
                # Distinguish module-level functions from instance method calls
                is_module = False
                known_modules = ("math","os","sys","json","random","re","string","hashlib","base64","struct","io","collections","itertools","functools","pathlib","datetime","typing","site","tempfile","subprocess","ast","ffi","bit","table","operator","six","packaging","websockets","asyncio","socket","http","requests","sqlite3","numpy","PIL","types")
                known_submodules = ("os.path", "urllib.parse", "urllib.request", "urllib.error", "http.client", "http.server", "collections.abc", "ffi.C", "math.simd")

                if isinstance(node.func.value, ast.Name):
                    if node.func.value.id in known_modules or (hasattr(self, "_imported_modules") and node.func.value.id in self._imported_modules):
                        is_module = True
                elif isinstance(node.func.value, ast.Attribute):
                    parts = []
                    curr = node.func.value
                    while isinstance(curr, ast.Attribute):
                        parts.append(curr.attr)
                        curr = curr.value
                    if isinstance(curr, ast.Name):
                        parts.append(curr.id)
                        dotted = ".".join(reversed(parts))
                        if dotted in known_submodules or (hasattr(self, "_imported_modules") and dotted in self._imported_modules):
                            is_module = True

                if is_module:
                    target_fn = self.lower_expr(node.func)
                    pos_args = []
                else:
                    obj = self.lower_expr(node.func.value)
                    meth = self._new_tmp()
                    self._emit("SUBSCR", [obj, f'"{node.func.attr}"'], result=meth)
                    target_fn = meth
                    pos_args = [obj]
            else:
                target_fn = self.lower_expr(node.func)
                pos_args = []

            if has_starred:
                flat_args_tmp = self._new_tmp()
                self._emit("MAKE_LIST", [], result=flat_args_tmp)
                for obj_arg in pos_args:
                    self._emit("CALL", ["_seq_append", flat_args_tmp, obj_arg])
                for a in node.args:
                    if isinstance(a, ast.Starred):
                        seq = self.lower_expr(a.value)
                        self._emit("CALL", ["_seq_extend", flat_args_tmp, seq])
                    else:
                        val = self.lower_expr(a)
                        self._emit("CALL", ["_seq_append", flat_args_tmp, val])
                res = self._new_tmp()
                if kw_table is not None:
                    self._emit("CALL", ["_luthon_call_starred", target_fn, flat_args_tmp, kw_table], result=res)
                else:
                    self._emit("CALL", ["_luthon_call_starred", target_fn, flat_args_tmp], result=res)
                return res

            all_args = pos_args + [self.lower_expr(a) for a in node.args]
            return self._emit_call(target_fn, all_args, kw_table)
        if isinstance(node, ast.BoolOp):
            result = self._new_tmp()
            left_tmp = self.lower_expr(node.values[0])
            end_lbl = self._new_label("bool_end")
            if isinstance(node.op, ast.And):
                false_lbl = self._new_label("and_false")
                self._emit("BRANCH_FALSE", [left_tmp, false_lbl])
                right_tmp = self.lower_expr(node.values[1])
                self._emit("STORE", [result, right_tmp])
                self._emit("JUMP", [end_lbl])
                self._cur_block = self._new_block(false_lbl)
                self._emit("STORE", [result, left_tmp])
                self._cur_block = self._new_block(end_lbl)
            elif isinstance(node.op, ast.Or):
                true_lbl = self._new_label("or_true")
                self._emit("BRANCH_TRUE", [left_tmp, true_lbl])
                right_tmp = self.lower_expr(node.values[1])
                self._emit("STORE", [result, right_tmp])
                self._emit("JUMP", [end_lbl])
                self._cur_block = self._new_block(true_lbl)
                self._emit("STORE", [result, left_tmp])
                self._cur_block = self._new_block(end_lbl)
            return result
        if isinstance(node, ast.IfExp):
            cond = self.lower_expr(node.test)
            chk_cond = self._new_tmp()
            self._emit("CALL", ["bool", cond], result=chk_cond)
            res = self._new_tmp()
            then_lbl = self._new_label("ifexp_then")
            else_lbl = self._new_label("ifexp_else")
            end_lbl = self._new_label("ifexp_end")
            self._emit("BRANCH", [chk_cond, then_lbl, else_lbl])
            self._cur_block = self._new_block(then_lbl)
            a = self.lower_expr(node.body)
            self._emit("STORE", [res, a])
            self._emit("JUMP", [end_lbl])
            self._cur_block = self._new_block(else_lbl)
            b = self.lower_expr(node.orelse)
            self._emit("STORE", [res, b])
            self._emit("JUMP", [end_lbl])
            self._cur_block = self._new_block(end_lbl)
            return res
        if isinstance(node, ast.List):
            has_starred = any(isinstance(e, ast.Starred) for e in node.elts)
            if not has_starred:
                t = self._new_tmp()
                els = [self.lower_expr(e) for e in node.elts]
                self._emit("MAKE_LIST", els, result=t)
                return t
            res = self._new_tmp()
            self._emit("MAKE_LIST", [], result=res)
            for e in node.elts:
                if isinstance(e, ast.Starred):
                    seq = self.lower_expr(e.value)
                    self._emit("CALL", ["_seq_extend", res, seq])
                else:
                    val = self.lower_expr(e)
                    self._emit("LIST_APPEND", [res, val])
            return res
        if isinstance(node, ast.Tuple):
            has_starred = any(isinstance(e, ast.Starred) for e in node.elts)
            if not has_starred:
                t = self._new_tmp()
                els = [self.lower_expr(e) for e in node.elts]
                self._emit("MAKE_TUPLE", els, result=t)
                return t
            list_tmp = self._new_tmp()
            self._emit("MAKE_LIST", [], result=list_tmp)
            for e in node.elts:
                if isinstance(e, ast.Starred):
                    seq = self.lower_expr(e.value)
                    self._emit("CALL", ["_seq_extend", list_tmp, seq])
                else:
                    val = self.lower_expr(e)
                    self._emit("LIST_APPEND", [list_tmp, val])
            res = self._new_tmp()
            self._emit("CALL", ["tuple", list_tmp], result=res)
            return res
        if isinstance(node, ast.Set):
            t = self._new_tmp()
            self._emit("MAKE_SET", [], result=t)
            for e in node.elts:
                val = self.lower_expr(e)
                self._emit("SET_ADD", [t, val])
            return t
        if isinstance(node, ast.SetComp):
            res = self._new_tmp()
            self._emit("MAKE_SET", [], result=res)
            gen = node.generators[0]
            iter_tmp = self._new_tmp()
            self._emit("CALL", ["iter", self.lower_expr(gen.iter)], result=iter_tmp)
            loop_lbl = self._new_label("scomp")
            body_lbl = self._new_label("sbody")
            end_lbl = self._new_label("send")
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(loop_lbl)
            nxt = self._new_tmp()
            self._emit("NEXT", [iter_tmp], result=nxt)
            self._emit("BRANCH_NONE", [nxt, end_lbl])
            self._lower_target(gen.target, nxt)
            if gen.ifs:
                cond = self.lower_expr(gen.ifs[0])
                self._emit("BRANCH", [cond, body_lbl, loop_lbl])
                self._cur_block = self._new_block(body_lbl)
            val = self.lower_expr(node.elt)
            self._emit("SET_ADD", [res, val])
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(end_lbl)
            return res
        if isinstance(node, ast.DictComp):
            # {key: value for target in iter [if cond]} -> dict built via DICT_SET
            res = self._new_tmp()
            self._emit("MAKE_DICT", [], result=res)
            gen = node.generators[0]
            iter_tmp = self._new_tmp()
            self._emit("CALL", ["iter", self.lower_expr(gen.iter)], result=iter_tmp)
            loop_lbl = self._new_label("dcomp")
            body_lbl = self._new_label("dbody")
            end_lbl = self._new_label("dend")
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(loop_lbl)
            nxt = self._new_tmp()
            self._emit("NEXT", [iter_tmp], result=nxt)
            self._emit("BRANCH_NONE", [nxt, end_lbl])
            self._lower_target(gen.target, nxt)
            if gen.ifs:
                cond = self.lower_expr(gen.ifs[0])
                self._emit("BRANCH", [cond, body_lbl, loop_lbl])
                self._cur_block = self._new_block(body_lbl)
            key = self.lower_expr(node.key)
            val = self.lower_expr(node.value)
            self._emit("DICT_SET", [res, key, val])
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(end_lbl)
            return res
        if isinstance(node, ast.ListComp):
            # basic: build list from first generator
            res = self._new_tmp()
            self._emit("MAKE_LIST", [], result=res)
            gen = node.generators[0]
            iter_tmp = self._new_tmp()
            self._emit("CALL", ["iter", self.lower_expr(gen.iter)], result=iter_tmp)
            loop_lbl = self._new_label("lcomp")
            body_lbl = self._new_label("lbody")
            end_lbl = self._new_label("lend")
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(loop_lbl)
            nxt = self._new_tmp()
            self._emit("NEXT", [iter_tmp], result=nxt)
            self._emit("BRANCH_NONE", [nxt, end_lbl])
            self._lower_target(gen.target, nxt)
            # condition
            if gen.ifs:
                cond = self.lower_expr(gen.ifs[0])
                self._emit("BRANCH", [cond, body_lbl, loop_lbl])
                self._cur_block = self._new_block(body_lbl)
            val = self.lower_expr(node.elt)
            self._emit("LIST_APPEND", [res, val])
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(end_lbl)
            return res
        if isinstance(node, ast.GeneratorExp):
            # (elt for target in iter [if cond]) -> eager list, like ListComp
            res = self._new_tmp()
            self._emit("MAKE_LIST", [], result=res)
            gen = node.generators[0]
            iter_tmp = self._new_tmp()
            self._emit("CALL", ["iter", self.lower_expr(gen.iter)], result=iter_tmp)
            loop_lbl = self._new_label("gcomp")
            body_lbl = self._new_label("gbody")
            end_lbl = self._new_label("gend")
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(loop_lbl)
            nxt = self._new_tmp()
            self._emit("NEXT", [iter_tmp], result=nxt)
            self._emit("BRANCH_NONE", [nxt, end_lbl])
            self._lower_target(gen.target, nxt)
            # condition
            if gen.ifs:
                cond = self.lower_expr(gen.ifs[0])
                self._emit("BRANCH", [cond, body_lbl, loop_lbl])
                self._cur_block = self._new_block(body_lbl)
            val = self.lower_expr(node.elt)
            self._emit("LIST_APPEND", [res, val])
            self._emit("JUMP", [loop_lbl])
            self._cur_block = self._new_block(end_lbl)
            return res
        if isinstance(node, ast.Dict):
            t = self._new_tmp()
            has_unpack = any(k is None for k in node.keys)
            if not has_unpack:
                items = []
                for k, v in zip(node.keys, node.values):
                    items.append((self.lower_expr(k), self.lower_expr(v)))
                self._emit("MAKE_DICT", items, result=t)
                return t
            self._emit("MAKE_DICT", [], result=t)
            for k, v in zip(node.keys, node.values):
                if k is None:
                    dict_val = self.lower_expr(v)
                    self._emit("CALL", ["_dict_update", t, dict_val])
                else:
                    k_tmp = self.lower_expr(k)
                    v_tmp = self.lower_expr(v)
                    self._emit("DICT_SET", [t, k_tmp, v_tmp])
            return t
        if isinstance(node, ast.Lambda):
            args = [_safe_var(a.arg) for a in node.args.args]
            if node.args.vararg or node.args.kwarg:
                args.append("...")
            # Create a nested function for the lambda body
            lambda_name = "_lambda_%d" % self._tmp
            self._tmp += 1
            fn = Function(name=lambda_name, params=args)
            fn.is_nested = True
            sc = getattr(node, "_scope", None)
            if sc is not None:
                fn.locals = sorted(_safe_var(k) for k in sc.locals.keys())
                fn.freevars = sorted(_safe_var(k) for k in getattr(sc, "freevars", set()))
                fn.cellvars = sorted(_safe_var(k) for k in getattr(sc, "cellvars", set()))
                fn.upvalues = list(fn.freevars)
            prev_fn = self._cur_fn
            prev_block = self._cur_block
            prev_try_depth = self._try_depth
            self._try_depth = 0
            self._cur_fn = fn
            b = Block(label="entry")
            fn.blocks.append(b)
            self._cur_block = b
            if node.args.vararg:
                vararg_name = _safe_var(node.args.vararg.arg)
                t_dots = self._new_tmp()
                self._emit("CALL", ["_tuple_pack", "..."], result=t_dots)
                self._emit("STORE", [vararg_name, t_dots])
            if node.args.kwarg:
                kwarg_name = _safe_var(node.args.kwarg.arg)
                t_kw = self._new_tmp()
                self._emit("CALL", ["_luthon_extract_kwargs", "..."], result=t_kw)
                self._emit("STORE", [kwarg_name, t_kw])
            body_tmp = self.lower_expr(node.body)
            self._emit("RETURN", [body_tmp])
            self.module.functions.append(fn)
            self._cur_fn = prev_fn
            self._cur_block = prev_block
            self._try_depth = prev_try_depth
            # Emit MAKE_FUNCTION that references the nested function
            t = self._new_tmp()
            self._emit("MAKE_FUNCTION", [fn.name], result=t)
            if node.args and node.args.args:
                param_names = [f'"{a.arg}"' for a in node.args.args]
                param_tuple = self._new_tmp()
                self._emit("MAKE_TUPLE", param_names, result=param_tuple)
                self._emit("CALL", ["_luthon_reg_fn", t, param_tuple])
            return t
        if isinstance(node, ast.JoinedStr):
            # f-string: concatenate all parts
            values = node.values
            if not values:
                t = self._new_tmp()
                self._emit("CONST", ['""'], result=t)
                return t
            first = values[0]
            if isinstance(first, ast.FormattedValue):
                val_tmp = self.lower_expr(first.value)
                res = self._new_tmp()
                str_fn = self._new_tmp()
                self._emit("LOAD", ["str"], result=str_fn)
                self._emit("CALL", [str_fn, val_tmp], result=res)
            else:
                res = self.lower_expr(first)

            for part in values[1:]:
                if isinstance(part, ast.FormattedValue):
                    val_tmp = self.lower_expr(part.value)
                    part_str = self._new_tmp()
                    str_fn = self._new_tmp()
                    self._emit("LOAD", ["str"], result=str_fn)
                    self._emit("CALL", [str_fn, val_tmp], result=part_str)
                    new_res = self._new_tmp()
                    self._emit("BINOP", ["concat", res, part_str], result=new_res)
                    res = new_res
                else:
                    part_tmp = self.lower_expr(part)
                    new_res = self._new_tmp()
                    self._emit("BINOP", ["concat", res, part_tmp], result=new_res)
                    res = new_res
            return res
        if isinstance(node, ast.FormattedValue):
            val_tmp = self.lower_expr(node.value)
            res = self._new_tmp()
            str_fn = self._new_tmp()
            self._emit("LOAD", ["str"], result=str_fn)
            self._emit("CALL", [str_fn, val_tmp], result=res)
            return res
        if isinstance(node, ast.Slice):
            lower_tmp = self.lower_expr(node.lower) if node.lower is not None else None
            upper_tmp = self.lower_expr(node.upper) if node.upper is not None else None
            step_tmp = self.lower_expr(node.step) if node.step is not None else None
            args = [
                lower_tmp if lower_tmp is not None else "nil",
                upper_tmp if upper_tmp is not None else "nil",
            ]
            if step_tmp is not None:
                args.append(step_tmp)
            t = self._new_tmp()
            self._emit("CALL", ["_luthon_slice_desc"] + args, result=t)
            return t
        if isinstance(node, ast.Yield):
            val_tmp = self.lower_expr(node.value) if node.value else None
            args = [val_tmp] if val_tmp else []
            t = self._new_tmp()
            self._emit("CALL", ["coroutine.yield"] + args, result=t)
            return t
        if isinstance(node, ast.Await):
            val_tmp = self.lower_expr(node.value)
            t = self._new_tmp()
            self._emit("CALL", ["_luthon_await", val_tmp], result=t)
            return t
        # fallback
        t = self._new_tmp()
        self._emit("EXPR", [ast.dump(node)], result=t)
        return t

    def _binop(self, op):
        return {
            ast.Add: "add", ast.Sub: "sub", ast.Mult: "mul", ast.Div: "div",
            ast.FloorDiv: "floordiv", ast.Mod: "mod", ast.Pow: "pow",
            ast.BitAnd: "band", ast.BitOr: "bor", ast.BitXor: "bxor",
            ast.LShift: "lshift", ast.RShift: "rshift",
            ast.MatMult: "matmul",
        }.get(type(op), type(op).__name__)

    def _unop(self, op):
        return {ast.USub: "neg", ast.UAdd: "pos", ast.Not: "not", ast.Invert: "inv"}.get(type(op), type(op).__name__)

    def _cmpop(self, op):
        return {
            ast.Eq: "eq", ast.NotEq: "ne", ast.Lt: "lt", ast.LtE: "le",
            ast.Gt: "gt", ast.GtE: "ge", ast.Is: "is", ast.IsNot: "isnot",
            ast.In: "in", ast.NotIn: "notin",
        }.get(type(op), type(op).__name__)

    def verify(self, module):
        errors = []
        for fn in module.functions:
            labels = {b.label for b in fn.blocks}
            if not fn.blocks:
                errors.append(fn.name + ": no blocks")
                continue
            for b in fn.blocks:
                if not b.instrs:
                    continue
                last = b.instrs[-1]
                if last.op in ("JUMP", "BRANCH", "RETURN", "BRANCH_NONE"):
                    continue
                # last block may fall through; ok
            # check jump targets resolve
            for b in fn.blocks:
                for ins in b.instrs:
                    if ins.op in ("JUMP", "BRANCH", "BRANCH_NONE"):
                        for a in ins.args[1:]:
                            if isinstance(a, str) and a not in labels and not a.startswith("_"):
                                errors.append(fn.name + ": unknown label " + a)
        return errors

    def make_cell(self, name):
        t = self._new_tmp()
        self._emit("MAKE_CELL", [name], result=t)
        return t

    def cell_get(self, cell):
        t = self._new_tmp()
        self._emit("CELL_GET", [cell], result=t)
        return t

    def cell_set(self, cell, value):
        self._emit("CELL_SET", [cell, value])

    def lower(self, scope_or_node):
        # accept scope (has .node?) or ast node; handle both
        if isinstance(scope_or_node, ast.AST):
            node = scope_or_node
        else:
            # assume scope; not enough info; expect caller passes tree
            node = None
        if node is None:
            raise ValueError("IRLowerer.lower requires an AST node")
        return self.lower_module(node)


def lower_source(source):
    import ast as _ast
    tree = _ast.parse(source)
    return IRLowerer().lower_module(tree)

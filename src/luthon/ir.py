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
            if isinstance(node.targets[0], ast.Tuple):
                # Tuple unpacking: f, name = expr
                val = self.lower_expr(node.value)
                for i, t in enumerate(node.targets[0].elts):
                    if isinstance(t, ast.Name):
                        idx_tmp = self._new_tmp()
                        self._emit("CONST", [i], result=idx_tmp)
                        elem_tmp = self._new_tmp()
                        self._emit("SUBSCR", [val, idx_tmp], result=elem_tmp)
                        self._emit("STORE", [t.id, elem_tmp])
            else:
                val = self.lower_expr(node.value)
                for t in node.targets:
                    if isinstance(t, ast.Name):
                        safe_name = _safe_var(t.id)
                        if self._cur_fn is not None and t.id in getattr(self._cur_fn, "cellvars", []):
                            self._emit("CELL_SET", [safe_name, val])
                        else:
                            self._emit("STORE", [safe_name, val])
                    elif isinstance(t, ast.Subscript):
                        base = self.lower_expr(t.value)
                        sl = self.lower_expr(t.slice)
                        self._emit("STORE_SUBSCR", [base, sl, val])
                    elif isinstance(t, ast.Attribute):
                        obj = self.lower_expr(t.value)
                        attr = t.attr
                        if attr in LUA_RESERVED_KEYWORDS:
                            self._emit("STORE_SUBSCR", [obj, f'"{attr}"', val])
                        else:
                            self._emit("SET_ATTR", [obj, attr, val])
        elif isinstance(node, ast.AugAssign):
            lhs = self.lower_expr(node.target)
            rhs = self.lower_expr(node.value)
            res = self._new_tmp()
            self._emit("BINOP", [self._binop(node.op), lhs, rhs], result=res)
            if isinstance(node.target, ast.Name):
                self._emit("STORE", [_safe_var(node.target.id), res])
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
        elif isinstance(node, ast.For):
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
                self._emit("STORE", [node.target.id, nxt])
            elif isinstance(node.target, (ast.Tuple, ast.List)):
                for i, t in enumerate(node.target.elts):
                    if isinstance(t, ast.Name):
                        idx_tmp = self._new_tmp()
                        self._emit("CONST", [i], result=idx_tmp)
                        elem_tmp = self._new_tmp()
                        self._emit("SUBSCR", [nxt, idx_tmp], result=elem_tmp)
                        self._emit("STORE", [t.id, elem_tmp])
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
        elif isinstance(node, ast.FunctionDef):
            fn_sym = node.name
            count = self._fn_counter.get(node.name, 0) + 1
            self._fn_counter[node.name] = count
            unique_fn_name = node.name if count == 1 else f"{node.name}_{count}"
            params = [_safe_var(a.arg) for a in node.args.args]
            if node.args.vararg:
                params.append("...")
            fn = Function(name=unique_fn_name, params=params)
            # Find nonlocal declarations in function body
            fn_nonlocals = set()
            for stmt in node.body:
                if isinstance(stmt, ast.Nonlocal):
                    fn_nonlocals.update(stmt.names)
            fn.nonlocals = sorted(fn_nonlocals)
            prev_fn = self._cur_fn
            prev_block = self._cur_block
            self._cur_fn = fn
            b = Block(label="entry")
            fn.blocks.append(b)
            self._cur_block = b
            # If vararg is present, pack into a table
            if node.args.vararg:
                vararg_name = _safe_var(node.args.vararg.arg)
                t_dots = self._new_tmp()
                self._emit("CALL", ["table.pack", "..."], result=t_dots)
                self._emit("STORE", [vararg_name, t_dots])
            # If kwarg is present, initialize table
            if node.args.kwarg:
                kwarg_name = _safe_var(node.args.kwarg.arg)
                t_kw = self._new_tmp()
                self._emit("MAKE_DICT", [], result=t_kw)
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
            is_gen = any(isinstance(n, (ast.Yield, ast.YieldFrom)) for n in ast.walk(node))
            if is_gen:
                # Wrap generator function body inside an implementation function
                impl_name = fn.name + "_impl"
                fn.name = impl_name
                self.module.functions.append(fn)

                # Now create the wrapper function that calls make_generator(impl_name, ...)
                wrapper_fn = Function(name=unique_fn_name, params=[_safe_var(a.arg) for a in node.args.args])
                sc = getattr(node, "_scope", None)
                if sc is not None:
                    wrapper_fn.freevars = sorted(getattr(sc, "freevars", set()))
                    wrapper_fn.cellvars = sorted(getattr(sc, "cellvars", set()))
                    wrapper_fn.upvalues = list(wrapper_fn.freevars)
                wrapper_block = Block(label="entry")
                wrapper_fn.blocks.append(wrapper_block)
                self._cur_fn = wrapper_fn
                self._cur_block = wrapper_block

                # Call make_generator(impl_name, arg1, arg2, ...)
                gen_res = self._new_tmp()
                call_args = ["make_generator", impl_name] + [_safe_var(a.arg) for a in node.args.args]
                self._emit("CALL", call_args, result=gen_res)
                self._emit("RETURN", [gen_res])
                self.module.functions.append(wrapper_fn)

                self._cur_fn = prev_fn
                self._cur_block = prev_block
            else:
                self.module.functions.append(fn)
                # Switch back to enclosing block before applying decorators
                self._cur_fn = prev_fn
                self._cur_block = prev_block
            self._emit("STORE", [_safe_var(fn_sym), unique_fn_name])
            # Apply decorators (innermost first)
            for dec in reversed(node.decorator_list):
                dec_tmp = self.lower_expr(dec)
                fn_tmp = self._new_tmp()
                self._emit("LOAD", [_safe_var(fn_sym)], result=fn_tmp)
                result_tmp = self._new_tmp()
                self._emit("CALL", [dec_tmp, fn_tmp], result=result_tmp)
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
            try_label = self._new_label("try")
            try_block = self._new_block(try_label)
            self._cur_block = try_block
            self._emit("TRY_BEGIN", [], result=self._new_tmp())
            self._try_depth += 1
            for s in node.body:
                self.lower_stmt(s)
            self._try_depth -= 1
            self._emit("END_TRY", [], result=self._new_tmp())
            finally_label = self._new_label("finally")
            end_label = self._new_label("end_try")
            for h in node.handlers:
                handler_lbl = self._new_label("except")
                self._cur_block = self._new_block(handler_lbl)
                if h.name:
                    self._emit("STORE", [h.name, "_exc"])
                for s in h.body:
                    self.lower_stmt(s)
                self._emit("END_CATCH", [], result=self._new_tmp())
            self._emit("END_ALL_CATCH", [], result=self._new_tmp())
            for s in node.orelse:
                self.lower_stmt(s)
            if node.finalbody:
                self._cur_block = self._new_block(finally_label)
                for s in node.finalbody:
                    self.lower_stmt(s)
            self._cur_block = self._new_block(end_label)
            self._emit("TRY_UNWIND", [])
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
            for stmt in node.body:
                if isinstance(stmt, ast.FunctionDef):
                    if stmt.name == "__init__":
                        has_init = True
                    if stmt.name == "__repr__":
                        has_repr = True
                    if stmt.name == "__eq__":
                        has_eq = True
                    params = [_safe_var(a.arg) for a in stmt.args.args]
                    if stmt.args.vararg:
                        params.append("...")
                    fn = Function(name=node.name + "." + stmt.name, params=params)
                    sc = getattr(stmt, "_scope", None)
                    if sc is not None:
                        fn.freevars = sorted(getattr(sc, "freevars", set()))
                        fn.cellvars = sorted(getattr(sc, "cellvars", set()))
                        fn.upvalues = list(fn.freevars)
                    prev_fn = self._cur_fn
                    prev_block = self._cur_block
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
                        self._emit("CALL", ["table.pack", "..."], result=t_dots)
                        self._emit("STORE", [vararg_name, t_dots])
                    # If kwarg is present, initialize table
                    if stmt.args.kwarg:
                        kwarg_name = _safe_var(stmt.args.kwarg.arg)
                        t_kw = self._new_tmp()
                        self._emit("MAKE_DICT", [], result=t_kw)
                        self._emit("STORE", [kwarg_name, t_kw])
                    for s2 in stmt.body:
                        self.lower_stmt(s2)
                    if not stmt.body or not isinstance(stmt.body[-1], ast.Return):
                        self._emit("RETURN", [])
                    self.module.functions.append(fn)
                    self._cur_fn = prev_fn
                    self._cur_block = prev_block
                    # Check for @property decorator on class method
                    is_prop = any((isinstance(d, ast.Name) and d.id == "property") for d in stmt.decorator_list)
                    if is_prop:
                        # Wrap as property object
                        prop_tmp = self._new_tmp()
                        prop_ref = f'{node.name}["{stmt.name}"]' if stmt.name in LUA_RESERVED_KEYWORDS else f"{node.name}.{stmt.name}"
                        self._emit("CALL", ["property", prop_ref], result=prop_tmp)
                        if stmt.name in LUA_RESERVED_KEYWORDS:
                            self._emit("STORE_SUBSCR", [node.name, f'"{stmt.name}"', prop_tmp])
                        else:
                            self._emit("SET_ATTR", [node.name, stmt.name, prop_tmp])

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
        elif isinstance(node, ast.With):
            # with statement: enter context, run body, exit context
            aliases = []
            for i, item in enumerate(node.items):
                ctx_tmp = self.lower_expr(item.context_expr)
                mgr_tmp = self._new_tmp()
                self._emit("LOAD", [ctx_tmp], result=mgr_tmp)
                aliases.append(mgr_tmp)
                enter_tmp = self._new_tmp()
                self._emit("GET_ATTR", [mgr_tmp, "__enter__"], result=enter_tmp)
                enter_lbl = self._new_label("with_enter")
                end_enter_lbl = self._new_label("with_enter_end")
                self._emit("BRANCH", [enter_tmp, enter_lbl, end_enter_lbl])
                self._cur_block = self._new_block(enter_lbl)
                self._emit("DO", [])
                enter_ret = self._new_tmp()
                self._emit("CALL", [enter_tmp, mgr_tmp], result=enter_ret)
                if item.optional_vars and isinstance(item.optional_vars, ast.Name):
                    self._emit("STORE", [item.optional_vars.id, enter_ret])
                self._emit("END", [])
                self._cur_block = self._new_block(end_enter_lbl)
            # body
            for s in node.body:
                self.lower_stmt(s)
            # __exit__ for each context manager (in reverse order)
            for mgr_tmp in reversed(aliases):
                exit_tmp = self._new_tmp()
                self._emit("GET_ATTR", [mgr_tmp, "__exit__"], result=exit_tmp)
                exit_lbl = self._new_label("with_exit")
                end_exit_lbl = self._new_label("with_exit_end")
                self._emit("BRANCH", [exit_tmp, exit_lbl, end_exit_lbl])
                self._cur_block = self._new_block(exit_lbl)
                self._emit("DO", [])
                self._emit("CALL", [exit_tmp, mgr_tmp], result=self._new_tmp())
                self._emit("END", [])
                self._cur_block = self._new_block(end_exit_lbl)
        elif isinstance(node, ast.Raise):
            if node.exc:
                exc_tmp = self.lower_expr(node.exc)
                self._emit("CALL", ["error", exc_tmp], result=self._new_tmp())
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
        else:
            # fallback: record unsupported
            self._emit("NOP", [type(node).__name__])

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
        all_args = list(args)
        if kw_table is not None:
            # Pad positional args with nil up to 5, then append kw table as 6th arg
            while len(all_args) < 5:
                all_args.append(None)
            all_args.append(kw_table)
        t = self._new_tmp()
        self._emit("CALL", [fn] + all_args, result=t)
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
            safe_name = _safe_var(node.id)
            if self._cur_fn is not None and node.id in getattr(self._cur_fn, "cellvars", []):
                t = self._new_tmp()
                self._emit("CELL_GET", [safe_name], result=t)
                return t
            t = self._new_tmp()
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
            if isinstance(node.func, ast.Attribute):
                # module-level / builtin functions: don't prepend self
                # determine root name of attribute chain
                root = node.func.value
                while isinstance(root, ast.Attribute):
                    root = root.value
                known_modules = ("math","os","sys","json","random","re","string","hashlib","base64","struct","io","collections","itertools","functools","pathlib","datetime","typing","site","tempfile","subprocess","ast","ffi","bit","table","operator","six","packaging")
                is_module = (isinstance(root, ast.Name) and root.id in known_modules) or (hasattr(self, "_imported_modules") and isinstance(root, ast.Name) and root.id in self._imported_modules)
                if is_module:
                    fn = self.lower_expr(node.func)
                    args = [self.lower_expr(a) for a in node.args]
                    kw_table = self._lower_call_keywords(node)
                    return self._emit_call(fn, args, kw_table)
                obj = self.lower_expr(node.func.value)
                meth = self._new_tmp()
                self._emit("SUBSCR", [obj, f'"{node.func.attr}"'], result=meth)
                args = [obj] + [self.lower_expr(a) for a in node.args]
                kw_table = self._lower_call_keywords(node)
                return self._emit_call(meth, args, kw_table)
            fn = self.lower_expr(node.func)
            args = [self.lower_expr(a) for a in node.args]
            kw_table = self._lower_call_keywords(node)
            return self._emit_call(fn, args, kw_table)
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
            t = self._new_tmp()
            els = [self.lower_expr(e) for e in node.elts]
            self._emit("MAKE_LIST", els, result=t)
            return t
        if isinstance(node, ast.Tuple):
            t = self._new_tmp()
            els = [self.lower_expr(e) for e in node.elts]
            self._emit("MAKE_TUPLE", els, result=t)
            return t
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
            if isinstance(gen.target, ast.Name):
                self._emit("STORE", [gen.target.id, nxt])
            if gen.ifs:
                cond = self.lower_expr(gen.ifs[0])
                self._emit("BRANCH", [cond, body_lbl, loop_lbl])
                self._cur_block = self._new_block(body_lbl)
            val = self.lower_expr(node.elt)
            self._emit("SET_ADD", [res, val])
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
            # bind target
            if isinstance(gen.target, ast.Name):
                self._emit("STORE", [gen.target.id, nxt])
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
            items = []
            for k, v in zip(node.keys, node.values):
                items.append((self.lower_expr(k) if k is not None else None, self.lower_expr(v)))
            self._emit("MAKE_DICT", items, result=t)
            return t
        if isinstance(node, ast.Lambda):
            args = [a.arg for a in node.args.args]
            # Create a nested function for the lambda body
            lambda_name = "_lambda_%d" % self._tmp
            fn = Function(name=lambda_name, params=args)
            prev_fn = self._cur_fn
            prev_block = self._cur_block
            self._cur_fn = fn
            b = Block(label="entry")
            fn.blocks.append(b)
            self._cur_block = b
            body_tmp = self.lower_expr(node.body)
            self._emit("RETURN", [body_tmp])
            self.module.functions.append(fn)
            self._cur_fn = prev_fn
            self._cur_block = prev_block
            # Emit MAKE_FUNCTION that references the nested function
            t = self._new_tmp()
            self._emit("MAKE_FUNCTION", [fn.name], result=t)
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
            ast.Gt: "gt", ast.GtE: "ge", ast.Is: "eq", ast.IsNot: "ne",
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

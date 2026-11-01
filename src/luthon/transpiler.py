"""Python AST -> LuaJIT code generator.

Translates a broad subset of Python into Lua source that runs under LuaJIT.
"""

import ast
from typing import Any


class TranspileError(Exception):
    pass


class LuaEmitter:
    def __init__(self) -> None:
        self.lines: list[str] = []
        self.indent = 0

    def emit(self, text: str) -> None:
        self.lines.append("    " * self.indent + text)

    def block(self, text: str) -> None:
        self.emit(text)
        self.indent += 1

    def dedent(self) -> None:
        self.indent = max(0, self.indent - 1)

    def result(self) -> str:
        return "\n".join(self.lines) + "\n"


class Transpiler(ast.NodeVisitor):
    def __init__(self) -> None:
        self.out = LuaEmitter()
        self._in_class = False

    def transpile(self, source: str) -> str:
        tree = ast.parse(source)
        self.out.emit("-- Luthon runtime helpers")
        self.out.emit("local bit = require('bit')")
        self.out.emit("function range(a, b, step)")
        self.out.indent += 1
        self.out.emit("if b == nil then a, b = 0, a; step = 1 end")
        self.out.emit("if step == nil then step = 1 end")
        self.out.emit("local r = {}")
        self.out.emit("if step > 0 then for i = a, b - 1, step do r[#r+1] = i end")
        self.out.emit("else for i = a, b + 1, step do r[#r+1] = i end end")
        self.out.emit("return r")
        self.out.indent -= 1
        self.out.emit("end")
        self.out.emit("function len(t) return #t end")
        self.out.emit("open = io.open")
        self.out.emit("function ValueError(m) return m end")
        self.out.emit("sqrt = math.sqrt")
        self.out.emit("if not os.path then os.path = {join = function(...) local a={...}; return table.concat(a, '/') end} end")
        self.out.emit("function str(x) return tostring(x) end")
        self.out.emit("function int(x) return math.floor(tonumber(x) or 0) end")
        self.out.emit("function float(x) return tonumber(x) or 0.0 end")
        self.out.emit("function bool(x) return not not x end")
        self.out.emit("function list(t) local r={} for i,v in ipairs(t or {}) do r[i]=v end return r end")
        self.out.emit("function dict(t) return t or {} end")
        self.out.emit("function set(t) local r={} for _,v in ipairs(t or {}) do r[v]=true end return r end")
        self.out.emit("function tuple(t) return t end")
        self.out.emit("function abs(x) return math.abs(x) end")
        self.out.emit("function min(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]<m then m=a[i] end end return m end")
        self.out.emit("function max(...) local a={...}; local m=a[1]; for i=2,#a do if a[i]>m then m=a[i] end end return m end")
        self.out.emit("function sum(t) local s=0; for _,v in ipairs(t) do s=s+v end return s end")
        self.out.emit("function sorted(t) local r=list(t); table.sort(r); return r end")
        self.out.emit("function enumerate(t) local r={}; for i,v in ipairs(t) do r[i]={i-1,v} end return r end")
        self.out.emit("function zip(a,b) local r={}; for i=1,math.min(#a,#b) do r[i]={a[i],b[i]} end return r end")
        self.out.emit("function any(t) for _,v in ipairs(t) do if v then return true end end return false end")
        self.out.emit("function all(t) for _,v in ipairs(t) do if not v then return false end end return true end")
        self.out.emit("")
        for node in tree.body:
            self.visit(node)
        return self.out.result()

    # ---- statements ----

    def visit_Module(self, node: ast.Module) -> None:
        for stmt in node.body:
            self.visit(stmt)

    def visit_Expr(self, node: ast.Expr) -> None:
        val = self._expr(node.value)
        if val is not None:
            self.out.emit(val)

    def visit_Assign(self, node: ast.Assign) -> None:
        # multiple targets / unpacking
        if len(node.targets) == 1 and isinstance(node.targets[0], (ast.Tuple, ast.List)):
            t = node.targets[0]
            names = [self._expr(e) for e in t.elts]
            val = self._expr(node.value)
            # unpack via temp
            self.out.emit(f"do")
            self.out.indent += 1
            self.out.emit(f"local __tmp = {val}")
            for i, n in enumerate(names, start=1):
                self.out.emit(f"{n} = __tmp[{i}]")
            self.out.indent -= 1
            self.out.emit("end")
            return
        targets = [self._expr(t) for t in node.targets]
        value = self._expr(node.value)
        for t in targets:
            self.out.emit(f"{t} = {value}")

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        target = self._expr(node.target)
        value = self._expr(node.value) if node.value else "nil"
        self.out.emit(f"{target} = {value}")

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        target = self._expr(node.target)
        value = self._expr(node.value)
        op = self._binop(node.op)
        self.out.emit(f"{target} = {target} {op} {value}")

    def visit_Delete(self, node: ast.Delete) -> None:
        for t in node.targets:
            self.out.emit(f"{self._expr(t)} = nil")

    def visit_Return(self, node: ast.Return) -> None:
        if node.value is None:
            self.out.emit("return")
        else:
            self.out.emit(f"return {self._expr(node.value)}")

    def visit_If(self, node: ast.If) -> None:
        cond = self._expr(node.test)
        self.out.block(f"if {cond} then")
        for s in node.body:
            self.visit(s)
        if node.orelse:
            # elif
            if len(node.orelse) == 1 and isinstance(node.orelse[0], ast.If):
                self.out.dedent()
                self.out.emit("elseif " + self._expr(node.orelse[0].test) + " then")
                self.out.indent += 1
                for s in node.orelse[0].body:
                    self.visit(s)
                # handle nested else of elif
                if node.orelse[0].orelse:
                    self.out.dedent()
                    self.out.block("else")
                    for s in node.orelse[0].orelse:
                        self.visit(s)
                    self.out.dedent()
                    self.out.emit("end")
                    return
                self.out.dedent()
                self.out.emit("end")
                return
            self.out.dedent()
            self.out.block("else")
            for s in node.orelse:
                self.visit(s)
        self.out.dedent()
        self.out.emit("end")

    def visit_While(self, node: ast.While) -> None:
        cond = self._expr(node.test)
        self.out.block(f"while {cond} do")
        for s in node.body:
            self.visit(s)
        if node.orelse:
            # while-else: else runs if no break; approximate with flag
            pass
        self.out.dedent()
        self.out.emit("end")

    def visit_For(self, node: ast.For) -> None:
        target = self._expr(node.target)
        iterable = self._expr(node.iter)
        self.out.block(f"for _, {target} in ipairs({iterable}) do")
        for s in node.body:
            self.visit(s)
        self.out.emit("::__continue::")
        self.out.dedent()
        self.out.emit("end")
        if node.orelse:
            self.out.emit("-- for-else (approximated)")
            for s in node.orelse:
                self.visit(s)

    def visit_Break(self, node: ast.Break) -> None:
        self.out.emit("break")

    def visit_Continue(self, node: ast.Continue) -> None:
        self.out.emit("-- continue (not native in Lua; use goto)")
        self.out.emit("goto __continue")

    def _collect_locals(self, stmts):
        names = set()
        for s in stmts:
            if isinstance(s, ast.Assign):
                for t in s.targets:
                    if isinstance(t, ast.Name):
                        names.add(t.id)
                    elif isinstance(t, (ast.Tuple, ast.List)):
                        for e in t.elts:
                            if isinstance(e, ast.Name):
                                names.add(e.id)
            elif isinstance(s, ast.AnnAssign) and isinstance(s.target, ast.Name):
                names.add(s.target.id)
            elif isinstance(s, ast.AugAssign) and isinstance(s.target, ast.Name):
                names.add(s.target.id)
            elif isinstance(s, ast.For) and isinstance(s.target, ast.Name):
                names.add(s.target.id)
                names |= self._collect_locals(s.body)
                names |= self._collect_locals(s.orelse)
            elif isinstance(s, ast.If):
                names |= self._collect_locals(s.body)
                names |= self._collect_locals(s.orelse)
            elif isinstance(s, ast.While):
                names |= self._collect_locals(s.body)
                names |= self._collect_locals(s.orelse)
            elif isinstance(s, ast.With):
                for item in s.items:
                    if item.optional_vars and isinstance(item.optional_vars, ast.Name):
                        names.add(item.optional_vars.id)
                names |= self._collect_locals(s.body)
            elif isinstance(s, ast.Try):
                names |= self._collect_locals(s.body)
                for h in s.handlers:
                    if h.name:
                        names.add(h.name)
                    names |= self._collect_locals(h.body)
                names |= self._collect_locals(s.orelse)
                names |= self._collect_locals(s.finalbody)
            # do not descend into nested functions/classes
        return names

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        posonly = [a.arg for a in getattr(node.args, "posonlyargs", [])]
        args = [a.arg for a in node.args.args]
        kwonly = [a.arg for a in node.args.kwonlyargs]
        params = posonly + args + kwonly
        if node.args.vararg:
            params.append("...")
        defaults = node.args.defaults + (node.args.kw_defaults or [])
        self.out.block(f"function {node.name}({', '.join(params)})")
        locals_ = self._collect_locals(node.body)
        locals_ -= set(params)
        if locals_:
            self.out.emit(f"local {', '.join(sorted(locals_))}")
        if node.args.vararg:
            self.out.emit(f"local {node.args.vararg.arg} = {{...}}")
        if node.args.kwarg:
            self.out.emit(f"local {node.args.kwarg.arg} = {{}}")
        # defaults
        if defaults:
            off = len(args) - len(defaults)
            for i, d in enumerate(defaults):
                idx = off + i
                self.out.emit(f"if {args[idx]} == nil then {args[idx]} = {self._expr(d)} end")
        for s in node.body:
            self.visit(s)
        self.out.dedent()
        self.out.emit("end")

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self.visit_FunctionDef(node)  # type: ignore

    def visit_Await(self, node: ast.Await) -> None:
        # await is a no-op in this transpiler
        pass

    def visit_Yield(self, node: ast.Yield) -> None:
        if node.value is None:
            self.out.emit("coroutine.yield()")
        else:
            self.out.emit(f"coroutine.yield({self._expr(node.value)})")

    def visit_YieldFrom(self, node: ast.YieldFrom) -> None:
        it = self._expr(node.value)
        self.out.block(f"for _, __y in ipairs({it}) do")
        self.out.emit("coroutine.yield(__y)")
        self.out.dedent()
        self.out.emit("end")

    def visit_Match(self, node: ast.Match) -> None:
        subj = self._expr(node.subject)
        first = True
        for case in node.cases:
            pat = case.pattern
            guard = f" and {self._expr(case.guard)}" if case.guard else ""
            if isinstance(pat, ast.MatchAs) and pat.name is None and pat.pattern is None:
                self.out.block("else")
            elif isinstance(pat, ast.MatchValue):
                kw = "if" if first else "elseif"
                self.out.block(f"{kw} {subj} == {self._expr(pat.value)}{guard} then")
            elif isinstance(pat, ast.MatchAs):
                name = pat.name or "_"
                kw = "if" if first else "elseif"
                self.out.block(f"{kw} true{guard} then")
                self.out.emit(f"local {name} = {subj}")
            elif isinstance(pat, ast.MatchOr):
                kw = "if" if first else "elseif"
                alts = " or ".join(f"{subj} == {self._expr(p.value)}" for p in pat.patterns if isinstance(p, ast.MatchValue))
                self.out.block(f"{kw} {alts}{guard} then")
            else:
                kw = "if" if first else "elseif"
                self.out.block(f"{kw} true{guard} then")
            for s in case.body:
                self.visit(s)
            self.out.dedent()
            first = False
        if first:
            pass
        self.out.emit("end")

    def visit_Lambda(self, node: ast.Lambda) -> None:
        # handled in _expr
        pass

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        bases = [self._expr(b) for b in node.bases] if node.bases else []
        base = bases[0] if bases else "nil"
        self.out.block(f"local {node.name} = {{}}")
        self.out.emit(f"{node.name}.__index = {node.name}")
        self.out.emit(f"setmetatable({node.name}, {{__call = function(cls, ...) return cls.new(...) end}})")
        if bases:
            self.out.emit(f"setmetatable({node.name}, {{__index = {base}}})")
        self.out.block(f"function {node.name}.new(...)")
        self.out.emit("local self = setmetatable({}, " + node.name + ")")
        self.out.emit("if self.init then self:init(...) end")
        self.out.emit("return self")
        self.out.dedent()
        self.out.emit("end")
        for item in node.body:
            if isinstance(item, ast.FunctionDef):
                self.out.block(f"function {node.name}:{item.name}({', '.join(a.arg for a in item.args.args[1:])})")
                for s in item.body:
                    self.visit(s)
                self.out.dedent()
                self.out.emit("end")
            else:
                self.visit(item)
        self.out.dedent()

    def visit_Try(self, node: ast.Try) -> None:
        self.out.block("local __ok, __err = pcall(function()")
        for s in node.body:
            self.visit(s)
        self.out.dedent()
        self.out.emit("end)")
        self.out.emit("if not __ok then")
        self.out.indent += 1
        if node.handlers:
            for h in node.handlers:
                name = h.name if h.name else "_"
                if h.type:
                    self.out.emit(f"if tostring(__err):find('{h.type.id if isinstance(h.type, ast.Name) else ''}') then")
                    self.out.indent += 1
                self.out.emit(f"local {name} = __err")
                for s in h.body:
                    self.visit(s)
                if h.type:
                    self.out.indent -= 1
                    self.out.emit("end")
        else:
            self.out.emit("error(__err)")
        self.out.indent -= 1
        self.out.emit("end")
        if node.finalbody:
            for s in node.finalbody:
                self.visit(s)

    def visit_Raise(self, node: ast.Raise) -> None:
        if node.exc is None:
            self.out.emit("error()")
        else:
            self.out.emit(f"error({self._expr(node.exc)})")

    def visit_Assert(self, node: ast.Assert) -> None:
        cond = self._expr(node.test)
        msg = self._expr(node.msg) if node.msg else '"assertion failed"'
        self.out.emit(f"assert({cond}, {msg})")

    def visit_Import(self, node: ast.Import) -> None:
        for n in node.names:
            mod = n.name.replace(".", "_")
            alias = n.asname or mod
            self.out.emit(f"local {alias} = require('{n.name}')")

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        mod = node.module or ""
        for n in node.names:
            alias = n.asname or n.name
            self.out.emit(f"local {alias} = require('{mod}').{n.name}")

    def visit_Global(self, node: ast.Global) -> None:
        self.out.emit(f"-- global: {', '.join(node.names)}")

    def visit_Nonlocal(self, node: ast.Nonlocal) -> None:
        self.out.emit(f"-- nonlocal: {', '.join(node.names)}")

    def visit_Pass(self, node: ast.Pass) -> None:
        self.out.emit("-- pass")

    def visit_With(self, node: ast.With) -> None:
        for i, item in enumerate(node.items):
            ctx = self._expr(item.context_expr)
            alias = self._expr(item.optional_vars) if item.optional_vars else f"__ctx{i}"
            self.out.emit(f"local {alias} = {ctx}")
            self.out.emit(f"if {alias}.__enter__ then {alias}:__enter__() end")
        self.out.block("do")
        for s in node.body:
            self.visit(s)
        self.out.dedent()
        self.out.emit("end")
        for i, item in enumerate(node.items):
            alias = self._expr(item.optional_vars) if item.optional_vars else f"__ctx{i}"
            self.out.emit(f"if {alias}.__exit__ then {alias}:__exit__() end")

    # ---- expressions ----

    def _expr(self, node: Any) -> str:
        if node is None:
            return "nil"
        if isinstance(node, ast.Constant):
            v = node.value
            if v is None:
                return "nil"
            if isinstance(v, bool):
                return "true" if v else "false"
            if isinstance(v, str):
                # f-string already parsed as JoinedStr, not Constant
                return repr(v)
            if isinstance(v, bytes):
                return repr(v)
            return repr(v)
        if isinstance(node, ast.JoinedStr):
            # f-string -> string concatenation
            parts = []
            for v in node.values:
                if isinstance(v, ast.Constant):
                    parts.append(repr(v.value))
                else:
                    parts.append(f"tostring({self._expr(v.value)})")
            return " .. ".join(parts) if parts else '""'
        if isinstance(node, ast.Yield):
            return "coroutine.yield(" + (self._expr(node.value) if node.value else "") + ")"
        if isinstance(node, ast.Await):
            return self._expr(node.value)
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.BoolOp):
            op = "and" if isinstance(node.op, ast.And) else "or"
            vals = [self._expr(v) for v in node.values]
            return f"({(' ' + op + ' ').join(vals)})"
        if isinstance(node, ast.BinOp):
            left = self._expr(node.left)
            right = self._expr(node.right)
            op = self._binop(node.op)
            return f"({left} {op} {right})"
        if isinstance(node, ast.UnaryOp):
            operand = self._expr(node.operand)
            if isinstance(node.op, ast.Not):
                return f"(not {operand})"
            if isinstance(node.op, ast.USub):
                return f"(-{operand})"
            if isinstance(node.op, ast.UAdd):
                return f"(+{operand})"
            if isinstance(node.op, ast.Invert):
                return f"(bit.bnot({operand}))"
            return operand
        if isinstance(node, ast.Compare):
            left = self._expr(node.left)
            parts = []
            cur = left
            for op, comp in zip(node.ops, node.comparators):
                right = self._expr(comp)
                if isinstance(op, ast.Is):
                    parts.append(f"rawequal({cur}, {right})")
                elif isinstance(op, ast.IsNot):
                    parts.append(f"(not rawequal({cur}, {right}))")
                elif isinstance(op, ast.In):
                    parts.append(f"(function() for _,_v in ipairs({right}) do if _v == {cur} then return true end end return false end)()")
                elif isinstance(op, ast.NotIn):
                    parts.append(f"(function() for _,_v in ipairs({right}) do if _v == {cur} then return false end end return true end)()")
                else:
                    parts.append(f"{cur} {self._cmpop(op)} {right}")
                cur = right
            return " and ".join(parts) if len(parts) > 1 else parts[0]
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute):
                base = self._expr(node.func.value)
                attr = node.func.attr
                args = [self._expr(a) for a in node.args]
                if node.keywords:
                    kw = ", ".join(f"{kw.arg} = {self._expr(kw.value)}" for kw in node.keywords if kw.arg)
                    if kw:
                        args.append("{" + kw + "}")
                modules = {"os", "math", "string", "table", "io", "debug", "bit", "coroutine", "utf8", "package", "luthon"}
                root = base.split(".")[0].split(":")[0]
                if root in modules:
                    return f"{base}.{attr}({', '.join(args)})"
                return f"{base}:{attr}({', '.join(args)})"
            func = self._expr(node.func)
            args = [self._expr(a) for a in node.args]
            if node.keywords:
                kw = ", ".join(f"{kw.arg} = {self._expr(kw.value)}" for kw in node.keywords if kw.arg)
                if kw:
                    args.append("{" + kw + "}")
            return f"{func}({', '.join(args)})"
        if isinstance(node, ast.Attribute):
            return f"{self._expr(node.value)}.{node.attr}"
        if isinstance(node, ast.Subscript):
            base = self._expr(node.value)
            sl = node.slice
            if isinstance(sl, ast.Slice):
                lower = self._expr(sl.lower) if sl.lower else "1"
                upper = self._expr(sl.upper) if sl.upper else f"#({base})"
                step = self._expr(sl.step) if sl.step else "1"
                return f"(function() local r={{}}; local i=0; for idx={lower},{upper},{step} do i=i+1; r[i]={base}[idx] end return r end)()"
            idx = self._expr(sl)
            return f"{base}[{idx}]"
        if isinstance(node, ast.List):
            items = [self._expr(e) for e in node.elts]
            return "{" + ", ".join(items) + "}"
        if isinstance(node, ast.Tuple):
            items = [self._expr(e) for e in node.elts]
            return "{" + ", ".join(items) + "}"
        if isinstance(node, ast.Set):
            items = [self._expr(e) for e in node.elts]
            # lua set as table with true values
            return "{" + ", ".join(f"[{it}] = true" for it in items) + "}"
        if isinstance(node, ast.Dict):
            pairs = []
            for k, v in zip(node.keys, node.values):
                if k is None:
                    # **unpack not supported; skip
                    continue
                pairs.append(f"[{self._expr(k)}] = {self._expr(v)}")
            return "{" + ", ".join(pairs) + "}"
        if isinstance(node, ast.ListComp):
            target = self._expr(node.elt)
            # build simple: { f(x) for x in iter if cond }
            gen = node.generators[0]
            it = self._expr(gen.iter)
            var = self._expr(gen.target)
            cond = " and ".join(self._expr(c) for c in gen.ifs) if gen.ifs else "true"
            return f"(function() local r={{}}; for _,{var} in ipairs({it}) do if {cond} then r[#r+1]={target} end end return r end)()"
        if isinstance(node, ast.DictComp):
            gen = node.generators[0]
            it = self._expr(gen.iter)
            var = self._expr(gen.target)
            key = self._expr(node.key)
            val = self._expr(node.value)
            cond = " and ".join(self._expr(c) for c in gen.ifs) if gen.ifs else "true"
            return f"(function() local r={{}}; for _,{var} in ipairs({it}) do if {cond} then r[{key}]={val} end end return r end)()"
        if isinstance(node, ast.SetComp):
            gen = node.generators[0]
            it = self._expr(gen.iter)
            var = self._expr(gen.target)
            elt = self._expr(node.elt)
            cond = " and ".join(self._expr(c) for c in gen.ifs) if gen.ifs else "true"
            return f"(function() local r={{}}; for _,{var} in ipairs({it}) do if {cond} then r[{elt}]=true end end return r end)()"
        if isinstance(node, ast.GeneratorExp):
            # treat as list comp (eager)
            return self._expr(ast.ListComp(node.elt, node.generators)) if False else self._expr_listcomp_like(node)
        if isinstance(node, ast.IfExp):
            return f"({self._expr(node.test)} and {self._expr(node.body)} or {self._expr(node.orelse)})"
        if isinstance(node, ast.Lambda):
            args = [a.arg for a in node.args.args]
            return f"function({', '.join(args)}) return {self._expr(node.body)} end"
        if isinstance(node, ast.Starred):
            return self._expr(node.value)
        raise TranspileError(f"Unsupported expression: {ast.dump(node)}")

    def _expr_listcomp_like(self, node) -> str:
        return self._expr(ast.ListComp(node.elt, node.generators))

    def _binop(self, op: ast.operator) -> str:
        mapping = {
            ast.Add: "+",
            ast.Sub: "-",
            ast.Mult: "*",
            ast.Div: "/",
            ast.FloorDiv: "//",
            ast.Mod: "%",
            ast.Pow: "^",
            ast.BitAnd: "bit.band",
            ast.BitOr: "bit.bor",
            ast.BitXor: "bit.bxor",
            ast.LShift: "<<",
            ast.RShift: ">>",
        }
        if type(op) in mapping:
            m = mapping[type(op)]
            return m
        raise TranspileError(f"Unsupported binop: {type(op).__name__}")

    def _cmpop(self, op: ast.cmpop) -> str:
        mapping = {
            ast.Eq: "==",
            ast.NotEq: "~=",
            ast.Lt: "<",
            ast.LtE: "<=",
            ast.Gt: ">",
            ast.GtE: ">=",
        }
        if type(op) in mapping:
            return mapping[type(op)]
        raise TranspileError(f"Unsupported cmpop: {type(op).__name__}")


def transpile(source: str) -> str:
    return Transpiler().transpile(source)


def transpile_ir(source: str, optimize: bool = False, sourcemap: bool = False, filename: str = ""):
    """Transpile via the IR pipeline (semantic -> IR -> Lua codegen)."""
    import ast
    from .semantic import analyze
    from .ir import IRLowerer
    from .codegen import generate, generate_with_sourcemap
    from .stdlib import STDLIB_LUA
    tree = ast.parse(source)
    scope = analyze(tree)
    ir = IRLowerer()
    module = ir.lower_module(tree, scope)
    if optimize:
        from .optimizer import optimize as opt_pass
        opt_pass(module)
    else:
        # Automatically run register allocation if a function's variable count threatens LuaJIT limits
        from .optimizer import allocate_registers_function
        for fn in module.functions:
            total_vars = len(getattr(fn, "locals", [])) + len(getattr(fn, "tmps", []))
            if total_vars > 80:
                allocate_registers_function(fn)
    has_module_entry = any(getattr(f, "is_entry_point", False) for f in module.functions)
    entry_call = "_luthon_module_entry()" if has_module_entry else "main()"
    if sourcemap:
        lua, sm = generate_with_sourcemap(module, filename=filename)
        return STDLIB_LUA + chr(10) + lua + chr(10) + entry_call, sm
    return STDLIB_LUA + chr(10) + generate(module) + chr(10) + entry_call

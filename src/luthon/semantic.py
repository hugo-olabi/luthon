"""Semantic analysis for Luthon."""
import ast
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set


@dataclass
class Scope:
    kind: str
    name: str
    parent: Optional["Scope"] = None
    locals: Dict[str, object] = field(default_factory=dict)
    globals: Set[str] = field(default_factory=set)
    nonlocals: Set[str] = field(default_factory=set)
    freevars: Set[str] = field(default_factory=set)
    cellvars: Set[str] = field(default_factory=set)
    children: List["Scope"] = field(default_factory=list)
    future_features: Set[str] = field(default_factory=set)

    def define(self, name, kind="local", node=None):
        sym = {"name": name, "kind": kind, "scope": self, "node": node}
        self.locals[name] = sym
        return sym


BUILTINS = {"abs","all","any","bool","dict","enumerate","float","int","len","list","max","min","range","set","sorted","str","sum","tuple","zip","True","False","None","print"}

# Recognized __future__ feature names
FUTURE_FEATURES = {
    "annotations", "division", "absolute_import", "print_function",
    "unicode_literals", "generator_stop", "nested_scopes",
    "with_statement", "generators", "generator_stop",
}


class SemanticAnalyzer(ast.NodeVisitor):
    def __init__(self):
        self.root = Scope(kind="module", name="<module>")
        self._stack = [self.root]
        self.errors = []

    @property
    def current(self):
        return self._stack[-1]

    def _push(self, s):
        s.parent = self.current
        self.current.children.append(s)
        self._stack.append(s)

    def _pop(self):
        self._stack.pop()

    def analyze_tree(self, tree):
        self.visit(tree)
        self._resolve_up(self.root)
        return self.root

    def analyze(self, source):
        if isinstance(source, ast.AST):
            return self.analyze_tree(source)
        tree = ast.parse(source)
        return self.analyze_tree(tree)

    def visit_Module(self, node):
        for s in node.body:
            self.visit(s)

    def visit_FunctionDef(self, node):
        scope = Scope(kind="function", name=node.name)
        for a in getattr(node.args, "posonlyargs", []):
            scope.define(a.arg, kind="param", node=a)
        for a in node.args.args:
            scope.define(a.arg, kind="param", node=a)
        for a in node.args.kwonlyargs:
            scope.define(a.arg, kind="param", node=a)
        if node.args.vararg:
            scope.define(node.args.vararg.arg, kind="param", node=node.args.vararg)
        if node.args.kwarg:
            scope.define(node.args.kwarg.arg, kind="param", node=node.args.kwarg)
        self._push(scope)
        for s in node.body:
            self.visit(s)
        self._pop()
        node._scope = scope

    def visit_AsyncFunctionDef(self, node):
        self.visit_FunctionDef(node)

    def visit_Lambda(self, node):
        scope = Scope(kind="function", name="<lambda>")
        for a in node.args.args:
            scope.define(a.arg, kind="param", node=a)
        if node.args.vararg:
            scope.define(node.args.vararg.arg, kind="param", node=node.args.vararg)
        if node.args.kwarg:
            scope.define(node.args.kwarg.arg, kind="param", node=node.args.kwarg)
        self._push(scope)
        self.visit(node.body)
        self._pop()
        node._scope = scope

    def visit_ClassDef(self, node):
        scope = Scope(kind="class", name=node.name)
        self._push(scope)
        for s in node.body:
            self.visit(s)
        self._pop()
        node._scope = scope

    def _comp(self, node):
        scope = Scope(kind="comprehension", name="<comp>")
        self._push(scope)
        for gen in node.generators:
            self._bind(gen.target)
            self.visit(gen.iter)
            for c in gen.ifs:
                self.visit(c)
        if hasattr(node, "elt"):
            self.visit(node.elt)
        if hasattr(node, "key"):
            self.visit(node.key)
        if hasattr(node, "value"):
            self.visit(node.value)
        self._pop()
        node._scope = scope

    def visit_ListComp(self, node): self._comp(node)
    def visit_SetComp(self, node): self._comp(node)
    def visit_DictComp(self, node): self._comp(node)
    def visit_GeneratorExp(self, node): self._comp(node)

    def visit_Assign(self, node):
        for t in node.targets:
            self._bind(t)
        self.visit(node.value)

    def visit_AnnAssign(self, node):
        if node.target is not None:
            self._bind(node.target)
        if node.value is not None:
            self.visit(node.value)

    def visit_AugAssign(self, node):
        self.visit(node.target)
        self.visit(node.value)

    def visit_For(self, node):
        self._bind(node.target)
        self.visit(node.iter)
        for s in node.body:
            self.visit(s)
        for s in node.orelse:
            self.visit(s)

    def visit_While(self, node):
        self.visit(node.test)
        for s in node.body: self.visit(s)
        for s in node.orelse: self.visit(s)

    def visit_If(self, node):
        self.visit(node.test)
        for s in node.body: self.visit(s)
        for s in node.orelse: self.visit(s)

    def visit_With(self, node):
        for item in node.items:
            self.visit(item.context_expr)
            if item.optional_vars is not None:
                self._bind(item.optional_vars)
        for s in node.body: self.visit(s)

    def visit_Try(self, node):
        for s in node.body: self.visit(s)
        for h in node.handlers:
            if h.name:
                self.current.define(h.name, kind="local", node=h)
            for s in h.body: self.visit(s)
        for s in node.orelse: self.visit(s)
        for s in node.finalbody: self.visit(s)

    def visit_Global(self, node):
        for n in node.names:
            self.current.globals.add(n)

    def visit_Nonlocal(self, node):
        for n in node.names:
            self.current.nonlocals.add(n)

    def visit_Import(self, node):
        for n in node.names:
            alias = n.asname or n.name.split(".")[0]
            self.current.define(alias, kind="local", node=n)

    def visit_ImportFrom(self, node):
        if node.module == "__future__":
            # Record __future__ features on the root (module) scope
            root = self._module()
            for n in node.names:
                if n.name in FUTURE_FEATURES:
                    root.future_features.add(n.name)
            return
        for n in node.names:
            alias = n.asname or n.name
            self.current.define(alias, kind="local", node=n)

    def visit_Expr(self, node):
        self.visit(node.value)

    def visit_Return(self, node):
        if node.value is not None:
            self.visit(node.value)

    def visit_Raise(self, node):
        if node.exc is not None:
            self.visit(node.exc)

    def visit_Assert(self, node):
        self.visit(node.test)
        if node.msg is not None:
            self.visit(node.msg)

    def visit_Delete(self, node):
        for t in node.targets:
            self.visit(t)

    def visit_Name(self, node):
        name = node.id
        if isinstance(node.ctx, ast.Store):
            if name not in self.current.globals and name not in self.current.nonlocals:
                if name not in self.current.locals:
                    self.current.define(name, kind="local", node=node)
            node._binding = self.current.locals.get(name)
            return
        node._binding = self._resolve(name, node)

    def _resolve(self, name, node):
        scope = self.current
        if name in scope.globals:
            root = self._module()
            if name not in root.locals:
                root.define(name, kind="global", node=node)
            return root.locals.get(name)
        if name in scope.nonlocals:
            s = scope.parent
            while s is not None:
                if name in s.locals:
                    s.cellvars.add(name)
                    scope.freevars.add(name)
                    return s.locals[name]
                s = s.parent
            self.errors.append(f"nonlocal '{name}' not found")
            return None
        s = scope
        first = True
        while s is not None:
            if name in s.locals:
                if s is not scope:
                    scope.freevars.add(name)
                    s.cellvars.add(name)
                return s.locals[name]
            if name in s.globals:
                root = self._module()
                if name not in root.locals:
                    root.define(name, kind="global", node=node)
                return root.locals.get(name)
            s = s.parent
            first = False
        if name in BUILTINS:
            root = self._module()
            if name not in root.locals:
                root.define(name, kind="global", node=node)
            return root.locals.get(name)
        root = self._module()
        if name not in root.locals:
            root.define(name, kind="global", node=node)
        return root.locals.get(name)

    def _module(self):
        s = self.current
        while s.parent is not None:
            s = s.parent
        return s

    def _bind(self, node):
        if isinstance(node, ast.Name):
            self.visit_Name(node)
        elif isinstance(node, (ast.Tuple, ast.List)):
            for e in node.elts:
                self._bind(e)
        elif isinstance(node, ast.Subscript):
            self.visit(node.value)
            self.visit(node.slice)
        elif isinstance(node, ast.Attribute):
            self.visit(node.value)

    def _resolve_up(self, scope):
        for child in scope.children:
            self._resolve_up(child)
            for fv in child.freevars:
                if fv in scope.locals:
                    scope.cellvars.add(fv)
        if scope.parent is not None:
            for fv in scope.freevars:
                if fv in scope.parent.locals:
                    scope.parent.cellvars.add(fv)

    def generic_visit(self, node):
        for child in ast.iter_child_nodes(node):
            self.visit(child)


def analyze(source):
    a = SemanticAnalyzer()
    return a.analyze(source)


def analyze_file(path):
    with open(path) as f:
        return analyze(f.read())


def future_features(source):
    """Return the set of __future__ features enabled in the given source."""
    root = analyze(source)
    return set(root.future_features)

# Luthon Self-Hosting Roadmap

Goal: make Luthon transpile its own Python source into Lua and run under LuaJIT.
Repo: https://github.com/hugo-olabi/luthon

Progress is tracked with GitHub task lists. Check boxes as work is completed.

## Summary

| Phase | Status | Steps |
|-------|--------|-------|
| Phase 0 — Baseline & Audit | ✅ Done | 4/4 |
| Phase 1 — Python Parser in Lua | ✅ Done | 5/5 |
| Phase 2 — Semantic Analyzer in Lua | ✅ Done | 6/6 |
| Phase 3 — IR Lowerer & Codegen in Lua | ✅ Done | 7/7 |
| Phase 4 — Complete Stdlib in Lua | ✅ Done | 5/5 |
| Phase 5 — Import System | ⬜ Todo | 5 |
| Phase 6 — Unsupported Constructs | ⬜ Todo | 7 |
| Phase 7 — Bootstrap — Transpile Luthon Itself | ⬜ Todo | 6 |
| Phase 8 — Correctness & Optimization | ⬜ Todo | 5 |

## Phase 0 — Baseline & Audit

- [x] List every Python stdlib module imported by `src/luthon/*.py` — `ast, pathlib, typing, hashlib, dataclasses, subprocess, os, sys, json`
- [x] List every Python language construct used in Luthon's own source — f-strings, comprehensions, `with`, `try`/`except`, decorators, keyword args
- [x] Mark each as implemented in Lua stdlib or missing — gap matrix recorded
- [x] Baseline: transpile `src/luthon/transpiler.py` and record failures — log of unsupported nodes/ops captured

## Phase 1 — Python Parser in Lua

Lua cannot call CPython's `ast.parse`. A pure-Lua Python parser is the largest blocker.

- [x] Define the Lua AST node schema — `Module, FunctionDef, ClassDef, Assign, Name, Call, BinOp, Compare, Constant, List, Dict, Subscript, Attribute, If, While, For, Return, Lambda, Import, etc.`
- [x] Write a Python tokenizer/lexer — identifiers, keywords, operators, strings, numbers, comments, indentation/dedent tracking
- [x] Write a recursive-descent parser — expressions, statements, suites, function/class definitions, imports
- [x] Produce AST nodes matching IR lowerer expectations — `lineno, col_offset, args, body, targets, value, ops, comparators`
- [x] Validate round-trip against CPython `ast.dump` — parse small Python file, compare structure with CPython output

## Phase 2 — Semantic Analyzer in Lua

Python semantic analyzer exists; Lua port complete.

- [x] Port `Scope` and `Symbol` dataclasses to Lua tables
- [x] Implement scope stack (module, function, class, comprehension, lambda)
- [x] Implement name resolution: local, global, nonlocal, free, cell, builtin
- [x] Implement `__future__` flag tracking
- [x] Implement decorator detection (`@dataclass`, etc.)
- [ ] Validate against Python semantic analyzer on Luthon's own source

## Phase 3 — IR Lowerer & Codegen in Lua

IR data model and codegen exist in Python (instr, blocks, goto/labels, closures). Ported to Lua.

- [x] Port `Instr, Block, Function, Module` IR dataclasses to Lua
- [x] Port statement lowering: `Assign, If, While, For, Return, Try, With, Break, AugAssign`
- [x] Port expression lowering: `BinOp, UnaryOp, Compare, Call, Name, Attribute, Subscript, List, Dict, Lambda`
- [x] Port control-flow lowering: basic blocks, goto, labels, branch instructions
- [x] Port closure/cell boxing: `MAKE_CELL, CELL_GET, CELL_SET`, upvalue propagation
- [x] Port class lowering: `MAKE_CLASS, SET_ATTR`, `__init__` synthesis, metatables
- [x] Port codegen: `CONST, LOAD, STORE, BINOP, CALL, RETURN, JUMP, BRANCH, MAKE_FUNCTION, MAKE_LIST, MAKE_DICT`

## Phase 4 — Complete Python Runtime Stdlib in Lua

Many modules done (math, os, sys, json, random, re, collections, itertools, functools, pathlib, datetime, string, base64, io, struct, hashlib, typing, site, tempfile, dataclasses, subprocess). Missing: `ast.parse`, full pathlib, full subprocess exit codes, real cryptographic hashlib.

- [x] Implement `ast.parse` in Lua (depends on Phase 1)
- [x] Complete `pathlib.Path` (glob, resolve, is_absolute, is_relative_to)
- [x] Complete `subprocess` with real exit code capture
- [x] Replace simplified `hashlib` with real implementations or FFI to OpenSSL
- [x] Implement missing builtins: `set, frozenset, slice, property, staticmethod, classmethod, super`
- [ ] Implement `try/except/finally, with/contextmanager, assert, raise`
- [ ] Implement f-strings, chained comparisons, boolean `and`/`or` short-circuit

## Phase 5 — Import System & Package Resolution

`ModuleLoader` exists in Python with site-packages search. No Lua module system with `sys.modules` cache.

- [ ] Implement `sys.modules` cache in Lua
- [ ] Implement relative import resolution (`from .foo import bar`)
- [ ] Implement package `__init__.py` execution and namespace
- [ ] Implement circular import handling
- [ ] Integrate with `ModuleLoader` so `import luthon.semantic` works in transpiled Lua

## Phase 6 — Unsupported Constructs (long tail)

`try/except`, `with`, `assert`, f-strings, chained comparisons, boolean `and`/`or` not yet in IR.

- [ ] Implement `try/except/finally` with exception objects and traceback
- [ ] Implement `with/contextlib.contextmanager`
- [ ] Implement set/dict comprehensions and generator expressions
- [ ] Implement f-strings
- [ ] Implement chained comparisons (`a < b < c`)
- [ ] Implement boolean `and`/`or` as short-circuit expressions
- [ ] Implement `del`, `nonlocal`, `global` statement edge cases

## Phase 7 — Bootstrap — Transpile Luthon Itself

Not started. Requires Phases 1–6.

- [ ] Create `bootstrap.lua`: Lua runtime prelude (stdlib + IR runtime helpers)
- [ ] Write Lua driver `luthon_lua.lua`: read `.py`, parse, analyze, lower to IR, generate Lua
- [ ] Transpile Luthon's own source files one at a time
- [ ] Fix semantic mismatches (truthiness, integer division, string methods, exception types)
- [ ] Run transpiled Luthon under LuaJIT on a small test program
- [ ] Compare output against CPython Luthon on the same input

## Phase 8 — Correctness & Optimization

Not started.

- [ ] Build test harness: run Luthon (CPython) and transpiled Luthon (LuaJIT) on same inputs, diff outputs
- [ ] Add property-based tests for the parser (round-trip `ast.dump`)
- [ ] Optimize: remove temporary locals, inline constants, dead-code elimination
- [ ] Add source maps (VLQ) wired into IR codegen output
- [ ] Performance benchmark: self-transpilation speed under LuaJIT vs CPython

## How to update

This file lives in the repo. When a step is completed, check its box and commit:

```bash
git add ROADMAP.md
git commit -m "docs(roadmap): mark <step> complete"
git push
```

The agent reads this file at the start of work and updates checked boxes as phases progress.

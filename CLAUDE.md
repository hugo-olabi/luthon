# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Luthon is a Python to LuaJIT transpiler targeting high-performance execution of numeric, algorithmic, and object-oriented Python programs under LuaJIT 2.1+. It features two Python-based transpilation pipelines and an ongoing self-hosting pure-Lua pipeline.

## Development Commands

### Testing
- Run all tests: `pytest`
- Run a specific test file: `pytest tests/test_transpiler.py`
- Run a single test: `pytest tests/test_transpiler.py::test_basic_transpile`
- Run tests with output: `pytest -v -s`

*Note: If `luthon` is not installed into the Python environment, prefix Python commands with `PYTHONPATH=src`.*

### Building & Installing
- Install editable package: `pip install -e .` (or `pip install -e ".[dev]"`)

### Running Luthon CLI
- Transpile via direct AST visitor: `python3 -m luthon.main transpile <input.py> -o <output.lua>`
- Transpile via IR backend: `python3 -m luthon.main transpile <input.py> --ir -o <output.lua>`
- Run semantic analyzer on file: `python3 -m luthon.main analyze <input.py>`
- Transpile bypassing cache: `python3 -m luthon.main transpile <input.py> --no-cache -o <output.lua>`
- Execute compiled Lua under LuaJIT: `luajit <output.lua>`

### Self-Hosting / Bootstrap Pipeline (Pure Lua)
- Run pure-Lua transpiler driver: `luajit src/luthon/lua/luthon_lua.lua <input.py> [output.lua]`

## Architecture & Code Structure

### 1. Python Pipeline (`src/luthon/`)

There are two transpilation paths sharing the runtime prelude:

- **Direct AST Pipeline**: `source` -> `ast.parse` -> `Transpiler` (in `transpiler.py`) -> Lua output.
- **IR Backend Pipeline (`--ir` or `transpile_ir`)**:
  - `semantic.py` (`SemanticAnalyzer`): Scopes (`Scope`, `Symbol`), lexical binding, upvalue and closure analysis, cell/free variable tagging, and `__future__` feature handling.
  - `ir.py` (`IRLowerer`): Lowers AST nodes into a `Module` of `Function`s composed of labeled `Block`s containing `Instr` instructions. Conditionals and loops lower to explicit jumps (`JUMP`, `BRANCH`, `BRANCH_NONE`). Cell variables use `MAKE_CELL`, `CELL_GET`, `CELL_SET`.
  - `codegen.py` (`generate`): Emits Lua code from the IR. Maps instructions to Lua operations, converts control flow into `goto` and `::label::`, synthesizes class and dataclass metatables, and manages variable scoping.
  - `stdlib.py` (`STDLIB_LUA`): Lua string embedded into generated files. Implements Python builtins (`range`, `len`, `enumerate`, `zip`, etc.) and modules (`math`, `os`, `sys`, `json`, `re`, `collections`, `itertools`, `functools`, `pathlib`, `dataclasses`, `subprocess`, etc.).
  - `modules.py` (`ModuleLoader`): Python module and package resolution across `sys.path`, `site-packages`, and `PYTHONPATH`.
  - `cache.py` (`CompilationCache`): Persistent compilation cache in `.luthon_cache`. Uses two-tier invalidation (stat mtime/size check, followed by content hashing) and atomic writes.
  - `sourcemap.py`: VLQ-encoded source map generation.

### 2. Self-Hosting Bootstrap Pipeline (`src/luthon/lua/`)

A pure-Lua implementation of the transpilation toolchain to enable compiling Luthon without CPython's `ast`:
- `parser.lua`: Tokenizer, lexer, and recursive-descent Python AST parser in Lua.
- `semantic.lua`: Lua port of scope hierarchy and symbol analysis.
- `ir.lua`: Lua port of the IR lowerer.
- `codegen.lua`: Lua port of the IR-to-Lua code generator.
- `bootstrap.lua`: Lua runtime prelude with stdlib and IR helpers.
- `modules.lua`: Module resolution in Lua with `sys.modules` caching and circular import handling.
- `luthon_lua.lua`: Driver coordinating parse, semantic, IR lowering, and codegen.

## Important Implementation Details

- **LuaJIT Local Variable Limit**: LuaJIT restricts functions to 200 local variables. `codegen.py` checks total locals + temporaries; if `<= 150`, temporaries are declared `local`; otherwise, they fall back to globals to prevent exceeding the limit.
- **Indexing Semantics**: Python is 0-indexed, Lua is 1-indexed. Tables are not shifted at compile time; instead, numeric subscripts use a runtime `+ 1` offset check (`type(_i) == "number"`), preserving string keys for dictionaries and objects.
- **Control Flow**: Generated Lua requires LuaJIT specifically because it relies on `goto` and `::label::` statements (unsupported in standard Lua 5.1).
- **Closures & Upvalues**: Free variables captured by nested functions are boxed via `{value = ...}` cells. `codegen.py` propagates upvalue names into enclosing function locals so Lua naturally captures them.
- **Unsupported Syntax**: Unsupported Python statements lower to no-ops in the IR backend rather than failing compilation immediately.

# Luthon

Luthon is a high-performance Python to LuaJIT transpiler with an optimizing compiler backend. It parses Python source, runs semantic analysis, lowers programs to an intermediate representation (IR/CIR) with explicit control flow, and emits optimized Lua that executes under LuaJIT 2.1+.

The goal is not to interpret Python. The goal is to take Python programs—including functions, closures, classes, generators, comprehensions, numerical pipelines, and standard library modules—and produce Lua code that runs with near-native speed.

## Why

LuaJIT has an exceptionally fast trace compiler and a minimal memory footprint. Python is expressive and has a massive ecosystem. Luthon connects the two:
- Numeric algorithms and mathematical loops execute up to 10x-50x faster than CPython.
- Memory consumption is drastically reduced through unboxed FFI buffers and allocation sinking.
- Full standalone executable packaging is supported without requiring Python or Lua installed on target hosts.

## Installation

```bash
pip install -e .
```

Requirements:
- Python 3.9 or newer (for CPython AST pipeline)
- LuaJIT 2.1 or newer (generated Lua targets LuaJIT `goto` and FFI extensions)

## Usage

### 1. Compile and Run Directly

```bash
luthon run script.py [args...]
# Shorthand:
luthon script.py [args...]
```

### 2. Transpile Python to Lua

```bash
# Transpile via optimizing IR backend
luthon transpile input.py -o output.lua

# Transpile with full optimizations (CPA type inference, constant folding, DCE)
luthon transpile input.py -O -o output.lua

# Transpile with VLQ source maps for debugging
luthon transpile input.py --sourcemap -o output.lua
```

### 3. Build Standalone Native Executables

Package any Python script into a self-contained executable bundle:

```bash
luthon build script.py -o myapp
./myapp [arguments...]
```

### 4. Package Management (luthon-pip)

Install and AOT-precompile Python packages from PyPI into Luthon site-packages:

```bash
# Install a package from PyPI
luthon install package_name

# Package manager CLI
luthon pip install -r requirements.txt
luthon pip list
luthon pip uninstall package_name

# Create an isolated virtual environment
luthon venv .my_env
```

### 5. JIT Profiling and Trace Diagnostics

```bash
# Profile LuaJIT trace execution
luthon run input.py --profile

# Dump JIT bytecode and trace IR
luthon run input.py --dump-traces
```

### 6. Pure-Lua Bootstrap Pipeline (Self-Hosting)

Luthon can compile without CPython using its pure-Lua toolchain:

```bash
luajit src/luthon/lua/luthon_lua.lua input.py output.lua
```

## Architecture

Luthon features two transpilation pipelines sharing a runtime prelude:

### Pipeline Overview

```
source
  -> AST Parser (ast.parse or pure-Lua parser.lua)
  -> SemanticAnalyzer (scopes, symbol binding, closures, cell variables)
  -> CIR / IRLowerer (typed SSA, control-flow basic blocks, magic methods)
  -> Optimizer (CPA type inference, constant folding, DCE, register allocation, ASO)
  -> Codegen (LuaJIT emission, vtables, unboxed FFI buffers)
  -> Lua output + stdlib prelude
```

| Component | File | Description |
| --- | --- | --- |
| `semantic.py` / `semantic.lua` | Frontend | Scoped symbol tables, lexical binding, upvalue and closure capture. |
| `cir.py` | Intermediate Rep | Typed High-Level IR (CIR), CPA type inference, call-site monomorphization. |
| `ir.py` / `ir.lua` | Intermediate Rep | Basic block instruction lowering, explicit branching and landing pads. |
| `optimizer.py` | Optimizer | Constant folding, copy propagation, dead-code elimination, register pooling. |
| `nyi.py` | JIT Diagnostics | Static NYI auditor, loop-invariant allocation hoisting, CData memory anchoring. |
| `codegen.py` / `codegen.lua` | Code Generation | Emits LuaJIT gotos, labels, FFI structs, and class metatables. |
| `stdlib.py` / `bootstrap.lua` | Runtime | Complete Lua runtime prelude implementing Python builtins and modules. |
| `hpy.lua` | Native Interop | HPy Universal ABI trampoline and zero-copy NumPy array wrapping. |
| `pybridge.lua` | Native Interop | Lazy CPython FFI bridge for transparent PyObject proxying. |
| `bundle.py` | Packager | Amalgamation builder for standalone executable bundles. |
| `pip.py` | Package Manager | PyPI wheel resolver, universal wheel unpacker, and venv manager. |
| `benchmarks.py` | Benchmarks | PyPerformance workload runner and performance comparison dashboard. |
| `cache.py` | Caching | Two-tier persistent compilation cache in `.luthon_cache`. |
| `sourcemap.py` | Debugging | VLQ-encoded source map generator. |

## Language and Standard Library Coverage

### Supported Language Features

- Variables, multi-variable tuple unpacking (`a, b, c = 1, 2, 3`), and annotated assignments
- Control flow: `if`, `elif`, `else`, `while`, `for` (over sequences, generators, ranges), `break`, `continue`
- Functions, default argument values, keyword arguments, nested functions, lambdas
- Closures and cell boxing for captured variables
- Classes, dataclasses (`@dataclass`), single and prototype inheritance, method dispatch
- Fixed-layout C structs via `@struct` / `@native_struct` with `ffi.metatype` vtables
- Exception handling: `try`, `except`, `finally`, `raise`, `assert`
- Context managers: `with` statements and custom `__enter__` / `__exit__` class protocols
- Generators: generator functions, `yield`, and `yield from` sub-generator delegation
- Data structures: lists, tuples, dictionaries, sets, and comprehensions (list, dict, set)
- Vectorized mathematics: 2D `matrix` type with native `@` (`__matmul__`) operator support
- f-strings, short-circuit boolean `and`/`or`, chained comparisons (`1 < x < 10`)
- Negative sequence indexing (`s[-1]`) with Python parity

### Standard Library Modules in Lua

| Module | Features Supported |
| --- | --- |
| `math` | All standard trigonometric, exponential, and rounding functions with FFI C bindings |
| `os` / `os.path` | Environment variables, filesystem operations, path manipulation (`join`, `exists`, etc.) |
| `sys` | `argv` argument passing, `path`, `version`, `exit`, `stdout`, `stderr`, `stdin` |
| `json` | Fast `dumps`, `loads`, `encode`, `decode` supporting nested structures and escapes |
| `re` | `match`, `search`, `sub`, `findall` mapped to Lua pattern matching |
| `collections` | `deque`, `defaultdict`, `Counter`, `OrderedDict` |
| `itertools` | `chain`, `product`, `permutations`, `combinations` |
| `functools` | `reduce`, `partial`, `lru_cache` |
| `pathlib` | `Path` with resolution, directory checks, reading, writing, and navigation |
| `array` / `ffi` | High-performance unboxed typed memory buffers (`array('d')`) and raw FFI bindings |
| `subprocess` | Process spawning, returncode capture, output inspection (`run`, `Popen`, `call`) |
| `hashlib` | Direct FFI bindings to OpenSSL `libcrypto` (`sha256`, `md5`, `sha1`, `sha512`) |
| `random` | `seed`, `random`, `randint`, `choice`, `shuffle`, `uniform` |
| `datetime` | `date`, `time`, `datetime`, `timedelta` |
| `base64` | `b64encode`, `b64decode` |
| `struct` | Binary packing and unpacking |

## Performance and Benchmarks

Luthon includes an automated benchmark harness running standard Computer Language Benchmarks Game (CLBG) and PyPerformance workloads against CPython 3.13:

| Benchmark | Workload | CPython 3.13 | Luthon (LuaJIT) | Speedup |
| --- | --- | --- | --- | --- |
| Fibonacci | `fib(36)` recursion | 5.26 s | 0.40 s | ~13x |
| Mandelbrot | 500x500 grid, 50 iterations | 3.26 s | 0.17 s | ~19x |
| Spectral-Norm | CLBG 100x100 matrix vectorization | 0.14 s | 0.01 s | ~14x |
| Float Norm | 1000 3D vector normalizations | 0.15 s | 0.05 s | ~2.8x |
| Fannkuch | Permutation generation | 0.06 s | 0.03 s | ~2.0x |
| Richards | OS task dispatcher simulation | 0.09 s | 0.04 s | ~2.2x |

## AI Disclaimer and Community Contribution

This project is an experimental endeavor created to explore the boundaries of transpiling Python to LuaJIT with a real optimizing compiler backend. Writing this entire compiler toolchain manually from scratch would have taken months or even over a year. With this context in mind, human code review, real-world bug reports, and community contributions are very welcome! If you spot an edge case or have ideas for performance improvements, please feel free to open an issue or pull request.

## Running Tests

Run the full test suite (107 tests across 25 modules):

```bash
pytest
```

Run with verbose output:

```bash
pytest -v
```

## Development and Repository Structure

```
src/luthon/
  cir.py            Typed High-Level IR, CPA type inference, monomorphization
  ir.py             Instruction-level lowering, basic blocks, control flow
  optimizer.py      Constant folding, copy propagation, DCE, register allocation
  codegen.py        LuaJIT code generator, vtables, FFI cdefs
  bundle.py         Standalone binary packaging and amalgamation builder
  benchmarks.py     PyPerformance benchmark runner and dashboard
  pip.py            Wheel installer, PyPI resolver, virtual environment manager
  nyi.py            Static NYI trace auditor and CData memory anchoring
  ffi.py            CFFI translation and native library binding generator
  semantic.py       Symbol tables, lexical binding, closure analysis
  stdlib.py         Embedded Lua runtime prelude
  lua/              Pure-Lua self-hosting bootstrap pipeline (parser, semantic, ir, codegen)
tests/              Comprehensive pytest test suite (test_phase9 through test_phase24)
```

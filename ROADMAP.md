# Luthon Self-Hosting Roadmap

Goal: make Luthon transpile its own Python source into Lua and run under LuaJIT.
Repo: https://github.com/hugo-olabi/luthon

Progress is tracked with GitHub task lists. Check boxes as work is completed.

## Summary

| Phase | Status | Steps |
|-------|--------|-------|
| Phase 0 — Baseline & Audit | [Done] | 4/4 |
| Phase 1 — Python Parser in Lua | [Done] | 5/5 |
| Phase 2 — Semantic Analyzer in Lua | [Done] | 6/6 |
| Phase 3 — IR Lowerer & Codegen in Lua | [Done] | 7/7 |
| Phase 4 — Complete Stdlib in Lua | [Done] | 5/5 |
| Phase 5 — Import System & Package Resolution | [Done] | 5/5 |
| Phase 6 — Unsupported Constructs | [Done] | 7/7 |
| Phase 7 — Bootstrap — Transpile Luthon Itself | [Done] | 6/6 |
| Phase 8 — Correctness & Optimization | [Done] | 5/5 |
| Phase 9 — Advanced Architecture & JIT Specialization | [Done] | 7/7 |
| Phase 10 — C Extensions, Native FFI & Hybrid Python Bridge | [Done] | 6/6 |
| Phase 11 — Luthon Package Manager (luthon-pip) | [Done] | 6/6 |
| Phase 12 — Pipeline Parity & Full Source Self-Compilation | [Done] | 6/6 |
| Phase 13 — High-Performance JIT Optimization & NYI Elimination | [Done] | 3/3 |
| Phase 14 — Numeric Acceleration & Unboxed FFI Memory | [Done] | 3/3 |
| Phase 15 — Python Language Parity (Generators & Dynamic Args) | [Done] | 4/4 |
| Phase 16 — Multi-Stage Self-Hosting Bootstrap & Fixpoint Loop | [Done] | 3/3 |
| Phase 17 — Typed High-Level IR (CIR) & SSA Monomorphization | [Done] | 4/4 |
| Phase 18 — Allocation Sinking, Object Virtualization & Vtables | [Done] | 4/4 |
| Phase 19 — Strict LuaJIT Trace JIT Specialization & NYI Eliminator | [Done] | 4/4 |
| Phase 20 — Native HPy Universal ABI & Zero-Copy CData Buffers | [Done] | 4/4 |
| Phase 21 — Real-Time Systems, Zero-GC Freelists & Domain Benchmarks | [Done] | 4/4 |
| Phase 22 — PyPerformance Full Benchmarking Suite & Profiler | [Done] | 4/4 |
| Phase 23 — Standalone Embedded Executable Packaging (Luthon Static Bundle) | [Done] | 4/4 |
| Phase 24 — SIMD Vectorized Numeric Arrays & OpenBLAS Integration | [Done] | 4/4 |
| Phase 25 — Real-World Ecosystem Compatibility & Showcase Verification | [Done] | 5/5 |
| Phase 26 — High-Throughput Asset & Serialization Performance | [Done] | 4/4 |
| Phase 27 — Deep C-API Emulation, Native Codecs & Zero-Bridge Pipelines | [Done] | 4/4 |
| Phase 28 — Modular C Native Library Architecture & Core Runtime Expansion | [Done] | 4/4 |

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
- [x] Validate against Python semantic analyzer on Luthon's own source

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
- [x] Implement `try/except/finally, with/contextmanager, assert, raise`
- [x] Implement f-strings, chained comparisons, boolean `and`/`or` short-circuit

## Phase 5 — Import System & Package Resolution

`ModuleLoader` exists in Python with site-packages search. No Lua module system with `sys.modules` cache.

- [x] Implement `sys.modules` cache in Lua
- [x] Implement relative import resolution (`from .foo import bar`)
- [x] Implement package `__init__.lua` execution and namespace
- [x] Implement circular import handling
- [x] Integrate with `ModuleLoader` so `import luthon.semantic` works in transpiled Lua

## Phase 6 — Unsupported Constructs (long tail)

All Phase 6 constructs implemented.

- [x] Implement set/dict comprehensions and generator expressions
- [x] Implement boolean `and`/`or` as short-circuit expressions
- [x] Implement `try/except/finally` with exception objects and traceback
- [x] Implement `with/contextlib.contextmanager`
- [x] Implement `assert`
- [x] Implement f-strings
- [x] Implement chained comparisons (`a < b < c`)
- [x] Implement `del`, `nonlocal`, `global` statement edge cases

## Phase 7 — Bootstrap — Transpile Luthon Itself

Requires Phases 1–6.

- [x] Create `bootstrap.lua`: Lua runtime prelude (stdlib + IR runtime helpers)
- [x] Write Lua driver `luthon_lua.lua`: read `.py`, parse, analyze, lower to IR, generate Lua
- [x] Transpile Luthon's own source files one at a time
- [x] Fix semantic mismatches (truthiness, integer division, string methods, exception types)
- [x] Run transpiled Luthon under LuaJIT on a small test program
- [x] Compare output against CPython Luthon on the same input

## Phase 8 — Correctness & Optimization

- [x] Build test harness: run Luthon (CPython) and transpiled Luthon (LuaJIT) on same inputs, diff outputs
- [x] Add property-based tests for the parser (round-trip `ast.dump`)
- [x] Optimize: remove temporary locals, inline constants, dead-code elimination
- [x] Add source maps (VLQ) wired into IR codegen output
- [x] Performance benchmark: self-transpilation speed under LuaJIT vs CPython

## Phase 9 — Advanced Architecture & JIT Specialization

Focus on LuaJIT trace compilation (NYI avoidance), register allocation, and deep runtime fidelity.

- [x] Optimize subscript indexing: replace inlined closures with `__luthon_get`/`__luthon_set` runtime helpers and static integer indexing to eliminate LuaJIT JIT trace aborts
- [x] Implement negative index wrapping semantics (`s[-1]`) for Python sequence parity
- [x] Implement linear-scan register allocation / temporary variable pooling in `optimizer.py` to prevent LuaJIT 200-local limit spillover into global variables
- [x] Implement function prologue default argument and keyword argument unpacking in Python IR lowerer (`ir.py`)
- [x] Port structured `try/except/finally` landing-pad lowering from `src/luthon/lua/ir.lua` to `src/luthon/ir.py`
- [x] Fast prototype-based class inheritance (`__index = cls`) to eliminate per-instance method copying
- [x] Port VLQ source map generator to pure Lua (`src/luthon/lua/sourcemap.lua`) for standalone debugging

## Phase 10 — C Extensions, Native FFI & Hybrid Python Bridge

Enable transparent use of Python C extensions and native C libraries without sacrificing LuaJIT speed.

- [x] Automated Python `cffi` translation: lower `cffi.FFI().cdef(...)` declarations directly to LuaJIT `ffi.cdef[[...]]`
- [x] Direct native FFI wrappers for common C-API modules (`sqlite3` -> `libsqlite3.so`, `zlib` -> `libz.so`, `ssl`/`hashlib` -> `libcrypto.so`)
- [x] Lazy on-demand CPython bridge: load `libpython3.so` via LuaJIT FFI only when an unsupported binary C extension is imported
- [x] Transparent Python object proxy: marshal basic types (int, float, str, bool, list, dict) across the LuaJIT <-> CPython FFI boundary
- [x] Opaque pointer passing: hold `PyObject*` references in LuaJIT for complex objects (e.g. `numpy.ndarray`, PyTorch tensors) without full serialization
- [x] Fallback module loader: waterfall import resolution (Pure Lua -> Pure .py in site-packages -> Native FFI shim -> Lazy libpython)

## Phase 11 — Luthon Package Manager (luthon-pip)

Enable direct installation, dependency resolution, pre-compilation (AOT to Lua), and virtual environment isolation for Python packages running on Luthon under LuaJIT.

- [x] Direct Wheel Installer & PyPI Client: query PyPI JSON API and download/unpack pure Python universal wheels (`*.whl`) into Luthon site-packages
- [x] AOT Pre-compiler: automatically compile downloaded `.py` packages into optimized `.lua` modules upon installation
- [x] Dependency Resolution & Metadata Parser: parse `.dist-info/METADATA` (`Requires-Dist`) and recursively install required dependencies
- [x] Package Management CLI (`luthon pip` & `luthon install`): implement `install`, `uninstall`, `list`, `freeze`, and `-r requirements.txt`
- [x] Virtual Environment Support (`luthon venv`): create isolated `.luthon_env` directories with scoped search paths and binaries
- [x] Pure-Lua Runtime Package Resolution: wire `~/.luthon/site-packages` and `.luthon_env` into `src/luthon/lua/modules.lua` and Python `ModuleLoader`

## Phase 12 — Pipeline Parity & Full Source Self-Compilation

Address discrepancies between the Python IR pipeline and Lua bootstrap pipeline so that 100% of Luthon's source files compile and run under both pipelines.

- [x] Fix comparison operator lowering (`in` and `not in`) in Python `codegen.py` to call `_luthon_in` and `_luthon_not_in`
- [x] Add runtime `_luthon_in` and `_luthon_not_in` helpers to Python `stdlib.py` matching `bootstrap.lua`
- [x] Fix bitwise operator normalization in Python `codegen.py` (`bitand`, `bitor`, `bitxor`, `lshift`, `rshift`)
- [x] Fix Lua statement ordering in `try/except` landing pads when handlers end with `return`
- [x] Support raw string literals (`r"..."`, `R"..."`) and multi-prefix strings in pure-Lua lexer (`parser.lua`)
- [x] Support multi-target unpacking assignments and RHS comma-separated tuples in pure-Lua parser (`parser.lua`)

## Phase 13 — High-Performance JIT Optimization & NYI Elimination

Eliminate LuaJIT NYI bytecode aborts to ensure tight loops run entirely within the JIT trace compiler.

- [x] Trace-friendly sequence iterations: replace `pairs()` with `ipairs()` or indexed numeric loops in runtime helpers
- [x] File-level local aliasing: emit local aliases for standard library primitives (`local _bit_band = bit.band`, `local _math_floor = math.floor`)
- [x] Register allocation & temporary reuse: implement live-range temporary variable pooling in `optimizer.py` to prevent LuaJIT 200-local limit spillover

## Phase 14 — Numeric Acceleration & Unboxed FFI Memory

Leverage LuaJIT FFI for high-performance numeric and algorithmic execution.

- [x] Unboxed numeric arrays: specialized contiguous memory buffers (`ffi.new("double[?]")`) for homogeneous numeric Python lists
- [x] Native C-runtime mathematical bindings: direct `ffi.C` bindings for intensive math operations (`sqrt`, `sin`, `cos`, `exp`)
- [x] Fast slicing and memory copies for native buffers via `ffi.copy` and pointer arithmetic

## Phase 15 — Python Language Parity (Generators & Dynamic Args)

Extend Python language feature coverage in both transpilation pipelines.

- [x] Generator functions and coroutines (`yield` / `yield from`) lowered via Lua coroutines (`coroutine.create` / `coroutine.yield`)
- [x] Arbitrary positional (`*args`) and keyword (`**kwargs`) parameter unpacking in function definitions and call sites
- [x] Extended dictionary and string methods (`dict.setdefault`, `dict.popitem`, `%` string formatting, `str.format`)
- [x] Context manager `__enter__` and `__exit__` full protocol parity for custom classes

## Phase 16 — Multi-Stage Self-Hosting Bootstrap & Fixpoint Loop

Achieve true self-hosting verification with a multi-stage compilation cycle.

- [x] Stage 1: Transpile all `src/luthon/*.py` files using CPython pipeline into standalone Lua modules
- [x] Stage 2: Execute transpiled Stage 1 compiler under LuaJIT to recompile `src/luthon/*.py` into Stage 2
- [x] Stage 3: Assert fixpoint equality between Stage 1 and Stage 2 outputs with an automated CI test suite

## Phase 17 — Typed High-Level IR (CIR) & SSA Monomorphization

Incorporate research findings from Codon, Numba, and PyPy into Luthon's intermediate representation.

- [x] High-Level IR (CIR): position a typed intermediate representation between the AST and Lua lowerer that normalizes primitive operations into typed magic method invocations (`int.__add__[int, int]`)
- [x] Constraint-Based Type Inference (CPA): implement monotonic type-set propagation across SSA phi nodes and control-flow merges
- [x] Call-Site Monomorphization: specialize polymorphic function definitions for concrete scalar argument types (`int`, `float`, `bool`) to generate unboxed, branchless Lua routines
- [x] Idiomatic Pattern Fusion: early optimizer passes to recognize and fuse high-level dictionary and sequence idioms (`d[k] = d.get(k, 0) + 1`, chained range iteration) before lowering

## Phase 18 — Allocation Sinking, Object Virtualization & Vtables

Eliminate runtime heap pressure and object dispatch overhead inspired by PyPy OptVirtualize, mypyc, and LuaJIT ASO.

- [x] Class Immutability & Early Binding: enforce immutable class scopes to route method invocations through direct, fixed-offset vtables instead of runtime metatable searches
- [x] Object Virtualization: track short-lived cell boxes, small tuples, and intermediate records so they remain in CPU register states without triggering heap allocations
- [x] Allocation Sinking Optimization (ASO/SSO): shape emitted Lua local records to guarantee LuaJIT's native allocation sinking optimization elides allocations along fast loop traces
- [x] Fixed-Layout Struct Representations: compile class instances into fixed `ffi.cdef` C struct representations with direct base-plus-offset memory addressing

## Phase 19 — Strict LuaJIT Trace JIT Specialization & NYI Eliminator

Eliminate trace compiler aborts to keep inner loops 100% on fast machine code traces.

- [x] Static NYI Checker & Audit Linter: static pass across lowered IR to guarantee no NYI bytecodes or operations (such as table initializers in inner loops) are emitted
- [x] Pass-by-Reference Aggregate Enforcement: ensure all C structs and FFI aggregates are passed and returned by pointer/reference rather than by value to avoid interpreter fallback
- [x] CData Memory Anchoring: establish a Lua-side anchor registry for raw pointer targets to eliminate use-after-free bugs with unmanaged C memory
- [x] Trace Stitching Elimination: replace non-JIT compilable builtin calls along hot paths with JIT-friendly primitives to avoid trace stitching overhead

## Phase 20 — Native HPy Universal ABI & Zero-Copy CData Buffers

Provide modern, moving-GC-compatible C extension interoperability based on HPy research findings.

- [x] HPy Universal ABI Trampoline: implement a LuaJIT FFI loader for the HPy Universal ABI, replacing raw `PyObject*` pointers with opaque handles and ownership semantics
- [x] Zero-Copy NumPy C-API Wrapping: support `PyArray_SimpleNewFromData` semantics over LuaJIT FFI contiguous memory buffers without serialization
- [x] Refcount Elimination in Extensions: enable C extensions compiled against `hpy.h` to run at native speed without emulating CPython's reference counting or address stability
- [x] Universal Wheel Loader for HPy: integrate HPy wheel resolution into `luthon-pip` for drop-in package installation

## Phase 21 — Real-Time Systems, Zero-GC Freelists & Domain Benchmarks

Target ultra-low latency, game scripting, quantitative finance, and embedded systems based on Snabb and LuaVTS patterns.

- [x] Zero-GC Preallocated Memory Freelists: implement memory freelist pools for financial models and game loops to eliminate garbage collection jitter entirely during steady-state processing
- [x] Host-to-Script Fast Edge: provide ultra-low latency (~10ns) C host invocation bindings for embedding Luthon in game engines and simulation runtimes
- [x] PyPerformance & CLBG Automated Benchmark Suite: integrate real-world benchmark suites (nbody, spectral-norm, binary-trees, json-parsing) measuring speedups vs CPython and PyPy
- [x] Embedded & Edge Profile: generate minimal standalone LuaJIT bundles (<500 KB) for memory-constrained and edge IoT devices

## Phase 22 — PyPerformance Full Benchmarking Suite & Profiler

Implement comprehensive benchmarking across realistic Python workloads measuring speedup against CPython and PyPy.

- [x] PyPerformance Micro & Macro Workloads: transpile and benchmark standard workloads (richards, fannkuch, spectral_norm, json_loads, float, deltablue)
- [x] JIT Trace Profiler & Diagnostics: emit JIT profiler command-line hooks (`luthon --profile` / `luthon --dump-traces`) using LuaJIT's `jit.p` and `jit.dump`
- [x] Automated Performance Regression Tests: add CI benchmark assertions ensuring transpiled algorithms do not regress in execution time
- [x] Speedup Dashboard: generate structured JSON and Markdown comparison reports of Luthon vs CPython 3.13 and PyPy

## Phase 23 — Standalone Embedded Executable Packaging (Luthon Static Bundle)

Enable single-binary compilation packaging Luthon Python scripts into standalone native executables.

- [x] Amalgamation Builder: combine runtime prelude, user modules, and LuaJIT bytecode into a single self-contained `.c` or object file
- [x] Embedded C Driver: provide a minimal C runner (`main.c`) initializing the LuaJIT VM and invoking the entry point without requiring Python or Lua installed
- [x] Single-Binary CLI (`luthon build --standalone`): CLI command compiling Python source into a standalone ELF / Mach-O executable
- [x] Binary Footprint Optimization: strip unused stdlib modules to produce executables under 1 MB for edge / IoT distribution

## Phase 24 — SIMD Vectorized Numeric Arrays & OpenBLAS Integration

Leverage SIMD CPU vectorization and native BLAS libraries for matrix operations.

- [x] BLAS FFI Bindings: provide direct FFI bindings to system `libopenblas.so` or `libblas.so` for `dgemm`, `dgemv`, and dot products
- [x] Vectorized Array Operations: element-wise arithmetic (+, -, *, /) on `array('d')` using 128/256-bit SIMD intrinsics or unrolled FFI loops
- [x] Multi-Dimensional Strided Slicing: support 2D and 3D tensor indexing with stride arrays without memory copying
- [x] Matrix Multiplication Operator (`@` / `__matmul__`): lower Python `@` operator on 2D arrays directly to `cblas_dgemm`

## Phase 25 — Real-World Ecosystem Compatibility & Showcase Verification

Harden compiler, codegen, runtime stdlib, and module loader against real-world third-party packages and advanced showcase examples.

- [x] Entry-Point & Name Environment Parity: ensure `__name__` evaluates to `"__main__"` when executing entry modules under LuaJIT without accidental local shadowing
- [x] Safe List Literal Codegen: fix `MAKE_LIST` in `codegen.py` to prevent erroneous string quoting of register variables (`_r*`) and numeric expressions
- [x] Stdlib Builtins & Metamethod Expansion: implement `isinstance` in runtime preludes and register `super`, `getattr`, `hasattr`, `setattr`, `delattr`, and `isinstance` in builtin symbol sets
- [x] Robust Typing & Subscript Protocol: make `__luthon_get` gracefully tolerate subscripting non-table objects such as runtime generic types (`Union[...]`, `tuple[...]`)
- [x] Showcase Verification & Package Precompilation: retranspile site-packages and verify all showcase examples in `examples/` and `tests/test_examples.py` pass cleanly under LuaJIT

## Phase 26 — High-Throughput Asset & Serialization Performance

Maximize runtime throughput on asset, data-transformation, and I/O heavy workloads.

- [x] Fast Filesystem & Traversal FFI: POSIX FFI `stat`, `opendir`, `readdir`, and `mkdir` bindings accelerating `os.walk`, `os.listdir`, `os.path.exists`, and `os.makedirs`
- [x] High-Resolution POSIX Timers: direct `clock_gettime(CLOCK_MONOTONIC)` FFI bindings for `time.perf_counter` and `time.time`
- [x] Fast Memory Buffers & Slicing: `bytearray` and `bytes` implementations backed by contiguous FFI `uint8_t` memory buffers with direct SIMD swizzling
- [x] PyBridge NYI Telemetry & Fallback Reporter: automatic `<script>.luthon-nyi` report generation tracking all fallback modules, attributes, and protocol accesses

## Phase 27 — Deep C-API Emulation, Native Codecs & Zero-Bridge Pipelines

Eliminate PyBridge fallback overhead for heavy binary extensions (PIL/Pillow, NumPy) by bridging binary reflection with runtime module resolution and type protocol trampolines.

- [x] Automatic Binary Reflector Hook in Module Waterfall: intercept `.so`/`.pyd` imports in `modules.lua` (Tier 4.5) to automatically reflect and load native C-extensions via `capi_proxy` before falling back to `libpython3`
- [x] PyTypeObject & Object Protocol Emulation in `capi_proxy.c`: implement `tp_getattro`, `tp_call`, `tp_as_mapping` (subscripts, 3D slice tuples), `tp_as_number`, and `tp_descr_get` so native C-types (e.g. `ndarray`, `ImagingCore`) can be manipulated without CPython
- [x] Native Stream & Buffer Interoperability: implement Python C-stream protocol (`read`, `seek`, `tell`) and PEP 3118 buffer protocol directly inside `capi_proxy` for zero-copy `io.BytesIO` passing to C codecs
- [x] Direct Image Codec FFI Shims: standalone pure FFI bindings for `libpng`, `libjpeg-turbo`, and uncompressed pixel buffer manipulations (MER / channel packing) bypassing Pillow entirely

## Phase 28 — Modular C Native Library Architecture & Core Runtime Expansion

Restructure and mature Luthon's native C library (`src/luthon/native/`) from a single proxy file into a clean, modular multi-file architecture designed for ongoing growth and comprehensive CPython ABI emulation.

- [x] Multi-File Modular C Architecture: decompose `capi_proxy.c` into domain-specific translation units under `src/luthon/native/` (`core/object.c`, `core/types.c`, `protocols/mapping.c`, `protocols/sequence.c`, `protocols/buffer.c`, `io/stream.c`, `modules/loader.c`, `include/luthon_capi.h`)
- [x] Unified CMake/Ninja & Fast C Build System: introduce modular build configuration in `build_capi.py` supporting incremental compilation, static/shared outputs (`libluthon_capi.so` / `.a`), and multi-platform compilation flags (-O3, LTO, -fvisibility=hidden)
- [x] Comprehensive Type Metaclass & Slot Dispatch: implement complete `PyType_Ready`, `tp_richcompare`, `tp_iter`/`tp_iternext`, and dynamic heap-type allocation (`PyType_FromSpec`) across decomposed subsystems
- [x] Native Extension Unit Test Harness & Header Verification: add C-level unit tests and ABI header compliance tests verifying third-party binary compatibility against standard CPython ABI headers

## How to update

This file lives in the repo. When a step is completed, check its box and commit:

```bash
git add ROADMAP.md
git commit -m "docs(roadmap): mark <step> complete"
git push
```

The agent reads this file at the start of work and updates checked boxes as phases progress.

# Luthon Future Engineering Roadmap

This roadmap defines the upcoming architectural milestones and performance initiatives for Luthon, synthesized from the in-depth compiler, native C-API, and LuaJIT execution deep research audit.

Progress is tracked with GitHub task lists. Check boxes as work is completed.

---

## Roadmap Overview

| Milestone | Subsystem | Focus Area | Status | Target |
|:---|:---|:---|:---:|:---:|
| **Phase 29** | Optimization & Codegen | Register Allocation & Local Variable Slot Reuse | [x] | 4/4 |
| **Phase 30** | Codegen & Runtime | Direct Subscript & Comparison Specialization | [x] | 4/4 |
| **Phase 31** | Classical SSA Optimizer | Loop-Invariant Code Motion (LICM) & CSE | [x] | 4/4 |
| **Phase 32** | Native C-API Proxy | Full Slot Dispatch (`tp_iternext`, `tp_richcompare`, `tp_hash`) | [x] | 4/4 |
| **Phase 33** | C-API & Buffer Protocol | Multi-Dimensional Buffer Protocol (PEP 3118) & GC Lifetime Sync | [x] | 4/4 |
| **Phase 34** | High-Level IR (CIR) | Parametric Container Type Propagation (`List[T]`, `Tuple[T]`) | [x] | 4/4 |
| **Phase 35** | Runtime Event Loop | Multi-Task Asynchronous Event Loop (`asyncio.gather`, `create_task`) | [x] | 4/4 |
| **Phase 36** | Language Parity | Modern Python Parity (`ast.Match`, Dict Unpacking `**kwargs`) | [x] | 4/4 |
| **Phase 37** | Native Reflection Automation | DWARF Debuginfo Inspection & Autonomous C Header Extraction | [x] | 3/3 |
| **Phase 38** | Runtime Concurrency | True Multi-Threading & GIL-Free OS Thread Pools | [x] | 4/4 |
| **Phase 39** | Compiler & SIMD | SIMD & Vectorization Lowering in CIR (AVX2 / NEON) | [x] | 4/4 |
| **Phase 40** | Native C-API Proxy | Extended Ecosystem Coverage (PyTorch, OpenCV, SciPy) | [ ] | 0/4 |
| **Phase 41** | Cross-Platform Codegen | WebAssembly & WASI Compilation Target | [ ] | 0/4 |

---

## Phase 29 — Register Allocation & Local Variable Slot Reuse (LuaJIT 200-Local Limit Eliminator)
*Target: Eliminate the fallback to global variables when functions exceed 150 variables by implementing live-range register allocation.*

- [x] **Liveness Analysis Pass**: Implement backward live-variable analysis in `src/luthon/optimizer.py` computing `live_in` and `live_out` bitsets for every basic block and instruction.
- [x] **Chaitin-Briggs Graph Coloring / Linear Scan Allocator**: Map temporary variables (`_t1`, `_t2`, etc.) with disjoint live ranges to a shared pool of physical Lua local register slots.
- [x] **Codegen Local Guarantee**: Update `src/luthon/codegen.py` to declare physical register slots as locals, ensuring large non-trivial functions (1,000+ IR instructions) fit well below LuaJIT's 200-local variable ceiling.
- [x] **Performance Verification**: Measure bytecode generation and trace compilation on complex functions to verify 0 global variable fallback occurrences.

---

## Phase 30 — Direct Subscript & Comparison Specialization (Trace-Friendly Hot Paths)
*Target: Eliminate runtime dispatch overhead and trace aborts in hot numerical and algorithmic loops.*

- [x] **Direct Indexing Specialization**:
  - In `src/luthon/codegen.py`, identify subscript operations where indices are statically proven to be non-negative integers (`0 <= i < len`).
  - Emit direct 1-based table index access `t[i + 1]` instead of dynamic dispatch via `__luthon_get`.
- [x] **Relational Comparison Specialization**:
  - Detect comparisons between operands of known numeric types (`int`, `float`) in `cir.py` and `optimizer.py`.
  - Emit native Lua `<` / `>` / `==` / `~=` operators directly instead of calling `_luthon_cmp` and traversing metatables.
- [x] **Zero-Copy Slice Views**:
  - Replace full-table element copies in `a[start:stop]` for typed arrays with lightweight slice views or native C `memcpy`.
- [x] **Trace Abort Verification**: Run `luajit -jp=v` and `luajit -jp=a` across benchmark suites to verify 0 trace aborts in inner loops.

---

## Phase 31 — Classical SSA Optimizer Passes (LICM, CSE, and Strength Reduction)
*Target: Expand Luthon's intermediate representation optimizer with production-grade compiler passes.*

- [x] **Loop-Invariant Code Motion (LICM)**:
  - Detect loop nests and natural loops in control flow graph (`Function.blocks`).
  - Hoist constant computations, invariant global loads, and invariant attribute fetches (e.g. `math.sqrt`, `len(t)`) into loop pre-headers.
- [x] **Common Subexpression Elimination (CSE)**:
  - Implement local and dominator-tree global value numbering (GVN) to identify and eliminate duplicate subexpressions within and across basic blocks.
- [x] **Algebraic Simplification & Strength Reduction**:
  - Rewrite integer power operations (`x ** 2`, `x ** 3`) into direct multiplications (`x * x`, `x * x * x`).
  - Simplify identity operations (`x + 0`, `x * 1`, `x & -1`, `x or False`).
- [x] **Dead Store Elimination (DSE)**: Remove redundant variable stores whose values are never subsequently read before reassignment.

---

## Phase 32 — Native C-API Proxy Full Slot Dispatch (`tp_iternext`, `tp_richcompare`, `tp_hash`)
*Target: Enable binary C-extension packages (.so/.pyd) with custom class iterators, rich comparisons, and hashing to run unmodified.*

- [x] **Iterator Slot Emulation**:
  - In `src/luthon/native/core/object.c`, update `PyIter_Next` and `PyObject_GetIter` to check `obj->ob_type->tp_iternext` and `obj->ob_type->tp_iter`.
  - Invoke custom iterator callbacks when present on custom extension classes.
- [x] **Rich Comparison Protocol**:
  - Expand `PyObject_RichCompare` in `core/object.c` to dispatch to `tp_richcompare` on left and right operand types for custom C-extension classes.
- [x] **Hash Protocol**:
  - Implement full `PyObject_Hash` calling `tp_hash` on custom types, with support for standard Python string and integer hash algorithms.
- [x] **Descriptor / Property Protocol**:
  - Implement `tp_descr_get` and `tp_descr_set` in `core/types.c` to support `@property` and custom C-extension attribute descriptors.

---

## Phase 33 — Multi-Dimensional Buffer Protocol (PEP 3118) & GC Lifetime Sync
*Target: Full zero-copy multi-dimensional array exchange between LuaJIT and native C libraries (NumPy, SciPy, OpenCV).*

- [x] **ND Buffer Protocol Support**:
  - In `src/luthon/native/protocols/buffer.c`, implement full `PyBUF_ND` and `PyBUF_STRIDES` shape/stride buffer export for multi-dimensional arrays.
  - Implement format string parsing (`f`, `d`, `i`, `b`, etc.) for typed memory exports.
- [x] **Dual-Ownership GC Synchronization**:
  - Build a centralized pointer registry linking LuaJIT FFI `cdata` wrappers to CPython reference counts via `ffi.gc(ptr, Py_DecRef)`.
  - Distinguish between borrowed and owned references to prevent double frees or premature reclamation.
- [x] **Buffer Writeback & Locking**: Add memory read-only flags and buffer lock counts to prevent array reallocation while external C libraries hold buffer pointers.

---

## Phase 34 — Parametric Container Type Propagation in CIR (`cir.py`)
*Target: Prevent type degradation to dynamic objects by propagating container inner types.*

- [x] **Parametric Type System**:
  - Extend `Type` in `src/luthon/cir.py` with parametric definitions: `ListType(item_type)`, `DictType(key_type, value_type)`, `TupleType(item_types)`.
- [x] **Container Operation Type Inference**:
  - Infer return types of indexing operations (`list[int]` subscript -> `int`).
  - Track append and extend operations to update container element types.
- [x] **Signature Type Seeding**:
  - Parse Python type annotations (`def compute(vals: list[float]) -> float:`) in `semantic.py` to seed CIR argument types directly.
- [x] **Unboxed Loop Generation**: Emit type-specialized unboxed loops when container elements are proven homogeneous.

---

## Phase 35 — Multi-Task Asynchronous Event Loop (`asyncio.gather`, `create_task`)
*Target: Provide real cooperative multi-task concurrency in pure LuaJIT without requiring CPython.*

- [x] **Task Scheduler & Microtask Queue**:
  - Implement a cooperative round-robin task scheduler in `src/luthon/stdlib.py`.
  - Support `asyncio.create_task(coro)` returning a schedulable `Task` object.
- [x] **`asyncio.gather(*tasks)` Implementation**:
  - Support awaiting multiple concurrent coroutines/tasks and collecting results in order.
- [x] **Non-Blocking Timer & I/O Multiplexing**:
  - Integrate `epoll` / `poll` via LuaJIT FFI into the Lua event loop for non-blocking network socket waiting in `websockets.lua` and `requests.lua`.

---

## Phase 36 — Modern Python Syntax Parity (`ast.Match` & Dict Unpacking)
*Target: Complete syntax parity for Python 3.10+ language constructs.*

- [x] **Structural Pattern Matching (`ast.Match`)**:
  - Lower `ast.Match`, `ast.MatchValue`, `ast.MatchSingleton`, `ast.MatchSequence`, and `ast.MatchMapping` in `src/luthon/ir.py` into decision trees with branch tests.
- [x] **Dictionary & Sequence Unpacking in Expressions**:
  - Support `{**d1, **d2, "key": val}` in `ir.py` lowering via chained `_dict_update`.
  - Support `[*seq1, *seq2]` unpacking in list and tuple literals.
- [x] **Keyword Argument Splatting (`**kwargs`)**:
  - Expand call-site lowering in `ir.py` to seamlessly merge dictionary splats with explicit keyword arguments.

---

## Phase 37 — Autonomous C Header & DWARF Reflection (`reflect.py`)
*Target: Automatically extract method signatures, struct layouts, and ABI definitions directly from binary .so files without manual header definitions.*

- [x] **DWARF Debuginfo Extractor**:
  - Enhance `src/luthon/reflect.py` with DWARF inspection to extract argument and return types for `PyMethodDef` function pointers.
- [x] **Automated FFI CDEF Generation**:
  - Generate full LuaJIT `ffi.cdef` type declarations automatically for compiled extensions during `luthon reflect <binary.so>`.
- [x] **End-to-End Binary Loading Test**: Verify standalone binary loading of compiled scientific C extensions with zero manual C code.

---

## Phase 38 — True Multi-Threading & GIL-Free OS Thread Pools (pthreads & Shared Memory Workers)
*Target: Deliver true multi-core parallel computing for Python workloads without CPython's Global Interpreter Lock (GIL) via native OS thread pools and shared-memory communication.*

- [x] **Native POSIX Thread Pool & Worker Runtime Primitives**:
  - In `src/luthon/native/core/thread.c`, implement a lightweight POSIX `pthread` worker pool exposing C ABI bindings (`luthon_threadpool_create`, `luthon_threadpool_submit`, `luthon_threadpool_wait`, `luthon_threadpool_destroy`).
  - Initialize an independent, isolated `lua_State*` runtime instance per worker thread, eliminating GIL contention while sharing read-only global constant state and immutable bytecode.
- [x] **Lock-Free SPSC/MPMC Ring Buffers & Zero-Copy Memory Sharing**:
  - Implement lock-free circular queues in `src/luthon/native/core/channel.c` using atomic compare-and-swap primitives (`__atomic_compare_exchange_n`) for sub-microsecond task dispatch and result collection.
  - Enable zero-copy exchange of unboxed typed memory buffers (`array('d')`, raw C pointers, PEP 3118 contiguous buffers) across worker threads without data copying or serialization.
- [x] **Python Concurrency Lowering (`concurrent.futures` & `threading`)**:
  - Lower `concurrent.futures.ThreadPoolExecutor(max_workers=N)` and `executor.map` / `submit` in `src/luthon/stdlib.py` and `src/luthon/ir.py` to dispatch directly to the native pthread pool.
  - Implement thread-safe synchronization primitives in pure LuaJIT FFI: `threading.Lock`, `threading.RLock`, `threading.Event`, and `threading.Semaphore` backed by native `pthread_mutex_t` and `pthread_cond_t`.
- [x] **GIL-Free Multi-Core Verification & Scaling Benchmarks**:
  - Add test suite in `tests/test_phase38_threading.py` verifying parallel task dispatch, return value harvesting, exception propagation, and mutex synchronization.
  - Implement multi-core scaling benchmarks (parallel Monte Carlo simulation and parallel Mandelbrot rendering) demonstrating near-linear speedup across 4+ physical CPU cores.

---

## Phase 39 — SIMD & Vectorization Lowering in CIR (AVX2 / NEON Auto-Vectorization)
*Target: Transform countable array loops in High-Level Intermediate Representation (CIR) into unrolled SIMD vector operations targeting AVX2 and ARM NEON.*

- [x] **Affine Loop Dependency & Vectorizability Analysis**:
  - In `src/luthon/cir.py`, implement an affine loop dependency pass analyzing natural loop nests identified by dominator tree analysis in `optimizer.py`.
  - Detect countable affine loops with unit stride (`i += 1`) iterating over homogeneous numeric arrays (`array('f')`, `array('d')`, typed `list[float]`, `list[int]`).
  - Check distance vectors and memory aliasing to prove the absence of loop-carried dependencies (no RAW/WAR/WAW hazards across iterations) to certify loops for vectorization.
- [x] **CIR Vector Instruction Set & Loop Strip-Mining**:
  - Introduce typed vector IR instructions in `src/luthon/cir.py`: `VEC_LOAD`, `VEC_STORE`, `VEC_ADD`, `VEC_SUB`, `VEC_MUL`, `VEC_FMA`, `VEC_BROADCAST`, and `VEC_REDUCE_SUM`.
  - Implement strip-mining pass decomposing candidate loops into alignment peeling pre-headers, SIMD kernel bodies of width W (W=4 for double on AVX2, W=8 for float; W=2/4 on ARM NEON), and scalar remainder cleanup blocks.
- [x] **Backend Vector Lowering (LuaJIT FFI & Native AVX2/NEON Intrinsics)**:
  - In `src/luthon/codegen.py`, lower CIR vector operations into native C vector kernels in `src/luthon/native/core/simd.c` compiled with architecture flags (`-mavx2 -mfma` on x86_64, `-mfpu=neon` on aarch64).
  - Provide fast fallback lowering to 128-bit unrolled LuaJIT FFI vector struct operations for platforms lacking AVX2 hardware.
  - Implement vectorized transcendental approximations (vectorized `sin`, `cos`, `exp`, `sqrt`) utilizing SIMD FMA instructions.
- [x] **Vectorization Diagnostics & Numerical Benchmarking**:
  - Add CLI diagnostic flag `--dump-vectorization` displaying auto-vectorized loop nests, vector widths, unroll factors, and reasons for rejected loops.
  - Add benchmark suite in `tests/test_phase39_simd.py` demonstrating 3x-6x throughput speedup on vector math kernels (SAXPY/DAXPY, dot product, Euclidean distance, polynomial evaluation).

---

## Phase 40 — Extended Ecosystem C-API Coverage (PyTorch, OpenCV & SciPy Interop)
*Target: Enable binary reflection and execution of heavy scientific Python C/C++ extensions without CPython by completing dynamic heap type allocation, extended slot protocols, and multi-phase initialization.*

- [ ] **Dynamic Heap Type Creation & Type Spec Protocol (`PyType_FromSpec`)**:
  - In `src/luthon/native/core/types.c`, implement `PyType_FromSpec` and `PyType_FromSpecWithBases` parsing `PyType_Slot` arrays to dynamically construct heap types.
  - Support dynamic base inheritance, heap-type flags (`Py_TPFLAGS_HEAPTYPE`, `Py_TPFLAGS_BASETYPE`), and descriptor registration for dynamic classes emitted by C++ bindings (pybind11 and nanobind in PyTorch/OpenCV).
- [ ] **PEP 489 Multi-Phase Module Initialization & Capsule Table Sharing**:
  - Expand `src/luthon/native/modules/loader.c` and `src/luthon/reflect.py` to support PEP 489 multi-phase loading via `PyModuleDef_Init`, `Py_mod_create`, and `Py_mod_exec`.
  - Implement dynamic `PyCapsule_Import` symbol tables enabling cross-module C-API sharing (such as SciPy Cython BLAS/LAPACK capsules and PyTorch C++ dispatcher tables).
- [ ] **Extended Slot & Metamethod Coverage**:
  - Implement missing numeric and mapping slots in `protocols/number.c` and `protocols/mapping.c`: `nb_matrix_multiply` (`@`), `nb_inplace_matrix_multiply`, `nb_power`, `nb_inplace_power`, and `mp_ass_subscript` for multi-dimensional slice assignments.
  - Implement asynchronous and protocol slots: `tp_as_async` (`am_await`, `am_aiter`, `am_anext`) and `tp_finalize` for native C++ object cleanup.
- [ ] **Ecosystem Integration Test Harness & ABI Verification**:
  - Create synthetic test modules in `tests/test_phase40_ecosystem_capi.py` exercising heap-type specs, multi-phase loading, and capsule function exports without full CPython dependencies.
  - Validate end-to-end binary loading and execution of precompiled SciPy linalg and OpenCV image processing C-extensions.

---

## Phase 41 — WebAssembly & WASI Compilation Target (WASM Browser & Edge Runtimes)
*Target: Compile and execute Luthon-transpiled Python applications in WebAssembly environments, supporting both standalone WASI runtimes and web browsers.*

- [ ] **WASI Preview 1 Syscall Emulation & Platform Abstraction Layer**:
  - In `src/luthon/native/platform/wasi.c`, implement POSIX syscall shims compatible with WASI Preview 1 (`fd_read`, `fd_write`, `fd_seek`, `clock_time_get`, `environ_sizes_get`, `environ_get`, `random_get`).
  - Update `src/luthon/native/build_capi.py` to support compilation via `clang --target=wasm32-wasi` and Emscripten with `-O3 -flto`.
- [ ] **Standalone WebAssembly Binary Bundle Emitter (`bundle.py`)**:
  - Extend `src/luthon/bundle.py` and CLI with `luthon build --target wasm` and `luthon build --target wasi`.
  - Package the Lua VM interpreter, precompiled Luthon stdlib prelude, and user application bytecode into a single self-contained `.wasm` binary (<2 MB).
- [ ] **Browser WebWorker & JS-Python Interoperability Bridge**:
  - Create browser runtime scaffolding (`src/luthon/lua/wasm_js.lua`) facilitating bi-directional data marshaling between JavaScript objects and Luthon types.
  - Wire WebAssembly linear memory (`SharedArrayBuffer` / `ArrayBuffer`) for zero-copy binary data exchange with WebGL, WebGPU, and Canvas APIs.
- [ ] **WASI Engine Validation & Headless Test Suite**:
  - Add automated tests in `tests/test_phase41_wasm.py` executing compiled `.wasm` targets using standard WASI runtimes (`wasmtime`, `wasmer`, `nodejs --experimental-wasi-unstable-preview1`).
  - Validate algorithmic, mathematical, and string formatting correctness in sandboxed WASI environments with zero host filesystem/environment leakage.

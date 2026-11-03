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

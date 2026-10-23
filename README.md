# Luthon

Luthon is a Python to LuaJIT transpiler with a real compiler backend. It parses
Python source, runs semantic analysis, lowers the program to an intermediate
representation with explicit control flow, and emits Lua that executes under
LuaJIT.

The goal is not to interpret Python. The goal is to take ordinary Python
programs, including functions, closures, classes, comprehensions and a large
part of the standard library, and produce Lua code that runs fast.

## Why

LuaJIT has a very fast JIT compiler and a small runtime. Python is expressive and
has a large ecosystem. Luthon connects the two for the subset of Python where a
static translation to Lua is sound: numeric loops, recursive algorithms,
data-structure heavy code and object-oriented models.

Programs that exercise this subset run several times faster than CPython while
keeping the same source.

## Installation

```bash
pip install -e .
```

Requirements:

- Python 3.9 or newer (CPython, because the frontend uses the `ast` module)
- LuaJIT 2.1 or newer (the generated code uses `goto` and `::label::`)

## Usage

Transpile a file:

```bash
luthon transpile examples/fib.py -o fib.lua
luajit fib.lua
```

Use the IR backend explicitly:

```bash
luthon transpile examples/fib.py --ir -o fib.lua
```

Run the semantic analyzer and print a summary of the module scope:

```bash
luthon analyze examples/fib.py
```

Use the package as a module:

```bash
python -m luthon transpile examples/fib.py -o fib.lua
```

### Options

| Flag | Meaning |
| --- | --- |
| `-o`, `--output` | Output Lua file. Defaults to standard output. |
| `--ir` | Compile through semantic analysis, IR and IR codegen instead of the direct AST transpiler. |
| `--no-cache` | Bypass the compilation cache for this invocation. |
| `--cache-dir` | Directory used for cached output. Defaults to `.luthon_cache`. |

## Architecture

Luthon has two pipelines. Both share the semantic frontend and the same Lua
runtime prelude.

Direct transpiler:

```
source -> ast.parse -> Transpiler (AST visitor) -> Lua
```

IR backend, selected with `--ir` or `transpile_ir`:

```
source
  -> ast.parse
  -> SemanticAnalyzer        scopes, symbol tables, free and cell variables
  -> IRLowerer               instructions grouped into basic blocks
  -> codegen                 labels, gotos, locals, closures
  -> Lua + stdlib prelude + entry call
```

| Module | Responsibility |
| --- | --- |
| `src/luthon/semantic.py` | Scoped symbol tables, name resolution, upvalue and closure analysis, `__future__` features. |
| `src/luthon/ir.py` | Instruction level lowering. Conditionals and loops become branch and jump instructions over labelled blocks. |
| `src/luthon/codegen.py` | Translates IR to Lua. Emits `goto` and `::label::` for control flow, declares locals, builds classes and dataclass metamethods. |
| `src/luthon/stdlib.py` | Lua prelude implementing the Python standard library subset. |
| `src/luthon/transpiler.py` | Direct AST visitor, plus the `transpile_ir` entry point. |
| `src/luthon/cache.py` | Persistent compilation cache. |
| `src/luthon/modules.py` | Module resolution and execution for `import`. |
| `src/luthon/sourcemap.py` | Source map container with VLQ encoding. |
| `src/luthon/cli.py` | Command line interface. |

### Closures and upvalues

The semantic pass resolves every name to a binding and classifies it as local,
parameter, freed (captured from an enclosing function) or cell (a local captured
by a nested function). The IR emits cell boxing instructions for captured
variables, reads and writes go through the box, and codegen propagates upvalue
names to the enclosing function so Lua captures them as real upvalues.

### Indexing

Python sequences are zero based and Lua tables are one based. Luthon does not
shift entire tables at compile time. Instead, subscript operations apply a
runtime offset only when the index is a number, so string keys used by
dictionaries and the standard library objects keep their natural meaning.

## Language coverage

Implemented in the IR backend:

- Assignments, augmented assignments and tuple unpacking
- `if`, `elif`, `else`, `while`, `for` over iterables, `break`
- Functions, nested functions, closures, lambdas
- Classes with methods and attributes, constructors, instance metatables
- Dataclasses, including generated `__init__`, `__repr__` and `__eq__`
- List, tuple and dict literals, list comprehensions
- Subscripts and slices, attribute access
- Calls with positional arguments and keyword arguments
- `import` and `from ... import ...`, plus `from __future__ import ...`
- Function decorators

Not implemented yet:

- `try`, `except`, `finally`, `with`, `raise`, `assert`
- `async` and `await`, generators and `yield`
- Set, dict and generator comprehensions
- f-strings, boolean `and` and `or` expressions, chained comparisons
- Multiple inheritance and metaclasses

Unsupported statements lower to no-ops rather than failing the whole compile, so
a program using them silently loses that behaviour. Treat the list above as the
current contract.

## Standard library

The Lua prelude provides these modules:

| Module | Coverage |
| --- | --- |
| `math` | Constants and the usual numeric functions, with `math.pow` mapped to the Lua exponent operator |
| `os` | `getenv`, `remove`, `rmdir`, `makedirs`, `listdir`, `exit`, `clock`, `date`, `time`, `difftime`, `execute` |
| `os.path` | `join`, `exists`, `isfile`, `isdir` |
| `sys` | `argv`, `path`, `version`, `platform`, `exit`, standard streams |
| `json` | `dumps`, `encode`, `loads`, `decode` with objects, arrays, strings, numbers, booleans, null and `\uXXXX` escapes |
| `re` | `match`, `search`, `sub`, `findall` mapped to Lua patterns |
| `collections` | `deque`, `defaultdict`, `Counter`, `OrderedDict` |
| `itertools` | `chain`, `product`, `permutations`, `combinations` |
| `functools` | `reduce`, `partial`, `lru_cache` |
| `pathlib` | `Path` with `name`, `parent`, `exists`, `is_file`, `is_dir`, `join`, `read_text`, `write_text`, `cwd`, `home` |
| `random` | `seed`, `random`, `randint`, `choice`, `shuffle`, `uniform`, `randrange`, `sample` |
| `datetime` | `date`, `time`, `datetime`, `timedelta` |
| `string` | Character class constants |
| `base64` | `b64encode`, `b64decode` |
| `io` | `StringIO` |
| `struct` | Minimal `pack` and `unpack` for big-endian 32-bit integers |
| `hashlib` | `md5`, `sha1`, `sha256`, `sha512` |
| `typing` | Runtime placeholders, type hints are erased |
| `site` | `getsitepackages`, `getusersitepackages`, `addsitedir` |
| `tempfile` | `gettempdir`, `mkdtemp`, `mkstemp`, `NamedTemporaryFile`, `TemporaryFile` |
| `dataclasses` | `dataclass` support and the `field` helper |
| `subprocess` | `run`, `call`, `check_output`, `Popen` |

Builtins include `range`, `len`, `list`, `tuple`, `set`, `iter`, `str`, `int`,
`float`, `bool`, `abs`, `round`, `min`, `max`, `sum`, `sorted`, `reversed`,
`enumerate`, `zip`, `map`, `filter`, `any`, `all` and `open`.

The `hashlib` implementations are simplified, non-cryptographic digests used to
give compiled programs a consistent API. They must not be used for security
purposes or expected to match CPython output byte for byte. `struct` only
supports the big-endian integer format shown above. `re` translates to Lua
patterns, which are not a full regular expression engine.

## Compilation cache

Compiling a file twice without changing it is wasteful. Luthon keeps a
persistent cache under `.luthon_cache`, keyed by a hash of the input path so
lookups are a single directory read.

Each entry stores the generated Lua next to a metadata file containing the
LuaJIT version used, the file modification time, its size, a content hash and
the hashes of any imported modules.

The lookup is two tiered:

1. Compare modification time and size from `stat`. This is the fast path and
   costs almost nothing.
2. If the stat data differs, hash the file contents. A tag that only touched the
   modification time still hits the cache because the content is unchanged.

Writes go through temporary files and `os.replace`, so an interrupted compile
cannot leave a partially written entry behind. A cache entry written by a
different Luthon version is ignored.

## Benchmarks

Numbers measured on a single ARM device with CPython 3.14 and LuaJIT, wall clock
including interpreter startup. Output was verified to match between the two
runtimes for every case.

| Benchmark | Workload | CPython | LuaJIT | Speedup |
| --- | --- | --- | --- | --- |
| Fibonacci | `fib(36)`, naive recursion | 5.26 s | 0.40 s | about 13x |
| Mandelbrot | 500x500 grid, 50 iterations | 3.26 s | 0.17 s | about 19x |
| Binary trees | depth 18, 262143 nodes | 1.00 s | 0.38 s | about 2.7x |
| N-body | small two body step | 0.07 s | 0.02 s | startup dominated |

The workloads live under `bench/`. They are excluded from version control and
are not part of the test suite.

## Tests

```bash
pytest
```

The suite covers the semantic analyzer, closure analysis, `__future__` handling,
the transpiler, the IR pipeline and the compilation cache.

## Limitations

- Luthon is a transpiler, not an interpreter. It does not embed CPython and
  cannot run packages that rely on C extension modules such as NumPy or pandas.
  Pure Python packages can be resolved through `ModuleLoader`, which searches
  `site-packages` and `PYTHONPATH` and understands `__init__.py`.
- Luthon cannot compile itself. Its frontend depends on CPython modules that
  have no Lua equivalent, most importantly `ast`.
- Generated code requires LuaJIT. Plain Lua 5.1 lacks `goto`.
- Semantic differences such as integer division, string formatting and error
  handling are only as close as the prelude implements them.

## Development

```bash
pip install -e ".[dev]"
pytest
```

Layout:

```
src/luthon/    compiler, IR, codegen, stdlib prelude, cache, modules
tests/         unit tests
bench/         benchmark programs, not tracked by git
```

## License

MIT

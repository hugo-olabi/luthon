---
name: never-modify-transpiled
description: Never modify transpiled or generated files directly. Always fix issues and bugs by modifying Luthon compiler source code and re-transpiling.
---

# Never Modify Transpiled Files

Transpiled and generated files (such as `.lua` files produced from Python source, cache files, or precompiled modules in site-packages) must NEVER be modified by hand.

## Rules
1. Never edit generated or transpiled code directly.
2. When an error or unexpected behavior appears in transpiled output, always treat it as a defect in Luthon's compiler pipeline (frontend, semantic analyzer, IR lowerer, optimizer, or codegen).
3. Diagnose and fix the root cause by modifying Luthon's source code:
   - Python pipeline: `src/luthon/*.py`
   - Pure-Lua bootstrap pipeline: `src/luthon/lua/*.lua`
   - Stdlib runtime prelude: `src/luthon/stdlib.py` and `src/luthon/lua/bootstrap.lua`
4. Re-transpile, re-compile, or re-install to verify the fix in the newly generated code.

---
name: native-capi-priority
description: Prioritize C-API proxy and binary reflection FFI for native extensions over custom Lua library implementations, unless explicitly requested.
---

# Native C-API Proxy & Binary Reflection Priority Rule

When resolving, optimizing, or executing Python packages that rely on native C extensions (such as Pillow, NumPy, SciPy, etc.), strictly prioritize using and enhancing Luthon's C-API proxy (`src/luthon/native/`) and binary reflection FFI loader over writing custom Lua replacement libraries.

## Core Directives

1. **Prioritize Native ABI Emulation**:
   - The primary goal of Luthon is running unmodified Python code and ecosystem C extensions natively under LuaJIT without requiring custom-coded Lua ports for each package.
   - Expand `libluthon_capi.so` (`src/luthon/native/`) with missing CPython ABI functions, type slots, macros, and protocols so third-party binary `.so` extensions link and run directly.

2. **Binary Reflection First**:
   - Use `BinaryReflector` (`src/luthon/reflect.py`) and Tier 4.5 automatic binary resolution in `modules.lua` to inspect and trampoline C-extension entry points (`PyInit_*`) and method tables into LuaJIT FFI.
   - Do NOT create bespoke reimplementations in Lua (e.g. `pil.lua`, `numpy.lua`, `cv2.lua`) unless the user explicitly requests a custom Lua library.

3. **Eliminate PyBridge via C-API Coverage**:
   - When items appear in `.luthon-nyi` telemetry, analyze which C-API symbols, slots (`tp_call`, `tp_getattro`, `tp_as_mapping`), or protocol structures are missing in `libluthon_capi.so`.
   - Add those symbols and protocols directly into the appropriate translation unit under `src/luthon/native/` (`core/`, `protocols/`, `io/`, `modules/`) so the original binary extensions can be executed by Luthon directly.

"""Phase 23: Standalone Executable Packaging & Amalgamation Builder."""

from __future__ import annotations
import os
import subprocess
from pathlib import Path
from typing import Optional
from .cli import compile_file


class StandaloneBundler:
    """Packages a transpiled Python program and its Luthon runtime prelude into a self-contained executable bundle."""

    def __init__(self, optimize: bool = True):
        self.optimize = optimize

    def build_bundle(self, input_py_path: Path, output_exe_path: Path) -> Path:
        """Transpiles input Python source and writes an executable bundle."""
        lua_code, _ = compile_file(
            input_path=input_py_path,
            use_ir=True,
            optimize=self.optimize,
            no_cache=True
        )

        # Generate self-executing standalone amalgamation
        shebang = "#!/bin/sh\n"
        launcher = 'exec luajit - "$@" << \'__LUTHON_BUNDLE_EOF__\'\n'
        closing = "\n__LUTHON_BUNDLE_EOF__\n"

        bundle_content = shebang + launcher + lua_code + closing

        output_exe_path.write_text(bundle_content)
        # Make executable
        output_exe_path.chmod(output_exe_path.stat().st_mode | 0o755)

        return output_exe_path

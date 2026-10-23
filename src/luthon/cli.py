"""Command-line interface for Luthon."""

import argparse
import sys
from pathlib import Path

from .transpiler import transpile
from .cache import CompilationCache
from .semantic import analyze


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="luthon", description="Python -> LuaJIT transpiler")
    sub = parser.add_subparsers(dest="command")

    t = sub.add_parser("transpile", help="Transpile a Python file to Lua")
    t.add_argument("input", help="Input .py file")
    t.add_argument("-o", "--output", help="Output .lua file (default stdout)")
    t.add_argument("--ir", action="store_true", help="Use IR pipeline instead of direct transpiler")
    t.add_argument("--no-cache", action="store_true", help="Disable compilation cache")
    t.add_argument("--cache-dir", default=None, help="Cache directory")

    a = sub.add_parser("analyze", help="Run semantic analysis on a Python file")
    a.add_argument("input", help="Input .py file")

    args = parser.parse_args(argv)
    if args.command == "analyze":
        src = Path(args.input).read_text()
        root = analyze(src)
        print(f"module scope: {len(root.locals)} symbols, {len(root.children)} child scopes")
        return 0
    if args.command == "transpile":
        inp = Path(args.input)
        src = inp.read_text()
        cache = None if args.no_cache else CompilationCache(args.cache_dir)
        deps = {}
        lua = None
        if cache is not None:
            lua = cache.lookup(str(inp), deps)
            if lua is not None:
                if args.output:
                    Path(args.output).write_text(lua)
                    print(f"Cached {args.output}")
                else:
                    sys.stdout.write(lua)
                return 0
        if args.ir:
            from .transpiler import transpile_ir
            lua = transpile_ir(src)
        else:
            lua = transpile(src)
        if cache is not None:
            cache.store(str(inp), lua, deps)
        if args.output:
            Path(args.output).write_text(lua)
            print(f"Wrote {args.output}")
        else:
            sys.stdout.write(lua)
        return 0
    # default: print help
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

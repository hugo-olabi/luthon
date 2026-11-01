"""Command-line interface for Luthon."""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from .transpiler import transpile
from .cache import CompilationCache
from .semantic import analyze


def compile_file(
    input_path: Path,
    use_ir: bool = True,
    optimize: bool = False,
    sourcemap: bool = False,
    no_cache: bool = False,
    cache_dir: str | None = None,
    output_path: Path | None = None,
) -> tuple[str, Path | None]:
    """Compiles a Python file to Lua using cache and specified pipeline."""
    src = input_path.read_text()
    cache = None if no_cache else CompilationCache(cache_dir)
    deps = {}
    lua = None
    if cache is not None:
        lua = cache.lookup(str(input_path), deps)
        if lua is not None:
            if output_path:
                output_path.write_text(lua)
            return lua, output_path

    if use_ir:
        from .transpiler import transpile_ir
        if sourcemap:
            import json
            lua, sm = transpile_ir(src, optimize=optimize, sourcemap=True, filename=str(input_path))
            sm_path = (output_path.with_suffix(".lua.map") if output_path else input_path.with_suffix(".lua.map"))
            sm_path.write_text(json.dumps(sm.to_dict(), indent=2))
        else:
            lua = transpile_ir(src, optimize=optimize, filename=str(input_path))
    else:
        lua = transpile(src)

    if cache is not None:
        cache.store(str(input_path), lua, deps)

    if output_path:
        output_path.write_text(lua)

    return lua, output_path


def run_file(
    input_path: Path,
    script_args: list[str] | None = None,
    use_ir: bool = True,
    optimize: bool = False,
    no_cache: bool = False,
    cache_dir: str | None = None,
    profile: bool = False,
    dump_traces: bool = False,
) -> int:
    """Compiles a Python file and executes it immediately under LuaJIT."""
    with tempfile.NamedTemporaryFile(suffix=".lua", delete=False) as tmp:
        tmp_lua_path = Path(tmp.name)

    try:
        compile_file(
            input_path=input_path,
            use_ir=use_ir,
            optimize=optimize,
            no_cache=no_cache,
            cache_dir=cache_dir,
            output_path=tmp_lua_path,
        )

        cmd = ["luajit"]
        if profile:
            cmd.extend(["-jp"])
        if dump_traces:
            cmd.extend(["-jdump"])
        cmd.append(str(tmp_lua_path))
        if script_args:
            cmd.extend(script_args)

        proc = subprocess.run(cmd)
        return proc.returncode
    finally:
        try:
            if tmp_lua_path.exists():
                tmp_lua_path.unlink()
        except OSError:
            pass


def main(argv: list[str] | None = None) -> int:
    raw_argv = sys.argv[1:] if argv is None else argv

    # Direct execution check: if first argument is a .py file or an existing file (not a known command or option flag)
    # e.g.: `luthon ./main.py` or `luthon script.py arg1 arg2`
    known_commands = {"transpile", "analyze", "run", "pip", "install", "venv", "build", "-h", "--help"}
    if raw_argv and raw_argv[0] not in known_commands and not raw_argv[0].startswith("-"):
        candidate = Path(raw_argv[0])
        if candidate.suffix == ".py" or candidate.is_file():
            return run_file(input_path=candidate, script_args=raw_argv[1:])

    parser = argparse.ArgumentParser(prog="luthon", description="Python -> LuaJIT transpiler & runner")
    sub = parser.add_subparsers(dest="command")

    # install command shorthand: `luthon install <package>`
    inst = sub.add_parser("install", help="Install a package from PyPI into Luthon site-packages")
    inst.add_argument("packages", nargs="+", help="Package(s) to install")
    inst.add_argument("--no-aot", action="store_true", help="Skip AOT pre-compilation to Lua")
    inst.add_argument("--no-deps", action="store_true", help="Do not install dependencies")
    inst.add_argument("--target", default=None, help="Target installation directory")

    # pip command: `luthon pip <install|uninstall|list|freeze>`
    p = sub.add_parser("pip", help="Luthon package manager")
    p_sub = p.add_subparsers(dest="pip_action")

    p_install = p_sub.add_parser("install", help="Install package(s)")
    p_install.add_argument("packages", nargs="*", help="Package(s) to install")
    p_install.add_argument("-r", "--requirement", help="Install from requirements.txt")
    p_install.add_argument("--no-aot", action="store_true", help="Skip AOT pre-compilation to Lua")
    p_install.add_argument("--no-deps", action="store_true", help="Do not install dependencies")
    p_install.add_argument("--target", default=None, help="Target installation directory")

    p_uninstall = p_sub.add_parser("uninstall", help="Uninstall package(s)")
    p_uninstall.add_argument("packages", nargs="+", help="Package(s) to uninstall")
    p_uninstall.add_argument("--target", default=None, help="Target installation directory")

    p_list = p_sub.add_parser("list", help="List installed packages")
    p_list.add_argument("--target", default=None, help="Target installation directory")

    p_freeze = p_sub.add_parser("freeze", help="Output installed packages in requirements format")
    p_freeze.add_argument("--target", default=None, help="Target installation directory")

    # venv command: `luthon venv <env_dir>`
    v = sub.add_parser("venv", help="Create a local isolated Luthon virtual environment")
    v.add_argument("env_dir", nargs="?", default=".luthon_env", help="Directory for the environment (default: .luthon_env)")

    # run command: `luthon run <file.py> [args...]`
    r = sub.add_parser("run", help="Compile and run a Python file under LuaJIT")
    r.add_argument("input", help="Input .py file")
    r.add_argument("args", nargs=argparse.REMAINDER, help="Arguments passed to the script")
    r.add_argument("--ir", action="store_true", default=True, help="Use IR pipeline (default: True)")
    r.add_argument("--no-ir", dest="ir", action="store_false", help="Use direct AST visitor pipeline")
    r.add_argument("--optimize", "-O", action="store_true", help="Run IR optimizations")
    r.add_argument("--profile", action="store_true", help="Run with LuaJIT JIT profiler enabled (-jp)")
    r.add_argument("--dump-traces", action="store_true", help="Dump JIT trace bytecode and IR (-jdump)")
    r.add_argument("--no-cache", action="store_true", help="Disable compilation cache")
    r.add_argument("--cache-dir", default=None, help="Cache directory")

    t = sub.add_parser("transpile", help="Transpile a Python file to Lua")
    t.add_argument("input", help="Input .py file")
    t.add_argument("-o", "--output", help="Output .lua file (default stdout)")
    t.add_argument("--ir", action="store_true", default=True, help="Use IR pipeline instead of direct transpiler")
    t.add_argument("--no-ir", dest="ir", action="store_false", help="Use direct AST visitor pipeline")
    t.add_argument("--optimize", "-O", action="store_true", help="Run IR optimizations (constant folding, DCE, copy propagation)")
    t.add_argument("--sourcemap", action="store_true", help="Generate VLQ source map")
    t.add_argument("--no-cache", action="store_true", help="Disable compilation cache")
    t.add_argument("--cache-dir", default=None, help="Cache directory")

    a = sub.add_parser("analyze", help="Run semantic analysis on a Python file")
    a.add_argument("input", help="Input .py file")

    # build command: `luthon build <file.py> -o <binary>`
    b = sub.add_parser("build", help="Build a standalone executable bundle from a Python file")
    b.add_argument("input", help="Input .py file")
    b.add_argument("-o", "--output", required=True, help="Output executable binary path")
    b.add_argument("--standalone", action="store_true", default=True, help="Package as self-contained standalone bundle")
    b.add_argument("--optimize", "-O", action="store_true", default=True, help="Run IR optimizations")

    args, extra = parser.parse_known_args(raw_argv)

    if args.command == "run":
        inp = Path(args.input)
        script_args = (args.args or []) + extra
        return run_file(
            input_path=inp,
            script_args=script_args,
            use_ir=args.ir,
            optimize=args.optimize,
            no_cache=args.no_cache,
            cache_dir=args.cache_dir,
            profile=args.profile,
            dump_traces=args.dump_traces,
        )

    if args.command == "venv":
        from .pip import create_venv
        create_venv(Path(args.env_dir))
        return 0

    if args.command in ("install", "pip"):
        from .pip import PipInstaller
        target = Path(args.target) if getattr(args, "target", None) else None
        installer = PipInstaller(target_dir=target)

        # Handling `luthon install <package>`
        if args.command == "install":
            for pkg in args.packages:
                installer.install(pkg, aot_compile=not args.no_aot, install_deps=not args.no_deps)
            return 0

        # Handling `luthon pip <action>`
        action = getattr(args, "pip_action", None)
        if action == "install":
            pkgs = list(args.packages or [])
            if args.requirement:
                req_path = Path(args.requirement)
                if req_path.is_file():
                    for line in req_path.read_text().splitlines():
                        line = line.strip()
                        if line and not line.startswith("#"):
                            pkgs.append(line)
            if not pkgs:
                print("[-] No packages specified to install.")
                return 1
            for pkg in pkgs:
                installer.install(pkg, aot_compile=not args.no_aot, install_deps=not args.no_deps)
            return 0

        elif action == "uninstall":
            for pkg in args.packages:
                installer.uninstall(pkg)
            return 0

        elif action == "list":
            installed = installer.list_installed()
            if not installed:
                print(f"No packages installed in {installer.target_dir}")
                return 0
            print(f"Package{' ' * 20}Version")
            print(f"{'-' * 27}{'-' * 15}")
            for name, ver in installed:
                print(f"{name:<27}{ver}")
            return 0

        elif action == "freeze":
            for name, ver in installer.list_installed():
                print(f"{name}=={ver}")
            return 0

        else:
            p.print_help()
            return 0

    if args.command == "build":
        from .bundle import StandaloneBundler
        bundler = StandaloneBundler(optimize=args.optimize)
        out_bin = bundler.build_bundle(Path(args.input), Path(args.output))
        print(f"Built standalone executable: {out_bin} ({out_bin.stat().st_size} bytes)")
        return 0

    if args.command == "analyze":
        src = Path(args.input).read_text()
        root = analyze(src)
        print(f"module scope: {len(root.locals)} symbols, {len(root.children)} child scopes")
        return 0

    if args.command == "transpile":
        inp = Path(args.input)
        out_path = Path(args.output) if args.output else None
        lua, _ = compile_file(
            input_path=inp,
            use_ir=args.ir,
            optimize=args.optimize,
            sourcemap=args.sourcemap,
            no_cache=args.no_cache,
            cache_dir=args.cache_dir,
            output_path=out_path,
        )
        if out_path:
            print(f"Wrote {args.output}")
        else:
            sys.stdout.write(lua)
        return 0

    # default: print help
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

def _op(op):
    return {"add": "+", "sub": "-", "mul": "*", "div": "/", "mod": "%", "pow": "^", "concat": ".."}.get(op, op)


def _emit(ins):
    o = ins.op
    if o == "CONST":
        v = ins.args[0]
        if v is True:
            return ins.result + " = true"
        if v is False:
            return ins.result + " = false"
        if v is None:
            return ins.result + " = nil"
        return ins.result + " = " + repr(v)
    if o == "LOAD":
        return ins.result + " = " + ins.args[0]
    if o == "STORE":
        return ins.args[0] + " = " + ins.args[1]
    if o == "BINOP":
        l = ins.args[1] if ins.args[1] is not None else "nil"
        r = ins.args[2] if ins.args[2] is not None else "nil"
        raw_op = (ins.args[0] or "").lower()
        # Clean typed magic method signatures (e.g. int.__typed_add__ -> add)
        if "__typed_" in raw_op:
            raw_op = raw_op.split("__typed_")[1].rstrip("_")
        if raw_op in ("floordiv", "//"):
            return ins.result + " = math.floor(" + l + " / " + r + ")"
        elif raw_op in ("band", "bitand", "&"):
            return ins.result + " = bit.band(" + l + ", " + r + ")"
        elif raw_op in ("bor", "bitor", "|"):
            return ins.result + " = bit.bor(" + l + ", " + r + ")"
        elif raw_op in ("bxor", "bitxor", "^"):
            return ins.result + " = bit.bxor(" + l + ", " + r + ")"
        elif raw_op in ("<<", "lshift"):
            return ins.result + " = bit.lshift(" + l + ", " + r + ")"
        elif raw_op in (">>", "rshift"):
            return ins.result + " = bit.rshift(" + l + ", " + r + ")"
        elif raw_op in ("matmul", "@"):
            return ins.result + " = " + l + ":matmul(" + r + ")"
        return ins.result + " = " + l + " " + _op(raw_op) + " " + r
    if o == "UNOP":
        if ins.args[0] == "neg":
            return ins.result + " = -" + ins.args[1]
        elif ins.args[0] in ("inv", "invert"):
            return ins.result + " = bit.bnot(" + ins.args[1] + ")"
        return ins.result + " = " + ins.args[1]
    if o == "RETURN":
        return "do return " + (ins.args[0] if ins.args and ins.args[0] else "") + " end"
    if o == "JUMP":
        return "goto " + ins.args[0]
    if o == "BRANCH":
        return "if " + ins.args[0] + " then goto " + ins.args[1] + " else goto " + ins.args[2] + " end"
    if o == "BRANCH_NONE":
        return "if " + ins.args[0] + " == nil then goto " + ins.args[1] + " end"
    if o == "CMP":
        cmp_op = (ins.args[0] or "")
        if cmp_op in ("in", "In"):
            return ins.result + " = _luthon_in(" + ins.args[1] + ", " + ins.args[2] + ")"
        elif cmp_op in ("notin", "NotIn", "not in"):
            return ins.result + " = _luthon_not_in(" + ins.args[1] + ", " + ins.args[2] + ")"
        mapped_op = cmp_op.replace("eq","==").replace("ne","~=").replace("lt","<").replace("le","<=").replace("gt",">").replace("ge",">=")
        return ins.result + " = (" + ins.args[1] + " " + mapped_op + " " + ins.args[2] + ")"
    if o == "CALL":
        args = ", ".join(str(a) for a in ins.args[1:])
        return ins.result + " = " + str(ins.args[0]) + "(" + args + ")"
    if o == "DO":
        return "do"
    if o == "END":
        return "end"
    if o == "TRY_BEGIN":
        return "do\nlocal ok, err = pcall(function()"
    if o == "END_TRY":
        return "end)\nif not ok then\n    local _exc = type(err) == \"string\" and (err:match(\"^.-:%d+: (.*)$\") or err) or err\n    local _exc_matched = false"
    if o == "END_CATCH":
        return "    _exc_matched = true"
    if o == "END_ALL_CATCH":
        return "    if not _exc_matched then error(tostring(_exc)) end\nend\nend"
    if o == "CELL_GET":
        return ins.result + " = " + ins.args[0] + ".value"
    if o == "CELL_SET":
        return ins.args[0] + ".value = " + ins.args[1]
    if o == "MAKE_CELL":
        return ins.result + " = {value = " + ins.args[0] + "}"
    if o == "MAKE_FUNCTION":
        return ins.result + " = " + ins.args[0]
    if o == "MAKE_LIST":
        if ins.args:
            args = []
            for a in ins.args:
                s = str(a)
                if s.startswith("_t"):
                    args.append(s)
                else:
                    args.append('"' + s + '"')
            return ins.result + " = setmetatable({" + ", ".join(args) + "}, _list_mt)"
        return ins.result + " = setmetatable({}, _list_mt)"
    if o == "MAKE_TABLE":
        return ins.result + " = {}"
    if o == "MAKE_DICT":
        pairs = []
        for kv in ins.args:
            if isinstance(kv, (list, tuple)) and len(kv) == 2:
                pairs.append("[" + str(kv[0]) + "] = " + str(kv[1]))
            else:
                pairs.append("[" + str(kv[1]) + "] = " + str(kv[0]))
        return ins.result + " = setmetatable({" + ", ".join(pairs) + "}, _dict_mt)"
    if o == "MAKE_TUPLE":
        if ins.args:
            return ins.result + " = {" + ", ".join(str(a) for a in ins.args) + "}"
        return ins.result + " = {}"
    if o == "MAKE_SET":
        return ins.result + " = {}"
    if o == "SET_ADD":
        return ins.args[0] + "[#" + ins.args[0] + "+1] = " + ins.args[1]
    if o == "DICT_SET":
        return ins.args[0] + "[" + ins.args[1] + "] = " + ins.args[2]
    if o == "SELECT":
        return ins.result + " = (" + ins.args[0] + " and " + ins.args[1] + " or " + ins.args[2] + ")"
    if o == "SUBSCR":
        return ins.result + " = __luthon_get(" + ins.args[0] + ", " + ins.args[1] + ")"
    if o == "GET_ATTR":
        return ins.result + " = " + ins.args[0] + "." + ins.args[1]
    if o == "SET_ATTR":
        return ins.args[0] + "." + ins.args[1] + " = " + ins.args[2]
    if o == "MAKE_CLASS":
        return ins.result + " = " + ins.args[0]
    if o == "STORE_SUBSCR":
        return "__luthon_set(" + ins.args[0] + ", " + ins.args[1] + ", " + ins.args[2] + ")"
    if o == "LIST_REPEAT":
        return ins.result + " = list_repeat(" + ins.args[0] + ", " + ins.args[1] + ")"
    if o == "LIST_APPEND":
        return ins.args[0] + "[#" + ins.args[0] + "+1] = " + ins.args[1]
    if o == "DICT_COUNTER_INC":
        d_name, k_name, step_val = ins.args[0], ins.args[1], ins.args[2]
        return f"{d_name}[{k_name}] = ({d_name}[{k_name}] or 0) + {step_val}"
    if o == "NEXT":
        return ins.result + " = " + ins.args[0] + "()"
    if o == "IMPORT":
        return ins.args[0] + " = _luthon_import(\"" + ins.args[1] + "\")"
    if o == "IMPORT_FROM":
        return ins.args[0] + " = _luthon_import_from(\"" + ins.args[1] + "\", \"" + ins.args[2] + "\")"
    return "-- " + o


def generate(module, sourcemap=None):
    # propagate upvalue names into enclosing locals for Lua capture
    by_name = {f.name: f for f in module.functions}
    for fn in module.functions:
        for child in module.functions:
            if child is fn:
                continue
            for uv in getattr(child, "upvalues", []):
                if uv not in fn.locals:
                    fn.locals.append(uv)
    out = [
        "local _bit_band, _bit_bor, _bit_bxor, _bit_lshift, _bit_rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift",
        "local _math_floor, _math_abs, _math_min, _math_max = math.floor, math.abs, math.min, math.max",
        "local _table_insert, _table_concat, _string_sub = table.insert, table.concat, string.sub",
    ]
    _fnames = {f.name for f in module.functions}
    # hoist class tables for dotted method names
    classes = set()
    all_upvalues = set()
    for fn in module.functions:
        if "." in fn.name:
            classes.add(fn.name.split(".", 1)[0])
        for uv in getattr(fn, "upvalues", []) or []:
            all_upvalues.add(uv)
    for c in sorted(classes):
        out.append(c + " = " + c + " or {}")
    builtins = {"len","range","print","list","round","math","os","sys","json","random","re","str","int","float","abs","min","max","sum","sorted","reversed","enumerate","zip","map","filter","any","all","bool","datetime","collections","itertools","functools","pathlib","string","base64","io","struct","hashlib","typing","site","tempfile","open","dataclasses","subprocess","ast","array","ffi","bit","set","frozenset","table","dict"}
    # Hoist module-level locals that are captured as upvalues
    hoisted_set = set()
    main_fn = next((f for f in module.functions if f.name == "main"), None)
    if main_fn and all_upvalues:
        hoisted = [uv for uv in sorted(all_upvalues) if uv in main_fn.locals and uv not in builtins]
        if hoisted:
            out.append("local " + ", ".join(hoisted))
            hoisted_set = set(hoisted)
    for fn in module.functions:
        if "." in fn.name:
            prefix, meth = fn.name.split(".", 1)
            out.append(prefix + "." + meth + " = function(" + ", ".join(fn.params) + ")")
        else:
            out.append("local function " + fn.name + "(" + ", ".join(fn.params) + ")")
        if getattr(fn, "upvalues", None):
            out.append("  -- upvalues: " + ", ".join(fn.upvalues))
        builtins = {"len","range","print","list","round","math","os","sys","json","random","re","str","int","float","abs","min","max","sum","sorted","reversed","enumerate","zip","map","filter","any","all","bool","datetime","collections","itertools","functools","pathlib","string","base64","io","struct","hashlib","typing","site","tempfile","open","dataclasses","subprocess","ast","array","matrix","ffi","bit","set","frozenset","table","dict","_luthon_anchor","_luthon_release_anchor","_luthon_is_anchored"}
        _classes = {fn.name.split(chr(46),1)[0] for fn in module.functions if chr(46) in fn.name}
        uv_set = set(getattr(fn, "upvalues", []) or [])
        locs = [l for l in fn.locals if l not in builtins and l not in _fnames and l not in _classes and l not in uv_set and l not in hoisted_set]
        tmps = [t for t in getattr(fn, "tmps", []) if t not in locs]
        # Declare tmps as locals only when the count is small enough to avoid LuaJIT's 200-local limit.
        # Recursive functions (fib, binarytrees) need local tmps; large non-recursive main() can use globals.
        if len(locs) + len(tmps) <= 150:
            allvars = locs + tmps
            if allvars:
                out.append("  local " + ", ".join(allvars))
        elif locs:
            out.append("  local " + ", ".join(locs))
        for b in fn.blocks:
            out.append("  ::" + b.label + "::")
            for ins in b.instrs:
                gen_line = len(out) + 1
                if sourcemap is not None and getattr(ins, "src_line", 0) > 0:
                    src_file = sourcemap.file or (sourcemap.sources[0] if sourcemap.sources else "")
                    sourcemap.add(
                        gen_line=gen_line,
                        gen_col=2,
                        src_line=ins.src_line,
                        src_col=getattr(ins, "src_col", 0),
                        src_file=src_file,
                    )
                out.append("  " + _emit(ins))
        out.append("end")
    # Fixed-layout C-struct compilation (Phase 18)
    struct_classes = set()
    for s_name, s_cdef, s_fields in getattr(module, "native_structs", []):
        struct_classes.add(s_name)
        out.append(f"ffi.cdef[[\n{s_cdef}\n]]")
        out.append(f"local {s_name}_mt = {{ __index = {s_name} }}")
        out.append(f"pcall(function() ffi.metatype('{s_name}_t', {s_name}_mt) end)")
        init_args = ", ".join(s_fields)
        init_assigns = " ".join([f"inst.{f} = {f} or 0;" for f in s_fields])
        out.append(f"setmetatable({s_name}, {{__call = function(cls, {init_args}) local inst = ffi.new('{s_name}_t'); {init_assigns} return inst end}})")

    for c in sorted({fn.name.split(chr(46),1)[0] for fn in module.functions if chr(46) in fn.name}):
        if c in struct_classes:
            continue
        has_repr = any(f.name == c + ".__repr__" for f in module.functions)
        has_eq = any(f.name == c + ".__eq__" for f in module.functions)
        out.append(c + ".__index = " + c)
        mt_setup = c + ".__instance_mt = {__index = " + c
        if has_repr:
            mt_setup += ", __tostring = function(inst) return " + c + ".__repr__(inst) end"
        if has_eq:
            mt_setup += ", __eq = function(a, b) return " + c + ".__eq__(a, b) end"
        mt_setup += "}"
        out.append(mt_setup)
        call_body = "local self = setmetatable({}, " + c + ".__instance_mt); if " + c + ".__init__ then " + c + ".__init__(self, ...) end; return self"
        out.append("setmetatable(" + c + ", {__call = function(cls, ...) " + call_body + " end})")
    return "\n".join(out) + "\n"


def generate_with_sourcemap(module, filename=""):
    from .sourcemap import SourceMap
    sm = SourceMap(file=filename, sources=[filename] if filename else [])
    code = generate(module, sourcemap=sm)
    return code, sm

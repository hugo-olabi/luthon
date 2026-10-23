def _op(op):
    return {"add": "+", "sub": "-", "mul": "*", "div": "/", "mod": "%", "pow": "^"}.get(op, op)


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
        return ins.result + " = " + l + " " + _op(ins.args[0]) + " " + r
    if o == "UNOP":
        if ins.args[0] == "neg":
            return ins.result + " = -" + ins.args[1]
        return ins.result + " = " + ins.args[1]
    if o == "RETURN":
        return "return " + (ins.args[0] if ins.args and ins.args[0] else "")
    if o == "JUMP":
        return "goto " + ins.args[0]
    if o == "BRANCH":
        return "if " + ins.args[0] + " then goto " + ins.args[1] + " else goto " + ins.args[2] + " end"
    if o == "BRANCH_NONE":
        return "if " + ins.args[0] + " == nil then goto " + ins.args[1] + " end"
    if o == "CMP":
        return ins.result + " = (" + ins.args[1] + " " + ins.args[0].replace("eq","==").replace("ne","~=").replace("lt","<").replace("le","<=").replace("gt",">").replace("ge",">=") + " " + ins.args[2] + ")"
    if o == "CALL":
        args = ", ".join(str(a) for a in ins.args[1:])
        return ins.result + " = " + str(ins.args[0]) + "(" + args + ")"
    if o == "DO":
        return "do"
    if o == "END":
        return "end"
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
            return ins.result + " = {" + ", ".join(args) + "}"
        return ins.result + " = {}"
    if o == "MAKE_TABLE":
        return ins.result + " = {}"
    if o == "MAKE_DICT":
        pairs = []
        for kv in ins.args:
            if isinstance(kv, (list, tuple)) and len(kv) == 2:
                pairs.append("[" + str(kv[0]) + "] = " + str(kv[1]))
            else:
                pairs.append("[" + str(kv[1]) + "] = " + str(kv[0]))
        return ins.result + " = {" + ", ".join(pairs) + "}"
    if o == "SUBSCR":
        return ins.result + " = " + ins.args[0] + "[(function() local _i = " + ins.args[1] + "; if type(_i) == \"number\" then _i = _i + 1 end; return _i end)()]"
    if o == "GET_ATTR":
        return ins.result + " = " + ins.args[0] + "." + ins.args[1]
    if o == "SET_ATTR":
        return ins.args[0] + "." + ins.args[1] + " = " + ins.args[2]
    if o == "MAKE_CLASS":
        return ins.result + " = " + ins.args[0]
    if o == "STORE_SUBSCR":
        return ins.args[0] + "[(function() local _i = " + ins.args[1] + "; if type(_i) == \"number\" then _i = _i + 1 end; return _i end)()] = " + ins.args[2]
    if o == "LIST_REPEAT":
        return ins.result + " = list_repeat(" + ins.args[0] + ", " + ins.args[1] + ")"
    if o == "LIST_APPEND":
        return ins.args[0] + "[#" + ins.args[0] + "+1] = " + ins.args[1]
    if o == "NEXT":
        return ins.result + " = " + ins.args[0] + "()"
    return "-- " + o


def generate(module):
    # propagate upvalue names into enclosing locals for Lua capture
    by_name = {f.name: f for f in module.functions}
    for fn in module.functions:
        for child in module.functions:
            if child is fn:
                continue
            for uv in getattr(child, "upvalues", []):
                if uv not in fn.locals:
                    fn.locals.append(uv)
    out = []
    _fnames = {f.name for f in module.functions}
    # hoist class tables for dotted method names
    classes = set()
    for fn in module.functions:
        if "." in fn.name:
            classes.add(fn.name.split(".", 1)[0])
    for c in sorted(classes):
        out.append(c + " = " + c + " or {}")
    for fn in module.functions:
        if "." in fn.name:
            prefix, meth = fn.name.split(".", 1)
            out.append(prefix + "." + meth + " = function(" + ", ".join(fn.params) + ")")
        else:
            out.append("local function " + fn.name + "(" + ", ".join(fn.params) + ")")
        if getattr(fn, "upvalues", None):
            out.append("  -- upvalues: " + ", ".join(fn.upvalues))
        builtins = {"len","range","print","list","round","math","os","sys","json","random","re","str","int","float","abs","min","max","sum","sorted","reversed","enumerate","zip","map","filter","any","all","bool","datetime","collections","itertools","functools","pathlib","string","base64","io","struct","hashlib","typing","site","tempfile","open","dataclasses","subprocess","ast"}
        _classes = {fn.name.split(chr(46),1)[0] for fn in module.functions if chr(46) in fn.name}
        locs = [l for l in fn.locals if l not in builtins and l not in _fnames and l not in _classes]
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
                out.append("  " + _emit(ins))
        out.append("end")
    for c in sorted({fn.name.split(chr(46),1)[0] for fn in module.functions if chr(46) in fn.name}):
        has_repr = any(f.name == c + ".__repr__" for f in module.functions)
        has_eq = any(f.name == c + ".__eq__" for f in module.functions)
        init_part = "local self = {}; for k,v in pairs(cls) do self[k]=v end; cls.__init__(self, ...)"
        mt_part = ""
        if has_repr or has_eq:
            mt_part = "; if not cls.__instance_mt then cls.__instance_mt = {}; "
            if has_repr:
                mt_part = mt_part + "cls.__instance_mt.__tostring = function(inst) return cls.__repr__(inst) end; "
            if has_eq:
                mt_part = mt_part + "cls.__instance_mt.__eq = function(a, b) return cls.__eq__(a, b) end; "
            mt_part = mt_part + "end; setmetatable(self, cls.__instance_mt)"
        call_body = init_part + mt_part + "; return self end"
        out.append("setmetatable(" + c + ", {__call = function(cls, ...) " + call_body + "})")
    return "\n".join(out) + "\n"

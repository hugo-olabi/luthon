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
    if o == "BINOP_DIRECT":
        l = ins.args[1] if ins.args[1] is not None else "nil"
        r = ins.args[2] if ins.args[2] is not None else "nil"
        op_sym = _op(ins.args[0])
        return f"{ins.result} = ({l} {op_sym} {r})"
    if o == "BINOP":
        l = ins.args[1] if ins.args[1] is not None else "nil"
        r = ins.args[2] if ins.args[2] is not None else "nil"
        orig_op = ins.args[0] or ""
        is_typed_num = orig_op.startswith("int.__typed_") or orig_op.startswith("float.__typed_")
        is_typed_str = orig_op.startswith("str.__typed_")
        raw_op = orig_op.lower()
        # Clean typed magic method signatures (e.g. int.__typed_add__ -> add)
        if "__typed_" in raw_op:
            raw_op = raw_op.split("__typed_")[1].rstrip("_")
        if is_typed_num and raw_op in ("add", "+"):
            return f"{ins.result} = ({l} + {r})"
        elif is_typed_num and raw_op in ("sub", "-"):
            return f"{ins.result} = ({l} - {r})"
        elif is_typed_num and raw_op in ("mul", "*"):
            return f"{ins.result} = ({l} * {r})"
        elif is_typed_num and raw_op in ("mod", "%"):
            return f"{ins.result} = ({l} % {r})"
        elif is_typed_str and raw_op in ("add", "+", "concat"):
            return f"{ins.result} = ({l} .. {r})"
        elif raw_op == "concat":
            return f"{ins.result} = ({l} .. {r})"
        elif raw_op in ("floordiv", "//"):
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
        elif raw_op in ("add", "+"):
            return ins.result + " = _luthon_add(" + l + ", " + r + ")"
        return ins.result + " = " + l + " " + _op(raw_op) + " " + r
    if o == "UNOP":
        if ins.args[0] == "neg":
            return ins.result + " = -" + ins.args[1]
        elif ins.args[0] == "not":
            return ins.result + " = not " + ins.args[1]
        elif ins.args[0] in ("inv", "invert"):
            return ins.result + " = bit.bnot(" + ins.args[1] + ")"
        return ins.result + " = " + ins.args[1]
    if o == "RETURN":
        return "do return " + (ins.args[0] if ins.args and ins.args[0] else "") + " end"
    if o == "TRY_RETURN":
        ret_val = ins.args[0] if ins.args and ins.args[0] else "nil"
        return f"_luthon_ret_val = {ret_val}; _luthon_has_ret = true; do return end"
    if o == "TRY_BREAK":
        return "_luthon_has_break = true; do return end"
    if o == "TRY_CONTINUE":
        return "_luthon_has_continue = true; do return end"
    if o == "TRY_UNWIND":
        depth = int(ins.args[0]) if (ins.args and ins.args[0]) else 0
        break_lbl = ins.args[1] if (len(ins.args) > 1 and ins.args[1]) else None
        cont_lbl = ins.args[2] if (len(ins.args) > 2 and ins.args[2]) else None
        lines = []
        if depth > 0:
            lines.append("if _luthon_has_ret or _luthon_has_break or _luthon_has_continue then do return end end")
        else:
            lines.append("if _luthon_has_ret then local _r = _luthon_ret_val; _luthon_ret_val = nil; _luthon_has_ret = false; return _r end")
            if break_lbl:
                lines.append(f"if _luthon_has_break then _luthon_has_break = false; goto {break_lbl} end")
            if cont_lbl:
                lines.append(f"if _luthon_has_continue then _luthon_has_continue = false; goto {cont_lbl} end")
        return "\n".join(lines)
    if o == "JUMP":
        return "goto " + ins.args[0]
    if o == "BRANCH":
        flag = ins.args[3] if len(ins.args) >= 4 else None
        if flag == "bool":
            return "if " + ins.args[0] + " then goto " + ins.args[1] + " else goto " + ins.args[2] + " end"
        elif flag in ("list", "str"):
            return "if (#" + ins.args[0] + " > 0) then goto " + ins.args[1] + " else goto " + ins.args[2] + " end"
        return "if _luthon_truthy(" + ins.args[0] + ") then goto " + ins.args[1] + " else goto " + ins.args[2] + " end"
    if o == "BRANCH_NONE":
        return "if " + ins.args[0] + " == nil or " + ins.args[0] + " == _G.None then goto " + ins.args[1] + " end"
    if o == "BRANCH_TRUE":
        flag = ins.args[2] if len(ins.args) >= 3 else None
        if flag == "bool":
            return "if " + ins.args[0] + " then goto " + ins.args[1] + " end"
        elif flag in ("list", "str"):
            return "if (#" + ins.args[0] + " > 0) then goto " + ins.args[1] + " end"
        return "if _luthon_truthy(" + ins.args[0] + ") then goto " + ins.args[1] + " end"
    if o == "BRANCH_FALSE":
        flag = ins.args[2] if len(ins.args) >= 3 else None
        if flag == "bool":
            return "if not " + ins.args[0] + " then goto " + ins.args[1] + " end"
        elif flag in ("list", "str"):
            return "if (#" + ins.args[0] + " == 0) then goto " + ins.args[1] + " end"
        return "if not _luthon_truthy(" + ins.args[0] + ") then goto " + ins.args[1] + " end"
    if o == "CMP":
        cmp_op = (ins.args[0] or "")
        if cmp_op in ("in", "In"):
            return ins.result + " = _luthon_in(" + ins.args[1] + ", " + ins.args[2] + ")"
        elif cmp_op in ("notin", "NotIn", "not in"):
            return ins.result + " = _luthon_not_in(" + ins.args[1] + ", " + ins.args[2] + ")"
        mapped_op = cmp_op.replace("eq","==").replace("ne","~=").replace("lt","<").replace("le","<=").replace("gt",">").replace("ge",">=")
        return ins.result + " = _luthon_cmp('" + mapped_op + "', " + ins.args[1] + ", " + ins.args[2] + ")"
    if o in ("IN_UNROLL", "NOT_IN_UNROLL"):
        lhs = ins.args[0]
        eqs = []
        for v in ins.args[1:]:
            if v is True:
                eqs.append(f"({lhs} == true)")
            elif v is False:
                eqs.append(f"({lhs} == false)")
            elif v is None:
                eqs.append(f"({lhs} == nil)")
            elif isinstance(v, str):
                eqs.append(f"({lhs} == {repr(v)})")
            else:
                eqs.append(f"({lhs} == {v})")
        joined = " or ".join(eqs)
        if o == "IN_UNROLL":
            return ins.result + " = (" + joined + ")"
        else:
            return ins.result + " = not (" + joined + ")"
    if o == "CMP_DIRECT":
        cmp_op = (ins.args[0] or "")
        mapped_op = cmp_op.replace("eq","==").replace("ne","~=").replace("lt","<").replace("le","<=").replace("gt",">").replace("ge",">=")
        return ins.result + " = (" + ins.args[1] + " " + mapped_op + " " + ins.args[2] + ")"
    if o == "CALL":
        args = ", ".join(str(a) for a in ins.args[1:])
        if ins.result:
            return ins.result + " = " + str(ins.args[0]) + "(" + args + ")"
        return str(ins.args[0]) + "(" + args + ")"
    if o == "DO":
        return "do"
    if o == "END":
        return "end"
    if o == "TRY_BEGIN_HOISTED":
        fn_name = ins.args[0]
        return f"do\nlocal ok, err = pcall({fn_name})"
    if o == "END_TRY_HOISTED":
        return "if not ok then\n    local _exc = type(err) == \"string\" and (err:match(\"^.-:%d+: (.*)$\") or err) or err\n    local _exc_matched = false"
    if o in ("TRY_BEGIN", "WITH_BEGIN"):
        scoped_vars = [str(a) for a in ins.args] if ins.args else []
        if scoped_vars:
            if len(scoped_vars) > 180:
                scoped_vars = scoped_vars[:180]
            return "do\nlocal ok, err = pcall(function()\n  local " + ", ".join(scoped_vars)
        return "do\nlocal ok, err = pcall(function()"
    if o == "WITH_END":
        mgr = ins.args[0]
        return f"""end)
if not ok then
  local _suppressed = _luthon_with_exit({mgr}, err)
  if not _suppressed then error(err, 0) end
else
  _luthon_with_exit({mgr}, nil)
end
end"""
    if o == "END_TRY":
        return "end)\nif not ok then\n    local _exc = type(err) == \"string\" and (err:match(\"^.-:%d+: (.*)$\") or err) or err\n    local _exc_matched = false"
    if o == "CATCH_BEGIN":
        if ins.args and ins.args[0]:
            return f"    if not _exc_matched and _luthon_exc_match(_exc, {ins.args[0]}) then\n        _exc_matched = true"
        return "    if not _exc_matched then\n        _exc_matched = true"
    if o == "END_CATCH":
        return "    end"
    if o == "END_ALL_CATCH":
        return "    if not _exc_matched then error(err, 0) end"
    if o == "TRY_ELSE":
        return "else\n    if not _luthon_has_ret then"
    if o == "END_TRY_ELSE":
        return "    end"
    if o == "TRY_CLOSE":
        return "end\nend"
    if o == "FINALLY_BEGIN":
        return "end)"
    if o == "FINALLY_END":
        return "if not ok then error(err, 0) end\nend"
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
            return ins.result + " = setmetatable({" + ", ".join(str(a) for a in ins.args) + "}, _list_mt)"
        return ins.result + " = setmetatable({}, _list_mt)"
    if o == "MAKE_TABLE":
        return ins.result + " = {}"
    if o == "MAKE_DICT":
        pairs = []
        for kv in ins.args:
            if isinstance(kv, (list, tuple)) and len(kv) == 2:
                k_expr = f"({kv[0]} == nil and _G._luthon_none or {kv[0]})"
                v_expr = f"({kv[1]} == nil and _G._luthon_none or {kv[1]})"
                pairs.append("[" + k_expr + "] = " + v_expr)
            else:
                k_expr = f"({kv[1]} == nil and _G._luthon_none or {kv[1]})"
                v_expr = f"({kv[0]} == nil and _G._luthon_none or {kv[0]})"
                pairs.append("[" + k_expr + "] = " + v_expr)
        return ins.result + " = setmetatable({" + ", ".join(pairs) + "}, _dict_mt)"
    if o == "MAKE_TUPLE":
        if ins.args:
            return ins.result + " = setmetatable({" + ", ".join(str(a) for a in ins.args) + "}, _tuple_mt)"
        return ins.result + " = setmetatable({}, _tuple_mt)"
    if o == "MAKE_SET":
        return ins.result + " = {}"
    if o == "SET_ADD":
        return ins.args[0] + "[#" + ins.args[0] + "+1] = " + ins.args[1]
    if o == "DICT_SET":
        is_raw_key = len(ins.args) > 3 and ins.args[3] == "raw_key"
        k_expr = ins.args[1] if is_raw_key else f"({ins.args[1]} == nil and _G._luthon_none or {ins.args[1]})"
        v_expr = f"({ins.args[2]} == nil and _G._luthon_none or {ins.args[2]})"
        return f"{ins.args[0]}[{k_expr}] = {v_expr}"
    if o == "SELECT":
        return ins.result + " = (" + ins.args[0] + " and " + ins.args[1] + " or " + ins.args[2] + ")"
    if o == "DEFAULT_ARG":
        return f"if {ins.args[0]} == nil then {ins.args[0]} = {ins.args[1]} end"
    if o == "SUBSCR":
        return ins.result + " = __luthon_get(" + ins.args[0] + ", " + ins.args[1] + ")"
    if o == "SUBSCR_DIRECT":
        t = ins.args[0]
        idx = ins.args[1]
        return f"{ins.result} = _luthon_subscr_fast({t}, {idx})"
    if o in ("SUBSCR_FAST_INDEX", "SUBSCR_FAST_VAR_INDEX"):
        t = ins.args[0]
        idx = ins.args[1]
        try:
            k = int(idx) + 1
            return f"{ins.result} = {t}[{k}]"
        except (ValueError, TypeError):
            return f"{ins.result} = {t}[{idx} + 1]"
    if o == "PATH_EXISTS":
        return f"{ins.result} = _luthon_fast_path_exists({ins.args[0]})"
    if o == "PATH_ISDIR":
        return f"{ins.result} = _luthon_fast_path_isdir({ins.args[0]})"
    if o == "PATH_BASENAME":
        return f"{ins.result} = _luthon_fast_path_basename({ins.args[0]})"
    if o == "PATH_DIRNAME":
        return f"{ins.result} = _luthon_fast_path_dirname({ins.args[0]})"
    if o == "PATH_GETSIZE":
        return f"{ins.result} = _luthon_fast_path_getsize({ins.args[0]})"
    if o == "PATH_JOIN":
        if len(ins.args) == 2:
            return f"{ins.result} = _luthon_fast_path_join2({ins.args[0]}, {ins.args[1]})"
        return f"{ins.result} = os.path.join({', '.join(str(a) for a in ins.args)})"
    if o == "GET_ATTR":
        return ins.result + " = " + ins.args[0] + "." + ins.args[1]
    if o == "SET_ATTR":
        return ins.args[0] + "." + ins.args[1] + " = " + ins.args[2]
    if o == "MAKE_CLASS":
        return ins.result + " = " + ins.args[0]
    if o == "STORE_SUBSCR":
        return "__luthon_set(" + ins.args[0] + ", " + ins.args[1] + ", " + ins.args[2] + ")"
    if o == "STORE_SUBSCR_DIRECT":
        t = ins.args[0]
        idx = ins.args[1]
        val = ins.args[2]
        return f"if rawget({t}, '_buf') or rawget({t}, '_py') then {t}[{idx}] = {val} else {t}[{idx} + 1] = {val} end"
    if o == "STORE_SUBSCR_FAST_LIST":
        t = ins.args[0]
        idx = ins.args[1]
        val = ins.args[2]
        try:
            k = int(idx) + 1
            return f"{t}[{k}] = {val}"
        except (ValueError, TypeError):
            return f"{t}[{idx} + 1] = {val}"
    if o == "LIST_REPEAT":
        return ins.result + " = list_repeat(" + ins.args[0] + ", " + ins.args[1] + ")"
    if o == "LIST_APPEND":
        return ins.args[0] + "[#" + ins.args[0] + "+1] = " + ins.args[1]
    if o == "SUBSCR_FAST_KEY":
        return ins.result + " = " + ins.args[0] + "[" + ins.args[1] + "]"
    if o == "SLICE_STR":
        s, l, u = ins.args[0], ins.args[1], ins.args[2]
        l_expr = "1" if l in ("nil", None) else f"({l} + 1)"
        u_expr = "" if u in ("nil", None) else f", {u}"
        return f"{ins.result} = string.sub({s}, {l_expr}{u_expr})"
    if o == "DICT_COUNTER_INC":
        d_name, k_name, step_val = ins.args[0], ins.args[1], ins.args[2]
        return f"{d_name}[{k_name}] = ({d_name}[{k_name}] or 0) + {step_val}"
    if o == "NEXT":
        return ins.result + " = " + ins.args[0] + "()"
    if o == "IMPORT":
        if len(ins.args) > 2 and ins.args[2]:
            return ins.args[0] + " = _luthon_import(\"" + ins.args[1] + "\", \"" + ins.args[2] + "\")"
        return ins.args[0] + " = _luthon_import(\"" + ins.args[1] + "\")"
    if o == "IMPORT_FROM":
        return ins.args[0] + " = _luthon_import_from(\"" + ins.args[1] + "\", \"" + ins.args[2] + "\")"
    if o == "MOVE":
        return ins.result + " = " + str(ins.args[0])
    if o == "SIMD_BLOCK":
        op_type = ins.args[0]
        if op_type == "daxpy":
            n, alpha, x, y = ins.args[1], ins.args[2], ins.args[3], ins.args[4]
            elem_t = ins.args[5] if len(ins.args) > 5 else "double"
            x_buf = f"(rawget({x}, '_buf') and rawget({x}, '_buf') or {x})"
            y_buf = f"(rawget({y}, '_buf') and rawget({y}, '_buf') or {y})"
            if elem_t == "float":
                return f"_simd_lib.luthon_simd_saxpy({n}, {alpha}, {x_buf}, {y_buf})"
            return f"if (rawget({x}, 'typecode') == 'f' or rawget({y}, 'typecode') == 'f') then _simd_lib.luthon_simd_saxpy({n}, {alpha}, {x_buf}, {y_buf}) else _simd_lib.luthon_simd_daxpy({n}, {alpha}, {x_buf}, {y_buf}) end"
        elif op_type == "vec_add":
            n, a, b, c = ins.args[1], ins.args[2], ins.args[3], ins.args[4]
            elem_t = ins.args[5] if len(ins.args) > 5 else "double"
            a_buf = f"(rawget({a}, '_buf') and rawget({a}, '_buf') or {a})"
            b_buf = f"(rawget({b}, '_buf') and rawget({b}, '_buf') or {b})"
            c_buf = f"(rawget({c}, '_buf') and rawget({c}, '_buf') or {c})"
            if elem_t == "float":
                return f"_simd_lib.luthon_simd_add_f32({c_buf}, {a_buf}, {b_buf}, {n})"
            return f"if (rawget({a}, 'typecode') == 'f' or rawget({b}, 'typecode') == 'f' or rawget({c}, 'typecode') == 'f') then _simd_lib.luthon_simd_add_f32({c_buf}, {a_buf}, {b_buf}, {n}) else _simd_lib.luthon_simd_add_f64({c_buf}, {a_buf}, {b_buf}, {n}) end"
        elif op_type == "dot":
            n, a, b = ins.args[1], ins.args[2], ins.args[3]
            elem_t = ins.args[4] if len(ins.args) > 4 else "double"
            a_buf = f"(rawget({a}, '_buf') and rawget({a}, '_buf') or {a})"
            b_buf = f"(rawget({b}, '_buf') and rawget({b}, '_buf') or {b})"
            res = ins.result or "s"
            if elem_t == "float":
                return f"{res} = _simd_lib.luthon_simd_dot_f32({n}, {a_buf}, {b_buf})"
            return f"if (rawget({a}, 'typecode') == 'f' or rawget({b}, 'typecode') == 'f') then {res} = _simd_lib.luthon_simd_dot_f32({n}, {a_buf}, {b_buf}) else {res} = _simd_lib.luthon_simd_dot_f64({n}, {a_buf}, {b_buf}) end"
        elif op_type == "euclidean":
            n, a, b = ins.args[1], ins.args[2], ins.args[3]
            elem_t = ins.args[4] if len(ins.args) > 4 else "double"
            a_buf = f"(rawget({a}, '_buf') and rawget({a}, '_buf') or {a})"
            b_buf = f"(rawget({b}, '_buf') and rawget({b}, '_buf') or {b})"
            res = ins.result or "s"
            if elem_t == "float":
                return f"{res} = _simd_lib.luthon_simd_euclidean_f32({n}, {a_buf}, {b_buf})"
            return f"if (rawget({a}, 'typecode') == 'f' or rawget({b}, 'typecode') == 'f') then {res} = _simd_lib.luthon_simd_euclidean_f32({n}, {a_buf}, {b_buf}) else {res} = _simd_lib.luthon_simd_euclidean_f64({n}, {a_buf}, {b_buf}) end"
    if o == "VEC_LOAD":
        arr = ins.args[0]
        idx = ins.args[1]
        elem_t = ins.args[3] if len(ins.args) > 3 else "f64"
        fn_name = "luthon_simd_v4df_load" if elem_t == "f64" else "luthon_simd_v8sf_load"
        buf = f"(rawget({arr}, '_buf') and rawget({arr}, '_buf') or {arr})"
        return f"{ins.result} = _simd_lib.{fn_name}({buf}, {idx})"
    if o == "VEC_STORE":
        arr = ins.args[0]
        idx = ins.args[1]
        val = ins.args[2]
        elem_t = ins.args[4] if len(ins.args) > 4 else "f64"
        fn_name = "luthon_simd_v4df_store" if elem_t == "f64" else "luthon_simd_v8sf_store"
        buf = f"(rawget({arr}, '_buf') and rawget({arr}, '_buf') or {arr})"
        return f"_simd_lib.{fn_name}({buf}, {idx}, {val})"
    if o == "VEC_BROADCAST":
        val = ins.args[0]
        elem_t = ins.args[2] if len(ins.args) > 2 else "f64"
        fn_name = "luthon_simd_v4df_broadcast" if elem_t == "f64" else "luthon_simd_v8sf_broadcast"
        return f"{ins.result} = _simd_lib.{fn_name}({val})"
    if o == "VEC_ADD":
        elem_t = ins.args[3] if len(ins.args) > 3 else "f64"
        fn_name = "luthon_simd_v4df_add" if elem_t == "f64" else "luthon_simd_v8sf_add"
        return f"{ins.result} = _simd_lib.{fn_name}({ins.args[0]}, {ins.args[1]})"
    if o == "VEC_SUB":
        elem_t = ins.args[3] if len(ins.args) > 3 else "f64"
        fn_name = "luthon_simd_v4df_sub" if elem_t == "f64" else "luthon_simd_v8sf_sub"
        return f"{ins.result} = _simd_lib.{fn_name}({ins.args[0]}, {ins.args[1]})"
    if o == "VEC_MUL":
        elem_t = ins.args[3] if len(ins.args) > 3 else "f64"
        fn_name = "luthon_simd_v4df_mul" if elem_t == "f64" else "luthon_simd_v8sf_mul"
        return f"{ins.result} = _simd_lib.{fn_name}({ins.args[0]}, {ins.args[1]})"
    if o == "VEC_FMA":
        elem_t = ins.args[4] if len(ins.args) > 4 else "f64"
        fn_name = "luthon_simd_v4df_fma" if elem_t == "f64" else "luthon_simd_v8sf_fma"
        return f"{ins.result} = _simd_lib.{fn_name}({ins.args[0]}, {ins.args[1]}, {ins.args[2]})"
    if o == "VEC_REDUCE_SUM":
        elem_t = ins.args[2] if len(ins.args) > 2 else "f64"
        fn_name = "luthon_simd_v4df_reduce_sum" if elem_t == "f64" else "luthon_simd_v8sf_reduce_sum"
        return f"{ins.result} = _simd_lib.{fn_name}({ins.args[0]})"
    return "-- " + o


def generate(module, sourcemap=None):
    out = [
        "local _bit_band, _bit_bor, _bit_bxor, _bit_lshift, _bit_rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift",
        "local _math_floor, _math_abs, _math_min, _math_max = math.floor, math.abs, math.min, math.max",
        "local _table_insert, _table_concat, _string_sub = table.insert, table.concat, string.sub",
        "local _simd_lib = _G._luthon_simd_lib",
        "if _simd_lib == nil then",
        "  local _ok_ffi, _ffi = pcall(require, 'ffi')",
        "  if _ok_ffi and _ffi then",
        "    pcall(function()",
        "      _ffi.cdef[[",
        "        typedef struct { double v[4]; } luthon_v4df;",
        "        typedef struct { float  v[8]; } luthon_v8sf;",
        "        int         luthon_simd_get_vector_width(void);",
        "        const char* luthon_simd_get_backend_name(void);",
        "        luthon_v4df luthon_simd_v4df_load(const double *ptr, int64_t offset);",
        "        void        luthon_simd_v4df_store(double *ptr, int64_t offset, luthon_v4df val);",
        "        luthon_v4df luthon_simd_v4df_broadcast(double scalar);",
        "        luthon_v4df luthon_simd_v4df_add(luthon_v4df a, luthon_v4df b);",
        "        luthon_v4df luthon_simd_v4df_sub(luthon_v4df a, luthon_v4df b);",
        "        luthon_v4df luthon_simd_v4df_mul(luthon_v4df a, luthon_v4df b);",
        "        luthon_v4df luthon_simd_v4df_fma(luthon_v4df a, luthon_v4df b, luthon_v4df c);",
        "        double      luthon_simd_v4df_reduce_sum(luthon_v4df a);",
        "        void   luthon_simd_saxpy(size_t n, float alpha, const float *x, float *y);",
        "        void   luthon_simd_daxpy(size_t n, double alpha, const double *x, double *y);",
        "        void   luthon_simd_add_f64(double *out, const double *a, const double *b, size_t n);",
        "        void   luthon_simd_add_f32(float *out, const float *a, const float *b, size_t n);",
        "        double luthon_simd_dot_f64(size_t n, const double *x, const double *y);",
        "        float  luthon_simd_dot_f32(size_t n, const float *x, const float *y);",
        "        double luthon_simd_euclidean_f64(size_t n, const double *x, const double *y);",
        "        float  luthon_simd_euclidean_f32(size_t n, const float *x, const float *y);",
        "        void   luthon_simd_poly_eval_f64(size_t n, const double *x, double *out, const double *coeffs, size_t deg);",
        "        void   luthon_simd_poly_eval_f32(size_t n, const float *x, float *out, const float *coeffs, size_t deg);",
        "        void   luthon_simd_sin_f64(double *out, const double *x, size_t n);",
        "        void   luthon_simd_cos_f64(double *out, const double *x, size_t n);",
        "        void   luthon_simd_exp_f64(double *out, const double *x, size_t n);",
        "        void   luthon_simd_sqrt_f64(double *out, const double *x, size_t n);",
        "      ]]",
        "    end)",
        "    local _candidates = {}",
        "    local _env_lib = os.getenv(\"LUTHON_CAPI_LIB\")",
        "    if _env_lib and _env_lib ~= '' then table.insert(_candidates, _env_lib) end",
        "    if _G.__LUTHON_CAPI_LIB__ and _G.__LUTHON_CAPI_LIB__ ~= '' then table.insert(_candidates, _G.__LUTHON_CAPI_LIB__) end",
        "    table.insert(_candidates, 'src/luthon/native/libluthon_capi.so')",
        "    table.insert(_candidates, './src/luthon/native/libluthon_capi.so')",
        "    table.insert(_candidates, './libluthon_capi.so')",
        "    table.insert(_candidates, 'libluthon_capi.so')",
        "    local _info = debug.getinfo(1, 'S')",
        "    if _info and _info.source and _info.source:sub(1, 1) == '@' then",
        "      local _src_path = _info.source:sub(2)",
        "      local _dir = _src_path:match('(.*/)') or ''",
        "      table.insert(_candidates, _dir .. '../native/libluthon_capi.so')",
        "      table.insert(_candidates, _dir .. 'libluthon_capi.so')",
        "    end",
        "    for _, _p in ipairs(_candidates) do",
        "      if _p and _p ~= '' then",
        "        local _ok_l, _lib = pcall(_ffi.load, _p)",
        "        if _ok_l and _lib then _simd_lib = _lib; _G._luthon_simd_lib = _lib; break end",
        "      end",
        "    end",
        "  end",
        "end",
        "if _simd_lib == nil then",
        "  _simd_lib = {",
        "    luthon_simd_v4df_load = function(ptr, off) return {v = {ptr[off], ptr[off+1], ptr[off+2], ptr[off+3]}} end,",
        "    luthon_simd_v4df_store = function(ptr, off, val) ptr[off] = val.v[1]; ptr[off+1] = val.v[2]; ptr[off+2] = val.v[3]; ptr[off+3] = val.v[4] end,",
        "    luthon_simd_v4df_broadcast = function(s) return {v = {s, s, s, s}} end,",
        "    luthon_simd_v4df_add = function(a, b) return {v = {a.v[1]+b.v[1], a.v[2]+b.v[2], a.v[3]+b.v[3], a.v[4]+b.v[4]}} end,",
        "    luthon_simd_v4df_sub = function(a, b) return {v = {a.v[1]-b.v[1], a.v[2]-b.v[2], a.v[3]-b.v[3], a.v[4]-b.v[4]}} end,",
        "    luthon_simd_v4df_mul = function(a, b) return {v = {a.v[1]*b.v[1], a.v[2]*b.v[2], a.v[3]*b.v[3], a.v[4]*b.v[4]}} end,",
        "    luthon_simd_v4df_fma = function(a, b, c) return {v = {a.v[1]*b.v[1]+c.v[1], a.v[2]*b.v[2]+c.v[2], a.v[3]*b.v[3]+c.v[3], a.v[4]*b.v[4]+c.v[4]}} end,",
        "    luthon_simd_v4df_reduce_sum = function(a) return a.v[1]+a.v[2]+a.v[3]+a.v[4] end,",
        "    luthon_simd_daxpy = function(n, alpha, x, y) for i=0, n-1 do y[i] = alpha*x[i] + y[i] end end,",
        "    luthon_simd_saxpy = function(n, alpha, x, y) for i=0, n-1 do y[i] = alpha*x[i] + y[i] end end,",
        "    luthon_simd_add_f64 = function(out, a, b, n) for i=0, n-1 do out[i] = a[i] + b[i] end end,",
        "    luthon_simd_add_f32 = function(out, a, b, n) for i=0, n-1 do out[i] = a[i] + b[i] end end,",
        "    luthon_simd_dot_f64 = function(n, x, y) local s=0 for i=0, n-1 do s = s + x[i]*y[i] end return s end,",
        "    luthon_simd_dot_f32 = function(n, x, y) local s=0 for i=0, n-1 do s = s + x[i]*y[i] end return s end,",
        "    luthon_simd_euclidean_f64 = function(n, x, y) local s=0 for i=0, n-1 do local d=x[i]-y[i] s = s + d*d end return math.sqrt(s) end,",
        "    luthon_simd_euclidean_f32 = function(n, x, y) local s=0 for i=0, n-1 do local d=x[i]-y[i] s = s + d*d end return math.sqrt(s) end,",
        "    luthon_simd_poly_eval_f64 = function(n, x, out, coeffs, deg)",
        "      for i=0, n-1 do",
        "        local xi = x[i]",
        "        local p = coeffs[deg]",
        "        for k=deg-1, 0, -1 do p = p * xi + coeffs[k] end",
        "        out[i] = p",
        "      end",
        "    end,",
        "    luthon_simd_sin_f64 = function(out, x, n) for i=0, n-1 do out[i] = math.sin(x[i]) end end,",
        "    luthon_simd_cos_f64 = function(out, x, n) for i=0, n-1 do out[i] = math.cos(x[i]) end end,",
        "    luthon_simd_exp_f64 = function(out, x, n) for i=0, n-1 do out[i] = math.exp(x[i]) end end,",
        "    luthon_simd_sqrt_f64 = function(out, x, n) for i=0, n-1 do out[i] = math.sqrt(x[i]) end end,",
        "  }",
        "end",
    ]
    fn_map = {fn.name: fn for fn in module.functions}
    _fnames = {f.name for f in module.functions}
    # hoist class tables for dotted method names and MAKE_CLASS statements
    classes = set()
    all_upvalues = set()
    for fn in module.functions:
        if "." in fn.name:
            classes.add(fn.name.split(".", 1)[0])
        if not getattr(fn, "is_nested", False):
            for uv in getattr(fn, "upvalues", []) or []:
                all_upvalues.add(uv)
        for b in fn.blocks:
            for ins in b.instrs:
                if ins.op == "MAKE_CLASS" and ins.args:
                    classes.add(ins.args[0])
    for c in sorted(classes):
        out.append(c + " = " + c + " or {}")
    builtins = {"len","range","print","list","round","math","os","sys","json","random","re","str","int","float","abs","min","max","sum","sorted","reversed","enumerate","zip","map","filter","any","all","bool","datetime","collections","itertools","functools","pathlib","string","base64","io","struct","hashlib","typing","site","tempfile","open","dataclasses","subprocess","ast","array","matrix","ffi","bit","set","frozenset","table","dict","bytes","type","_luthon_type","callable","issubclass","_luthon_anchor","_luthon_release_anchor","_luthon_is_anchored","isinstance","super","getattr","hasattr","setattr","delattr","iter","tuple","globals","locals","__name__","_simd_lib","repr","_luthon_add"}
    # Hoist module-level and cross-function locals that are captured as upvalues
    hoisted_set = set()
    if all_upvalues:
        hoisted = [uv for uv in sorted(all_upvalues) if uv not in builtins and uv not in classes]
        if hoisted:
            out.append("local " + ", ".join(hoisted))
            hoisted_set = set(hoisted)

    def _emit_func_lines(fn, fn_map, classes, builtins, _fnames, hoisted_set, sourcemap=None, indent="", is_anon=False, anon_res=None, base_line_offset=0):
        lines = []
        if is_anon:
            lines.append(f"{indent}{anon_res} = function(" + ", ".join(fn.params) + ")")
        elif "." in fn.name:
            prefix, meth = fn.name.split(".", 1)
            if meth in ("and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"):
                lines.append(f"{indent}{prefix}[\"{meth}\"] = function(" + ", ".join(fn.params) + ")")
            else:
                lines.append(f"{indent}{prefix}.{meth} = function(" + ", ".join(fn.params) + ")")
        elif fn.name == "main" and getattr(fn, "is_entry_point", False):
            lines.append(f"{indent}local function _luthon_module_entry(" + ", ".join(fn.params) + ")")
        elif fn.name == "main":
            lines.append(f"{indent}local function {fn.name}(" + ", ".join(fn.params) + ")")
        else:
            lines.append(f"{indent}function {fn.name}(" + ", ".join(fn.params) + ")")
        if getattr(fn, "upvalues", None):
            lines.append(f"{indent}  -- upvalues: " + ", ".join(fn.upvalues))

        _classes = set(classes)
        uv_set = set(getattr(fn, "upvalues", []) or [])
        param_set = set(fn.params or [])
        if fn.name == "main":
            locs = []
        else:
            locs = [l for l in fn.locals if l not in builtins and l not in _fnames and l not in _classes and l not in uv_set and l not in hoisted_set and l not in param_set]

        # Find tmps that belong exclusively to a try or with block using LCA
        try_stack = []
        tmp_paths = {}
        outside_tmps = set()
        for b in fn.blocks:
            for ins in b.instrs:
                if ins.op in ("TRY_BEGIN", "WITH_BEGIN"):
                    try_stack.append(ins)
                elif ins.op in ("END_TRY", "FINALLY_BEGIN", "WITH_END"):
                    if try_stack:
                        try_stack.pop()
                else:
                    ins_tmps = set()
                    if ins.result and (ins.result.startswith("_t") or ins.result.startswith("_r")):
                        ins_tmps.add(ins.result)
                    if ins.op == "STORE" and isinstance(ins.args[0], str) and (ins.args[0].startswith("_t") or ins.args[0].startswith("_r")):
                        ins_tmps.add(ins.args[0])
                    for a in ins.args:
                        if isinstance(a, str) and (a.startswith("_t") or a.startswith("_r")):
                            ins_tmps.add(a)
                        elif isinstance(a, (list, tuple)):
                            for item in a:
                                if isinstance(item, str) and (item.startswith("_t") or item.startswith("_r")):
                                    ins_tmps.add(item)
                    if not try_stack:
                        outside_tmps.update(ins_tmps)
                    else:
                        path = list(try_stack)
                        for t in ins_tmps:
                            if t not in tmp_paths:
                                tmp_paths[t] = []
                            tmp_paths[t].append(path)

        block_locals = {}
        for t, paths in tmp_paths.items():
            if t in outside_tmps:
                continue
            lca = paths[0]
            for p in paths[1:]:
                new_lca = []
                for x, y in zip(lca, p):
                    if x is y:
                        new_lca.append(x)
                    else:
                        break
                lca = new_lca
                if not lca:
                    break
            if lca:
                target_ins = lca[-1]
                target_id = id(target_ins)
                if target_id not in block_locals:
                    block_locals[target_id] = []
                block_locals[target_id].append(t)
            else:
                outside_tmps.add(t)

        try_exclusive_all = set()
        for b in fn.blocks:
            for ins in b.instrs:
                if ins.op in ("TRY_BEGIN", "WITH_BEGIN"):
                    tmps_for_ins = sorted(block_locals.get(id(ins), []))[:180]
                    ins.args = tmps_for_ins
                    try_exclusive_all.update(tmps_for_ins)

        total_var_count = len(locs) + len(getattr(fn, "tmps", []))
        if total_var_count > 100:
            try:
                from .optimizer import allocate_registers_function
                allocate_registers_function(fn)
                locs = [l for l in fn.locals if l not in builtins and l not in _fnames and l not in _classes and l not in uv_set and l not in hoisted_set and l not in param_set]
            except Exception:
                pass

        tmps = [t for t in getattr(fn, "tmps", []) if t not in locs and t not in param_set and t not in _classes and t not in try_exclusive_all]
        allvars = locs + tmps
        if allvars:
            for chunk_start in range(0, len(allvars), 80):
                chunk = allvars[chunk_start:chunk_start + 80]
                lines.append(f"{indent}  local " + ", ".join(chunk))

        # Loop-level try...except closure hoisting (Phase 31/NYI JIT Unlock)
        loop_blocks = set()
        try:
            from .optimizer import compute_cfg
            succs, preds = compute_cfg(fn)
            label_to_idx = {b.label: i for i, b in enumerate(fn.blocks)}
            for u, targets in succs.items():
                for v in targets:
                    if v in label_to_idx and label_to_idx[v] <= label_to_idx[u]:
                        loop_blocks.add(v)
                        loop_blocks.add(u)
                        queue = [u]
                        while queue:
                            curr = queue.pop(0)
                            for p in preds.get(curr, set()):
                                if p != v and p not in loop_blocks:
                                    loop_blocks.add(p)
                                    queue.append(p)
        except Exception:
            pass

        hoisted_closures = []
        closure_counter = 0
        from .ir import Instr
        from .debug import get_active_diary
        diary = get_active_diary()
        for b in fn.blocks:
            new_instrs = []
            idx = 0
            while idx < len(b.instrs):
                ins = b.instrs[idx]
                if ins.op == "TRY_BEGIN":
                    end_idx = None
                    nested_depth = 0
                    for j in range(idx + 1, len(b.instrs)):
                        if b.instrs[j].op == "TRY_BEGIN":
                            nested_depth += 1
                        elif b.instrs[j].op == "END_TRY":
                            if nested_depth == 0:
                                end_idx = j
                                break
                            else:
                                nested_depth -= 1
                    if end_idx is not None:
                        body_instrs = b.instrs[idx + 1 : end_idx]
                        has_cf = any(
                            ins.op in ("JUMP", "BRANCH", "BRANCH_NONE", "BRANCH_TRUE", "BRANCH_FALSE", "TRY_BREAK", "TRY_CONTINUE", "RETURN")
                            for ins in body_instrs
                        )
                        if not has_cf:
                            closure_counter += 1
                            safe_fn_name = fn.name.replace(".", "_").replace("<", "_").replace(">", "_")
                            closure_name = f"_try_closure_{safe_fn_name}_{closure_counter}"
                            scoped_vars = [str(a) for a in ins.args] if ins.args else []
                            hoisted_closures.append((closure_name, scoped_vars, body_instrs))
                            new_instrs.append(Instr(op="TRY_BEGIN_HOISTED", args=[closure_name]))
                            new_instrs.append(Instr(op="END_TRY_HOISTED", args=[]))
                            if diary:
                                diary.record_decision(
                                    fn.name,
                                    "TRY_BLOCK",
                                    "pcall",
                                    "hoisted_closure",
                                    is_native=True,
                                    reason="Pure try block without control flow hoisted to eliminate inner anonymous closure (FNEW)",
                                    line=ins.src_line,
                                    col=ins.src_col,
                                )
                            idx = end_idx + 1
                            continue
                        else:
                            if diary:
                                diary.record_decision(
                                    fn.name,
                                    "TRY_BLOCK",
                                    "pcall",
                                    "anonymous_closure",
                                    is_native=False,
                                    reason="Try block contains non-local control flow; kept anonymous closure",
                                    line=ins.src_line,
                                    col=ins.src_col,
                                    suggestion="Refactor non-local jumps out of try block to unlock closure hoisting",
                                )
                new_instrs.append(ins)
                idx += 1
            b.instrs = new_instrs

        for c_name, c_scoped, c_instrs in hoisted_closures:
            lines.append(f"{indent}  local {c_name} = function()")
            if c_scoped:
                if len(c_scoped) > 180:
                    c_scoped = c_scoped[:180]
                lines.append(f"{indent}    local " + ", ".join(c_scoped))
            for b_ins in c_instrs:
                lines.append(f"{indent}    " + _emit(b_ins))
            lines.append(f"{indent}  end")

        for b in fn.blocks:
            lines.append(f"{indent}  ::{b.label}::")
            has_simd_block = any(ins.op == "SIMD_BLOCK" for ins in b.instrs)
            for ins in b.instrs:
                if has_simd_block and ins.op in ("VEC_LOAD", "VEC_STORE", "VEC_BROADCAST", "VEC_FMA", "VEC_ADD", "VEC_SUB", "VEC_MUL", "VEC_REDUCE_SUM"):
                    continue
                if ins.op == "MAKE_FUNCTION" and ins.args and ins.args[0] in fn_map and getattr(fn_map[ins.args[0]], "is_nested", False):
                    child_fn = fn_map[ins.args[0]]
                    child_lines = _emit_func_lines(
                        child_fn, fn_map, classes, builtins, _fnames, hoisted_set,
                        sourcemap=sourcemap, indent=indent + "  ", is_anon=True, anon_res=ins.result,
                        base_line_offset=base_line_offset + len(lines)
                    )
                    lines.extend(child_lines)
                else:
                    gen_line = base_line_offset + len(lines) + 1
                    if sourcemap is not None and getattr(ins, "src_line", 0) > 0:
                        src_file = sourcemap.file or (sourcemap.sources[0] if sourcemap.sources else "")
                        sourcemap.add(
                            gen_line=gen_line,
                            gen_col=len(indent) + 2,
                            src_line=ins.src_line,
                            src_col=getattr(ins, "src_col", 0),
                            src_file=src_file,
                        )
                    lines.append(f"{indent}  " + _emit(ins))
        lines.append(f"{indent}end")
        return lines

    for fn in module.functions:
        if getattr(fn, "is_nested", False):
            continue
        fn_lines = _emit_func_lines(
            fn, fn_map, classes, builtins, _fnames, hoisted_set,
            sourcemap=sourcemap, base_line_offset=len(out)
        )
        out.extend(fn_lines)
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

    for c in sorted(classes):
        if c in struct_classes:
            continue
        out.append(c + ".__index = " + c)
        out.append(c + ".__name__ = '" + c + "'")
        out.append(c + ".__name = '" + c + "'")
        mt_setup = (
            c + ".__instance_mt = {__index = function(inst, k) "
            "if k == '__class__' then return rawget(inst, '__class__') end; "
            "local ga = rawget(inst, '__getattribute__') or (rawget(inst, '__class__') and inst.__class__.__getattribute__); "
            "if type(ga) == 'function' then return ga(inst, k) end; "
            "local v = rawget(inst, k); if v ~= nil then return v end; "
            "local cv = " + c + "[k]; "
            "if type(cv) == 'table' and type(cv.__get__) == 'function' then return cv:__get__(inst, " + c + ") end; "
            "if type(cv) == 'function' then "
            "return (_G._luthon_bind_method and _G._luthon_bind_method(cv, inst)) or function(...) if select(1, ...) == inst then return cv(...) else return cv(inst, ...) end end end; "
            "if cv ~= nil then return cv end; "
            "local py = rawget(inst, '_py'); if py ~= nil then local ok, res = pcall(function() return py[k] end); if ok and res ~= nil then return res end end; "
            "local g = rawget(inst, '__getattr__') or (rawget(inst, '__class__') and inst.__class__.__getattr__); "
            "if type(g) == 'function' then return g(inst, k) end; "
            "return nil end, "
            "__newindex = function(inst, k, v) "
            "local sa = rawget(inst, '__setattr__') or (rawget(inst, '__class__') and inst.__class__.__setattr__); "
            "if type(sa) == 'function' then sa(inst, k, v) else rawset(inst, k, v) end; "
            "local py = rawget(inst, '_py'); if py ~= nil then pcall(function() py[k] = v end) end end, "
            "__tostring = function(inst) "
            "local s = inst.__str__; if type(s) == 'function' then return s(inst) end; "
            "local r = inst.__repr__; if type(r) == 'function' then return r(inst) end; "
            "local cls = rawget(inst, '__class__'); "
            "local name = cls and (cls.__name__ or rawget(cls, '__name__')) or '" + c + "'; "
            "return '<' .. tostring(name) .. ' object>' end, "
            "__eq = function(a, b) "
            "local eq = type(a) == 'table' and a.__eq__; "
            "if type(eq) == 'function' then return eq(a, b) end; "
            "return rawequal(a, b) end}"
        )
        out.append(mt_setup)
        call_body = (
            "local self; "
            "if (rawget(" + c + ", '__new__') and not (type(" + c + ".__new__) == 'table' and rawget(" + c + ".__new__, '_py'))) or "
            "(" + c + ".__new__ and not (type(" + c + ".__new__) == 'table' and rawget(" + c + ".__new__, '_py')) and " + c + ".__new__ ~= (rawget(_G, 'object') and _G.object.__new__)) then "
            "self = " + c + ".__new__(" + c + ", ...) "
            "else "
            "self = setmetatable({__class__ = " + c + "}, " + c + ".__instance_mt) "
            "end; "
            "if type(self) == 'table' and " + c + ".__init__ then " + c + ".__init__(self, ...) end; "
            "return self"
        )
        cls_mt = "{__index = function(t, k) local b = rawget(t, '__base__'); return b and b[k] end, __call = function(cls, ...) " + call_body + " end}"
        out.append("setmetatable(" + c + ", " + cls_mt + ")")
    return "\n".join(out) + "\n"


def generate_with_sourcemap(module, filename=""):
    from .sourcemap import SourceMap
    sm = SourceMap(file=filename, sources=[filename] if filename else [])
    code = generate(module, sourcemap=sm)
    return code, sm

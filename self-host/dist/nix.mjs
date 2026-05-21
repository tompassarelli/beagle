import * as $$bc from 'beagle/core.js';

const NIX_RESERVED = ["if", "then", "else", "let", "in", "with", "rec", "inherit", "assert", "or", "true", "false", "null", "import"];

function nix_reserved_p(s) {
  return NIX_RESERVED.includes(s);
}

function mangle(name) {
  return (() => { const out = name.replaceAll("->", "mk").replaceAll("?", "_p").replaceAll("!", "_bang"); return (nix_reserved_p(out) ? ("".concat(out, "'")) : out); })();
}

function indent(depth) {
  return "  ".repeat(depth);
}

function escape_nix_string(s) {
  return s.replaceAll("\\", "\\\\").replaceAll("\n", "\\n").replaceAll("\"", "\\\"").replaceAll("${", "\\${");
}

function escape_nix_multiline(s) {
  return s.replaceAll("''", "'''").replaceAll("${", "''${");
}

function escape_nix_string_keep_interp(s) {
  return s.replaceAll("\\", "\\\\").replaceAll("\n", "\\n").replaceAll("\"", "\\\"");
}

function escape_nix_multiline_keep_interp(s) {
  return s.replaceAll("''", "'''");
}

function needs_parens_p(e) {
  return ((e == null) ? false : (() => { const node = e["node"]; return ((node === "call")) ? (() => { const fn_expr = e["fn"]; return ((fn_expr["node"] === "ref") ? (() => { const fn_name = fn_expr["name"]; return (!(nix_infix_op(fn_name) != null)); })() : true); })() : ((node === "fn")) ? true : ((node === "let")) ? true : ((node === "if")) ? true : ((node === "when")) ? true : ((node === "cond")) ? true : ((node === "match")) ? true : ((node === "for")) ? true : false; })());
}

function paren_wrap(text, e) {
  return (needs_parens_p(e) ? ("".concat("(", text, ")")) : text);
}

function nix_infix_op(name) {
  return ((name === "+")) ? "+" : ((name === "-")) ? "-" : ((name === "*")) ? "*" : ((name === "/")) ? "/" : ((name === "<")) ? "<" : ((name === ">")) ? ">" : ((name === "<=")) ? "<=" : ((name === ">=")) ? ">=" : ((name === "=")) ? "==" : ((name === "==")) ? "==" : ((name === "not=")) ? "!=" : ((name === "!=")) ? "!=" : ((name === "and")) ? "&&" : ((name === "or")) ? "||" : ((name === "mod")) ? "/* mod */" : null;
}

function emit_body(exprs, depth) {
  return ((exprs.length === 0)) ? "null" : ((exprs.length === 1)) ? emit_expr(exprs[0], depth) : (() => { const last_e = exprs[exprs.length - 1]; const stmts = exprs.slice(0, (exprs.length - 1)); const ind = indent((depth + 1)); const indices = $$bc.range(0, stmts.length); const binds = indices.map((i) => ("".concat(ind, "__s", i, " = ", emit_expr(stmts[i], (depth + 1)), ";"))); return ("".concat("let\n", binds.join("\n"), "\n", indent(depth), "in\n", indent(depth), emit_expr(last_e, depth))); })();
}

function emit_key(key, depth) {
  return ((key == null) ? "null" : (() => { const node = key["node"]; return (((node === "literal") && (key["kind"] === "keyword"))) ? key["value"] : (((node === "literal") && (key["kind"] === "string"))) ? ("".concat("\"", escape_nix_string(key["value"]), "\"")) : ((node === "quoted")) ? (() => { const d = key["datum"]; return (((typeof d === 'object' && d !== null && !Array.isArray(d)) && (d["type"] === "symbol")) ? (() => { const s = d["value"]; return (s.startsWith(":") ? s.substring(1) : s); })() : emit_expr(key, (depth + 1))); })() : ((node === "nix-interpolated-string")) ? emit_expr(key, (depth + 1)) : ((node === "ref")) ? ("".concat("${", mangle(key["name"]), "}")) : ("".concat("${", emit_expr(key, (depth + 1)), "}")); })());
}

function flattenable_map_p(val) {
  return ((val != null) && (val["node"] === "map") && (val["pairs"].length === 1) && (() => { const inner_val = val["pairs"][0]["val"]; return (!((inner_val != null) && (inner_val["node"] === "map"))); })());
}

function emit_nix_list(items, depth) {
  return ((items.length === 0) ? "[ ]" : (() => { const item_strs = items.map((i) => paren_wrap(emit_expr(i, depth), i)); const single_line = ("".concat("[ ", item_strs.join(" "), " ]")); const base_indent = (depth * 2); const has_maps = items.some((i) => ((i != null) && (i["node"] === "map"))); return (((items.length <= 6) && (!has_maps) && ((base_indent + single_line.length) <= 80)) ? single_line : (() => { const ind = indent((depth + 1)); return ("".concat("[\n", items.map((i) => ("".concat(ind, paren_wrap(emit_expr(i, (depth + 1)), i)))).join("\n"), "\n", indent(depth), "]")); })()); })());
}

function flatten_dot_path(prefix, pairs, depth) {
  return (() => { const ind = indent((depth + 1)); return pairs.reduce((acc, pair) => (() => { const key = pair["key"]; const val = pair["val"]; const key_str = emit_key(key, depth); const full_key = ("".concat(prefix, ".", key_str)); return (flattenable_map_p(val) ? [].concat(acc, flatten_dot_path(full_key, val["pairs"], depth)) : [...acc, ("".concat(ind, full_key, " = ", emit_expr(val, (depth + 1)), ";"))]); })(), []); })();
}

function emit_nix_attrs(pairs, depth) {
  return ((pairs.length === 0) ? "{ }" : (() => { const ind = indent((depth + 1)); const entries = pairs.reduce((acc, pair) => (() => { const key = pair["key"]; const val = pair["val"]; const key_str = emit_key(key, depth); return (((val != null) && (val["node"] === "map") && key_str.includes(".") && (val["pairs"].length === 1)) ? [].concat(acc, flatten_dot_path(key_str, val["pairs"], depth)) : [...acc, ("".concat(ind, key_str, " = ", emit_expr(val, (depth + 1)), ";"))]); })(), []); return ("".concat("{\n", entries.join("\n"), "\n", indent(depth), "}")); })());
}

function emit_nix_rec_attrs(pairs, depth) {
  return (() => { const ind = indent((depth + 1)); const entries = pairs.map((pair) => ("".concat(ind, mangle(pair["key"]), " = ", emit_expr(pair["val"], (depth + 1)), ";"))); return ("".concat("rec {\n", entries.join("\n"), "\n", indent(depth), "}")); })();
}

function emit_nix_interp_string(parts, depth) {
  return (() => { const chunks = parts.map((part) => (() => { const t = part["type"]; return ((t === "text") ? escape_nix_string_keep_interp(part["value"]) : ("".concat("${", emit_expr(part["value"], depth), "}"))); })()); return ("".concat("\"", chunks.join(""), "\"")); })();
}

function emit_nix_interp_string_inline(parts, depth) {
  return (() => { const chunks = parts.map((part) => (() => { const t = part["type"]; return ((t === "text") ? escape_nix_multiline_keep_interp(part["value"]) : ("".concat("${", emit_expr(part["value"], depth), "}"))); })()); return chunks.join(""); })();
}

function emit_nix_multiline_string(lines, depth) {
  return (() => { const ind = indent((depth + 1)); const line_strs = lines.map((line) => (() => { const t = line["type"]; return ((t === "text")) ? ("".concat(ind, line["value"])) : ((t === "interp")) ? ("".concat(ind, emit_nix_interp_string_inline(line["parts"], depth))) : ("".concat(ind, "${", emit_expr(line["value"], depth), "}")); })()); return ("".concat("''\n", line_strs.join("\n"), "\n", indent(depth), "''")); })();
}

function emit_nix_indented_string(text, depth, do_escape) {
  return (() => { const ind = indent((depth + 1)); const lines = text.split("\n"); const processed = lines.map((l) => ((l === "") ? "" : ("".concat(ind, (do_escape ? escape_nix_multiline(l) : l))))); return ("".concat("''\n", processed.join("\n"), "\n", indent(depth), "''")); })();
}

function extract_cfg_root(body_str) {
  return (() => { const m = body_str.match("options\\.myConfig\\.modules\\.([a-zA-Z0-9_-]+)"); return (m ? ("".concat("config.myConfig.modules.", m[1])) : null); })();
}

function emit_nix_fn_set(e, depth) {
  return (() => { const formals = e["formals"]; const rest_flag = e["rest"]; const at_name = e["at-name"]; const body = e["body"]; const formal_strs = formals.map((f) => (() => { const fname = f["name"]; const dflt = f["default"]; return ((dflt && (dflt !== false)) ? ("".concat(fname, " ? ", emit_expr(dflt, depth))) : fname); })()); const all_formals = (rest_flag ? [...formal_strs, "..."] : formal_strs); const set_str = all_formals.join(", "); const pattern = ((at_name && (at_name !== false)) ? ("".concat("{ ", set_str, " } @ ", mangle(at_name))) : ("".concat("{ ", set_str, " }"))); const body_str = emit_expr(body, depth); const cfg_root = (rest_flag ? extract_cfg_root(body_str) : null); return (((cfg_root != null) && (body["node"] === "map"))) ? (() => { const rewritten = body_str.replaceAll(("".concat(cfg_root, ".")), "cfg."); return ("".concat(pattern, ":\n\nlet\n  cfg = ", cfg_root, ";\nin\n", rewritten)); })() : (((cfg_root != null) && (body["node"] === "let") && body_str.startsWith("let\n"))) ? (() => { const rewritten = body_str.replaceAll(("".concat(cfg_root, ".")), "cfg."); const injected = rewritten.replace("let\n", ("".concat("let\n  cfg = ", cfg_root, ";\n"))); return ("".concat(pattern, ":\n\n", injected)); })() : ((rest_flag && (depth === 0))) ? ("".concat(pattern, ":\n\n", body_str)) : (rest_flag) ? ("".concat(pattern, ": ", body_str)) : ("".concat(pattern, ": ", body_str)); })();
}

function emit_core_call(fn_name, args, depth) {
  return (() => { const n = args.length; const a = (i) => emit_expr(args[i], depth); const aw = (i) => paren_wrap(emit_expr(args[i], depth), args[i]); return (((fn_name === "not") && (n === 1))) ? ("".concat("!", aw(0))) : ((fn_name === "str")) ? (() => { const parts = args.map((x) => emit_expr(x, depth)); return ("".concat("(", parts.join(" + "), ")")); })() : (((fn_name === "count") && (n === 1))) ? ("".concat("builtins.length ", aw(0))) : (((fn_name === "map") && (n === 2))) ? ("".concat("builtins.map ", aw(0), " ", aw(1))) : (((fn_name === "filter") && (n === 2))) ? ("".concat("builtins.filter ", aw(0), " ", aw(1))) : ((fn_name === "concat")) ? ((n === 2) ? ("".concat("(", a(0), " ++ ", a(1), ")")) : ("".concat("(", args.map((x) => emit_expr(x, depth)).join(" ++ "), ")"))) : ((fn_name === "merge")) ? ((n === 2) ? ("".concat("(", a(0), " // ", a(1), ")")) : ("".concat("(", args.map((x) => emit_expr(x, depth)).join(" // "), ")"))) : (((fn_name === "get") && (n >= 2))) ? ("".concat(a(0), ".", a(1))) : (((fn_name === "assoc") && (n === 3))) ? ("".concat("(", a(0), " // { ", a(1), " = ", a(2), "; })")) : (((fn_name === "nil?") && (n === 1))) ? ("".concat("(", a(0), " == null)")) : (((fn_name === "some?") && (n === 1))) ? ("".concat("(", a(0), " != null)")) : (((fn_name === "string?") && (n === 1))) ? ("".concat("(builtins.isString ", aw(0), ")")) : (((fn_name === "int?") && (n === 1))) ? ("".concat("(builtins.isInt ", aw(0), ")")) : (((fn_name === "list?") && (n === 1))) ? ("".concat("(builtins.isList ", aw(0), ")")) : (((fn_name === "map?") && (n === 1))) ? ("".concat("(builtins.isAttrs ", aw(0), ")")) : (((fn_name === "inc") && (n === 1))) ? ("".concat("(", a(0), " + 1)")) : (((fn_name === "dec") && (n === 1))) ? ("".concat("(", a(0), " - 1)")) : (((fn_name === "first") && (n === 1))) ? ("".concat("builtins.head ", aw(0))) : (((fn_name === "rest") && (n === 1))) ? ("".concat("builtins.tail ", aw(0))) : (((fn_name === "keys") && (n === 1))) ? ("".concat("builtins.attrNames ", aw(0))) : (((fn_name === "vals") && (n === 1))) ? ("".concat("builtins.attrValues ", aw(0))) : (((fn_name === "contains?") && (n >= 2))) ? ("".concat("(builtins.hasAttr ", a(1), " ", aw(0), ")")) : (((fn_name === "range") && (n === 1))) ? ("".concat("builtins.genList (x: x) ", a(0))) : (((fn_name === "range") && (n === 2))) ? ("".concat("builtins.genList (x: x + ", a(0), ") (", a(1), " - ", a(0), ")")) : (((fn_name === "println") && (n === 1))) ? ("".concat("builtins.trace ", aw(0), " null")) : (((fn_name === "nix-ident") && (n === 1))) ? (() => { const arg = args[0]; return (((arg["node"] === "literal") && (arg["kind"] === "string")) ? arg["value"] : a(0)); })() : null; })();
}

function emit_expr(e, depth) {
  return ((e == null) ? "null" : (() => { const node = e["node"]; return ((node === "literal")) ? (() => { const kind = e["kind"]; return ((kind === "string")) ? ("".concat("\"", escape_nix_string(e["value"]), "\"")) : ((kind === "number")) ? ("".concat(e["value"])) : ((kind === "float")) ? (() => { const s = ("".concat(e["value"])); return (s.includes(".") ? s : ("".concat(s, ".0"))); })() : ((kind === "bool")) ? (e["value"] ? "true" : "false") : ((kind === "nil")) ? "null" : ((kind === "keyword")) ? ("".concat("\"", escape_nix_string(e["value"]), "\"")) : "null"; })() : ((node === "ref")) ? (() => { const name = e["name"]; return ((name === "nil")) ? "null" : ((name === "true")) ? "true" : ((name === "false")) ? "false" : (name.startsWith(":")) ? ("".concat("\"", escape_nix_string(name.substring(1)), "\"")) : (name.includes("/")) ? name.replaceAll("/", ".") : (name.includes(".")) ? name : mangle(name); })() : ((node === "def")) ? ("".concat("let ", mangle(e["name"]), " = ", emit_expr(e["value"], depth), "; in ", mangle(e["name"]))) : ((node === "defonce")) ? ("".concat("let ", mangle(e["name"]), " = ", emit_expr(e["value"], depth), "; in ", mangle(e["name"]))) : ((node === "fn")) ? (() => { const params = e["params"]; const rest_p = e["rest"]; const body = e["body"]; const param_strs = params.map((p) => ("".concat(mangle(p["name"]), ":"))); const all_params = ((rest_p && (rest_p !== false)) ? [...param_strs, ("".concat(mangle(rest_p["name"]), ":"))] : param_strs); const param_str = all_params.join(" "); return ("".concat(param_str, " ", emit_body(body, depth))); })() : ((node === "let")) ? emit_let(e, depth) : ((node === "if")) ? ("".concat("if ", emit_expr(e["cond"], depth), " then ", emit_expr(e["then"], depth), " else ", emit_expr(e["else"], depth))) : ((node === "cond")) ? emit_cond(e, depth) : ((node === "when")) ? ("".concat("if ", emit_expr(e["cond"], depth), " then ", emit_body(e["body"], depth), " else null")) : ((node === "do")) ? emit_body(e["body"], depth) : ((node === "call")) ? emit_call(e, depth) : ((node === "vec")) ? emit_nix_list(e["items"], depth) : ((node === "map")) ? emit_nix_attrs(e["pairs"], depth) : ((node === "set")) ? emit_nix_list(e["items"], depth) : ((node === "kw-access")) ? (() => { const target_str = emit_expr(e["target"], depth); const kw = e["kw"]; const field = (kw.startsWith(":") ? kw.substring(1) : kw); return ("".concat(target_str, ".", field)); })() : ((node === "quoted")) ? emit_quoted(e["datum"], depth) : ((node === "match")) ? emit_match(e, depth) : ((node === "with")) ? emit_with_form(e, depth) : ((node === "for")) ? emit_for(e, depth) : ((node === "loop")) ? emit_loop(e, depth) : ((node === "recur")) ? "null /* recur outside loop */" : ((node === "record")) ? emit_record_defs(e, depth) : ((node === "defenum")) ? emit_defenum(e, depth) : ((node === "deferror")) ? emit_deferror(e, depth) : ((node === "defunion")) ? emit_deferror(e, depth) : ((node === "defscalar")) ? ("".concat("# scalar ", mangle(e["name"]), " (validated at compile time)")) : ((node === "defn")) ? emit_top_defn(e, depth) : ((node === "defn-multi")) ? emit_top_defn_multi(e, depth) : ((node === "check")) ? (() => { const inner = emit_expr(e["expr"], depth); return ("".concat("(let r = ", inner, "; in if r ? __tag && r.__tag == \"Ok\" then r.value else abort \"check failed\")")); })() : ((node === "rescue")) ? (() => { const inner = emit_expr(e["expr"], depth); const fallback = emit_expr(e["fallback"], depth); return ("".concat("(let r = ", inner, "; in if r ? __tag && r.__tag == \"Ok\" then r.value else ", fallback, ")")); })() : ((node === "target-case")) ? (() => { const cases = e["cases"]; const branch = cases.filter((c) => (c["target"] === "nix"))[0]; return (branch ? emit_expr(branch["body"], depth) : "null"); })() : ((node === "try")) ? ("".concat("builtins.tryEval (", emit_body(e["body"], depth), ")")) : ((node === "unsafe")) ? emit_expr(e["inner"], depth) : ((node === "unsafe-raw")) ? e["code"].trim() : ((node === "method-call")) ? (() => { const target_str = emit_expr(e["target"], depth); const method = e["method"]; const m_args = e["args"]; const clean = (method.startsWith(".") ? method.substring(1) : method); return (method.startsWith(".-") ? ("".concat(target_str, ".", mangle(method.substring(2)))) : (() => { const arg_strs = m_args.map((x) => emit_expr(x, depth)); return ("".concat(target_str, ".", clean, ((arg_strs.length === 0) ? "" : ("".concat(" ", arg_strs.join(" ")))))); })()); })() : ((node === "when-let")) ? ("".concat("let __v = ", emit_expr(e["expr"], depth), "; in if __v != null then ", "let ", mangle(e["name"]), " = __v; in ", emit_body(e["body"], depth), " else null")) : ((node === "if-let")) ? ("".concat("let __v = ", emit_expr(e["expr"], depth), "; in if __v != null then ", "let ", mangle(e["name"]), " = __v; in ", emit_expr(e["then"], depth), " else ", emit_expr(e["else"], depth))) : ((node === "block-string")) ? emit_nix_indented_string(e["text"], depth, true) : ((node === "nix-inherit")) ? (() => { const names = e["names"].map(mangle); return ("".concat("inherit ", names.join(" "), ";")); })() : ((node === "nix-inherit-from")) ? (() => { const ns_str = emit_expr(e["ns-expr"], depth); const names = e["names"].map(mangle); return ("".concat("inherit (", ns_str, ") ", names.join(" "), ";")); })() : ((node === "nix-with")) ? ("".concat("with ", emit_expr(e["ns-expr"], depth), "; ", emit_expr(e["body"], depth))) : ((node === "nix-rec-attrs")) ? emit_nix_rec_attrs(e["pairs"], depth) : ((node === "nix-assert")) ? ("".concat("assert ", emit_expr(e["cond"], depth), "; ", emit_expr(e["body"], depth))) : ((node === "nix-get-or")) ? ("".concat(emit_expr(e["base"], depth), ".", e["path"], " or ", emit_expr(e["default"], depth))) : ((node === "nix-has-attr")) ? ("".concat(emit_expr(e["base"], depth), " ? ", e["path"])) : ((node === "nix-search-path")) ? ("".concat("<", e["name"], ">")) : ((node === "nix-interpolated-string")) ? emit_nix_interp_string(e["parts"], depth) : ((node === "nix-multiline-string")) ? emit_nix_multiline_string(e["lines"], depth) : ((node === "nix-indented-string")) ? emit_nix_indented_string(e["text"], depth, false) : ((node === "nix-path")) ? e["path"] : ((node === "nix-fn-set")) ? emit_nix_fn_set(e, depth) : ((node === "nix-pipe")) ? (() => { const op = ((e["direction"] === "to") ? "|>" : "<|"); return ("".concat("(", emit_expr(e["lhs"], depth), " ", op, " ", emit_expr(e["rhs"], depth), ")")); })() : ((node === "nix-impl")) ? ("".concat("(", emit_expr(e["lhs"], depth), " -> ", emit_expr(e["rhs"], depth), ")")) : ("".concat("null /* unsupported: ", node, " */")); })());
}

function emit_let(e, depth) {
  return (() => { const bindings = e["bindings"]; const body = e["body"]; const ind = indent((depth + 1)); const bind_strs = bindings.map((b) => ("".concat(ind, mangle(b["name"]), " = ", emit_expr(b["value"], (depth + 1)), ";"))); return ("".concat("let\n", bind_strs.join("\n"), "\n", indent(depth), "in\n", indent(depth), emit_body(body, depth))); })();
}

function emit_call(e, depth) {
  return (() => { const fn_expr = e["fn"]; const args = e["args"]; return ((fn_expr["node"] === "ref") ? (() => { const fn_name = fn_expr["name"]; const op = nix_infix_op(fn_name); return ((op != null) ? ((args.length === 2)) ? ("".concat("(", emit_expr(args[0], depth), " ", op, " ", emit_expr(args[1], depth), ")")) : (((args.length === 1) && ((fn_name === "-") || (fn_name === "not")))) ? ("".concat("(", ((fn_name === "not") ? "!" : "-"), emit_expr(args[0], depth), ")")) : (() => { const pairs = $$bc.range(0, (args.length - 1)).map((i) => ("".concat(emit_expr(args[i], depth), " ", op, " ", emit_expr(args[(i + 1)], depth)))); return ("".concat("(", pairs.join(("".concat(" ", op, " "))), ")")); })() : (() => { const core = emit_core_call(fn_name, args, depth); return ((core != null) ? core : (fn_name.includes("/") ? (() => { const nix_name = fn_name.replaceAll("/", "."); const arg_strs = args.map((x) => paren_wrap(emit_expr(x, depth), x)); return ((arg_strs.length === 0) ? nix_name : ("".concat(nix_name, " ", arg_strs.join(" ")))); })() : (() => { const fn_str = mangle(fn_name); const arg_strs = args.map((x) => paren_wrap(emit_expr(x, depth), x)); return ((arg_strs.length === 0) ? fn_str : ("".concat(fn_str, " ", arg_strs.join(" ")))); })())); })()); })() : (() => { const fn_str = emit_expr(fn_expr, depth); const arg_strs = args.map((x) => paren_wrap(emit_expr(x, depth), x)); return ((arg_strs.length === 0) ? fn_str : ("".concat(fn_str, " ", arg_strs.join(" ")))); })()); })();
}

function emit_cond(e, depth) {
  return emit_cond_clauses(e["clauses"], depth);
}

function emit_cond_clauses(clauses, depth) {
  return ((clauses.length === 0) ? "null" : (() => { const c = clauses[0]; const test = c["test"]; const body = c["body"]; const is_else = (((test["node"] === "literal") && (test["kind"] === "keyword") && (test["value"] === "else")) || ((test["node"] === "ref") && (test["name"] === "else"))); return ((is_else && (clauses.length === 1)) ? emit_body(body, depth) : ("".concat("if ", emit_expr(test, depth), " then ", emit_body(body, depth), " else ", emit_cond_clauses(clauses.slice(1), depth)))); })());
}

function emit_match(e, depth) {
  return (() => { const target = emit_expr(e["target"], depth); const clauses = e["clauses"]; return emit_match_clauses(clauses, target, depth); })();
}

function emit_match_clauses(clauses, target, depth) {
  return ((clauses.length === 0) ? "null" : (() => { const c = clauses[0]; const pat = c["pattern"]; const body = c["body"]; const body_str = emit_body(body, depth); const pat_type = pat["type"]; return ((pat_type === "wildcard")) ? body_str : ((pat_type === "literal")) ? (() => { const v = pat["value"]; const val_str = ((v == null)) ? "null" : ((typeof v === 'string')) ? ("".concat("\"", escape_nix_string(v), "\"")) : ((typeof v === 'number')) ? ("".concat(v)) : ((v === true)) ? "true" : ((v === false)) ? "false" : ("".concat(v)); return ("".concat("if ", target, " == ", val_str, " then ", body_str, " else ", emit_match_clauses(clauses.slice(1), target, depth))); })() : ((pat_type === "record")) ? (() => { const tag = pat["name"].toLowerCase(); const bindings = pat["bindings"]; const bind_str = ((bindings.length === 0) ? body_str : (() => { const bind_parts = bindings.map((b) => (() => { const bname = mangle(b["name"]); return ("".concat(bname, " = ", target, ".", bname, ";")); })()); return ("".concat("let ", bind_parts.join(" "), " in ", body_str)); })()); return ("".concat("if ", target, "._tag == \"", escape_nix_string(tag), "\" then ", bind_str, " else ", emit_match_clauses(clauses.slice(1), target, depth))); })() : ((pat_type === "var")) ? ("".concat("let ", mangle(pat["name"]), " = ", target, "; in ", body_str)) : emit_match_clauses(clauses.slice(1), target, depth); })());
}

function emit_with_form(e, depth) {
  return (() => { const target_str = emit_expr(e["target"], depth); const updates = e["updates"]; const update_entries = updates.map((u) => (() => { const kw = u["field"]; const field = (kw.startsWith(":") ? kw.substring(1) : kw); return ("".concat(field, " = ", emit_expr(u["value"], depth), ";")); })()); return ("".concat("(", target_str, " // { ", update_entries.join(" "), " })")); })();
}

function emit_for(e, depth) {
  return (() => { const clauses = e["clauses"]; const body = e["body"]; const binding_clause = clauses.filter((c) => (c["type"] === "binding"))[0]; const when_clauses = clauses.filter((c) => (c["type"] === "when")); return ((binding_clause != null) ? (() => { const var_name = mangle(binding_clause["name"]); const coll = emit_expr(binding_clause["expr"], depth); const body_str = emit_body(body, depth); const mapped = ("".concat("builtins.map (", var_name, ": ", body_str, ") ", coll)); return ((when_clauses.length === 0) ? mapped : ("".concat("builtins.filter (", var_name, ": ", emit_expr(when_clauses[0]["test"], depth), ") (", mapped, ")"))); })() : "[ ]"); })();
}

function emit_loop(e, depth) {
  return (() => { const bindings = e["bindings"]; const body = e["body"]; const param_names = bindings.map((b) => mangle(b["name"])); const init_vals = bindings.map((b) => emit_expr(b["value"], depth)); const param_str = param_names.join(" "); return ("".concat("let __loop = ", param_str, ": ", emit_body(body, depth), "; in __loop ", init_vals.join(" "))); })();
}

function emit_record_defs(e, depth) {
  return (() => { const name = e["name"]; const fields = e["fields"]; const tag = name.toLowerCase(); const ctor_name = mangle(("".concat("->", name))); const ind = indent(depth); const field_names = fields.map((f) => f["name"]); const param_str = field_names.map((fn_name) => ("".concat(mangle(fn_name), ":"))).join(" "); const body_entries = [("".concat(ind, "  _tag = \"", escape_nix_string(tag), "\";")), ...field_names.map((fn_name) => ("".concat(ind, "  ", mangle(fn_name), " = ", mangle(fn_name), ";")))]; const ctor = ("".concat(ind, ctor_name, " = ", param_str, " {\n", body_entries.join("\n"), "\n", ind, "};")); const accessors = field_names.map((fn_name) => (() => { const acc_name = mangle(("".concat(name.toLowerCase(), "-", fn_name))); return ("".concat(ind, acc_name, " = r: r.", mangle(fn_name), ";")); })()); return [ctor, ...accessors].join("\n"); })();
}

function emit_defenum(e, depth) {
  return (() => { const name = mangle(e["name"]); const vals = e["values"]; const ind = indent(depth); const entries = vals.map((v) => ("".concat("\"", escape_nix_string(v), "\""))); return ("".concat(ind, name, "_values = [ ", entries.join(" "), " ];")); })();
}

function emit_deferror(e, depth) {
  return (() => { const name = mangle(e["name"]); const members = e["members"]; const mf = e["member-fields"]; const ind = indent(depth); const ctors = members.map((m) => (() => { const fields = ((mf == null) ? [] : mf[m]); const safe_fields = ((fields == null) ? [] : fields); return ((safe_fields.length === 0) ? ("".concat(ind, mangle(m), " = { __tag = \"", m, "\"; };")) : (() => { const param_names = safe_fields.map((f) => mangle(f["name"])); const params_str = param_names.join(": "); const field_entries = param_names.map((pn) => ("".concat(pn, " = ", pn, ";"))); return ("".concat(ind, mangle(m), " = ", params_str, ": { __tag = \"", m, "\"; ", field_entries.join(" "), " };")); })()); })()); return ("".concat(ind, "# error ", name, "\n", ctors.join("\n"))); })();
}

function emit_top_defn(e, depth) {
  return (() => { const name = mangle(e["name"]); const params = e["params"]; const rest_p = e["rest"]; const body = e["body"]; const ind = indent(depth); const param_strs = params.map((p) => ("".concat(mangle(p["name"]), ":"))); const all_params = ((rest_p && (rest_p !== false)) ? [...param_strs, ("".concat(mangle(rest_p["name"]), ":"))] : param_strs); const param_str = all_params.join(" "); const body_str = emit_body(body, depth); return ("".concat(ind, name, " = ", param_str, " ", body_str, ";")); })();
}

function emit_top_defn_multi(e, depth) {
  return (() => { const name = mangle(e["name"]); const first_arity = e["arities"][0]; const params = first_arity["params"]; const body = first_arity["body"]; const ind = indent(depth); const param_str = params.map((p) => ("".concat(mangle(p["name"]), ":"))).join(" "); return ("".concat(ind, name, " = ", param_str, " ", emit_body(body, depth), ";")); })();
}

function emit_quoted(d, depth) {
  return ((typeof d === 'string')) ? ("".concat("\"", escape_nix_string(d), "\"")) : ((typeof d === 'number')) ? ("".concat(d)) : ((d === true)) ? "true" : ((d === false)) ? "false" : ((d == null)) ? "null" : (((typeof d === 'object' && d !== null && !Array.isArray(d)) && (d["type"] === "symbol"))) ? ("".concat("\"", escape_nix_string(d["value"]), "\"")) : (((typeof d === 'object' && d !== null && !Array.isArray(d)) && (d["type"] === "keyword"))) ? ("".concat("\"", escape_nix_string(d["value"]), "\"")) : ("".concat("\"", d, "\""));
}

function is_def_form_p(f) {
  return (() => { const node = f["node"]; return ((node === "def") || (node === "defn") || (node === "defn-multi") || (node === "defonce") || (node === "record") || (node === "defenum") || (node === "deferror") || (node === "defscalar") || (node === "nix-inherit") || (node === "nix-inherit-from")); })();
}

function emit_top_def(f, depth) {
  return (() => { const node = f["node"]; const ind = indent(depth); return ((node === "def")) ? ("".concat(ind, mangle(f["name"]), " = ", emit_expr(f["value"], depth), ";")) : ((node === "defonce")) ? ("".concat(ind, mangle(f["name"]), " = ", emit_expr(f["value"], depth), ";")) : ((node === "defn")) ? emit_top_defn(f, depth) : ((node === "defn-multi")) ? emit_top_defn_multi(f, depth) : ((node === "record")) ? emit_record_defs(f, depth) : ((node === "defenum")) ? emit_defenum(f, depth) : ((node === "deferror")) ? emit_deferror(f, depth) : ((node === "defunion")) ? emit_deferror(f, depth) : ((node === "defscalar")) ? ("".concat(ind, "# scalar ", mangle(f["name"]), " (validated at compile time)")) : ((node === "nix-inherit")) ? (() => { const names = f["names"].map(mangle); return ("".concat(ind, "inherit ", names.join(" "), ";")); })() : ((node === "nix-inherit-from")) ? (() => { const ns_str = emit_expr(f["ns-expr"], depth); const names = f["names"].map(mangle); return ("".concat(ind, "inherit (", ns_str, ") ", names.join(" "), ";")); })() : ("".concat(ind, "# unsupported form: ", node)); })();
}

function emit_program(prog) {
  return (() => { const forms = prog["forms"]; const requires = prog["requires"]; const defs = forms.filter(is_def_form_p); const body_exprs = forms.filter((f) => (!is_def_form_p(f))); const import_str = ((requires.length === 0) ? "" : ("".concat(requires.map((r) => (() => { const ns_name = r["ns"]; const alias_name = r["alias"]; const parts = ns_name.split("."); const default_alias = parts[parts.length - 1]; const name = (alias_name ? alias_name : default_alias); return ("".concat("  ", mangle(name), " = import ./", ns_name.replaceAll(".", "/"), ".nix;")); })()).join("\n"), "\n"))); const def_strs = defs.map((d) => emit_top_def(d, 1)); const body_str = ((body_exprs.length === 0)) ? "null" : ((body_exprs.length === 1)) ? emit_expr(body_exprs[0], 0) : emit_expr(body_exprs[body_exprs.length - 1], 0); return (((defs.length === 0) && (requires.length === 0)) ? ("".concat(body_str, "\n")) : ("".concat("let\n", import_str, def_strs.join("\n"), "\n", "in\n", body_str, "\n"))); })();
}

function main() {
  return (() => { const chunks = ({value: [], watches: {}}); process.stdin.on("data", (chunk) => (() => { const _a = chunks, _v = [...chunks.value, chunk.toString()]; const _old = _a.value; _a.value = _v; for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _v); return _v; })());
return process.stdin.on("end", () => (() => { const input = chunks.value.join(""); const prog = JSON.parse(input); const output = emit_program(prog); return process.stdout.write(output); })()); })();
}

main();

import * as $$bc from 'beagle/core.js';

function mangle(name) {
  return name.replaceAll("-", "_").replaceAll("?", "_p").replaceAll("!", "_bang").replaceAll(">", "_gt").replaceAll("<", "_lt");
}

const INDENT_STEP = "    ";

function indent_more(ind) {
  return ("".concat(ind, INDENT_STEP));
}

function emit_param(p) {
  return (() => { const t = p["type"]; return ((t === "param")) ? mangle(p["name"]) : ((t === "map-destructure")) ? (() => { const as_name = p["as"]; return (as_name ? mangle(as_name) : "kwargs"); })() : ((t === "seq-destructure")) ? mangle(p["names"][0]) : "_"; })();
}

function emit_params(params, rest_p) {
  return (() => { const fixed = params.map(emit_param); const all = ((rest_p && (rest_p !== false)) ? (() => { const rname = (((typeof rest_p === 'object' && rest_p !== null && !Array.isArray(rest_p)) && rest_p["name"]) ? rest_p["name"] : ((typeof rest_p === 'string') ? rest_p : "args")); return [...fixed, ("".concat("*", mangle(rname)))]; })() : fixed); return all.join(", "); })();
}

function stmt_form_p(e) {
  return (() => { const node = e["node"]; return ((node === "def") || (node === "defn") || (node === "when") || (node === "doseq") || (node === "set!") || (node === "try") || (node === "for") || (node === "match") || (node === "cond") || (node === "loop") || (node === "case") || (node === "let") || (node === "when-let") || (node === "if-let") || (node === "dotimes") || (node === "letfn") || (node === "condp") || (node === "with-open") || (node === "when-some")); })();
}

function emit_body_block(body, ind) {
  return ((body.length === 0) ? ("".concat(ind, "pass")) : (() => { const init = body.slice(0, (body.length - 1)); const last_e = body[body.length - 1]; const stmts = init.map((e) => ("".concat(ind, emit_expr(e, ind)))); const last_str = (stmt_form_p(last_e) ? ("".concat(ind, emit_expr(last_e, ind))) : ("".concat(ind, "return ", emit_expr(last_e, ind)))); return [...stmts, last_str].join("\n"); })());
}

function emit_stmt_block(body, ind) {
  return ((body.length === 0) ? ("".concat(ind, "pass")) : body.map((e) => ("".concat(ind, emit_expr(e, ind)))).join("\n"));
}

function emit_body_stmts(body, ind) {
  return body.map((e) => emit_expr(e, ind)).join(("".concat("\n", ind)));
}

function emit_quoted(d) {
  return ((typeof d === 'string')) ? JSON.stringify(d) : ((typeof d === 'number')) ? ("".concat(d)) : (((typeof d === 'object' && d !== null && !Array.isArray(d)) && (d["type"] === "symbol"))) ? JSON.stringify(d["value"]) : (((typeof d === 'object' && d !== null && !Array.isArray(d)) && (d["type"] === "keyword"))) ? JSON.stringify(d["value"]) : (Array.isArray(d)) ? ("".concat("[", d.map(emit_quoted).join(", "), "]")) : ((d == null)) ? "None" : ((d === true)) ? "True" : ((d === false)) ? "False" : ("".concat(d));
}

function emit_pattern(p) {
  return (() => { const pt = p["type"]; return ((pt === "wildcard")) ? "_" : ((pt === "var")) ? mangle(p["name"]) : ((pt === "literal")) ? (() => { const v = p["value"]; return ((v == null)) ? "None" : ((typeof v === 'string')) ? JSON.stringify(v) : ((typeof v === 'number')) ? ("".concat(v)) : ((v === true)) ? "True" : ((v === false)) ? "False" : ("".concat(v)); })() : ((pt === "record")) ? (() => { const bindings = p["bindings"]; const field_strs = bindings.map((b) => mangle(b["name"])); return ("".concat(mangle(p["name"]), "(", field_strs.join(", "), ")")); })() : ((pt === "map")) ? (() => { const entries = p["entries"]; const entry_strs = entries.map((pair) => ("".concat(emit_expr(pair["key"], ""), ": ", emit_pattern(pair["value"])))); return ("".concat("{", entry_strs.join(", "), "}")); })() : "_"; })();
}

function emit_core_call(fn_name, args, ind) {
  return (() => { const n = args.length; const a = (i) => emit_expr(args[i], ind); return ((fn_name === "println")) ? ("".concat("print(", args.map((x) => emit_expr(x, ind)).join(", "), ")")) : ((fn_name === "str")) ? ((n === 1) ? ("".concat("str(", a(0), ")")) : ("".concat("\"\".join([str(x) for x in [", args.map((x) => emit_expr(x, ind)).join(", "), "]])"))) : (((fn_name === "pr-str") && (n === 1))) ? ("".concat("repr(", a(0), ")")) : (((fn_name === "throw") && (n === 1))) ? ("".concat("raise ", a(0))) : (((fn_name === "not") && (n === 1))) ? ("".concat("(not ", a(0), ")")) : (((fn_name === "nil?") && (n === 1))) ? ("".concat("(", a(0), " is None)")) : (((fn_name === "some?") && (n === 1))) ? ("".concat("(", a(0), " is not None)")) : (((fn_name === "count") && (n === 1))) ? ("".concat("len(", a(0), ")")) : (((fn_name === "inc") && (n === 1))) ? ("".concat("(", a(0), " + 1)")) : (((fn_name === "dec") && (n === 1))) ? ("".concat("(", a(0), " - 1)")) : (((fn_name === "conj") && (n === 2))) ? ("".concat("(", a(0), " + [", a(1), "])")) : (((fn_name === "cons") && (n === 2))) ? ("".concat("[", a(0), "] + ", a(1))) : (((fn_name === "assoc") && (n === 3))) ? ("".concat("{**", a(0), ", ", a(1), ": ", a(2), "}")) : (((fn_name === "get") && (n === 3))) ? ("".concat(a(0), ".get(", a(1), ", ", a(2), ")")) : (((fn_name === "get") && (n === 2))) ? ("".concat(a(0), ".get(", a(1), ")")) : (((fn_name === "contains?") && (n === 2))) ? ("".concat("(", a(1), " in ", a(0), ")")) : (((fn_name === "map") && (n === 2))) ? (() => { const fn_arg = args[0]; const coll_str = a(1); return ((fn_arg["node"] === "fn") ? (() => { const params = fn_arg["params"]; const p = params[0]; const pname = mangle(((p["type"] === "param") ? p["name"] : ("".concat(p)))); const body_expr = fn_arg["body"][0]; return ("".concat("[", emit_expr(body_expr, ind), " for ", pname, " in ", coll_str, "]")); })() : ("".concat("[", emit_expr(fn_arg, ind), "(x) for x in ", coll_str, "]"))); })() : (((fn_name === "filter") && (n === 2))) ? (() => { const fn_arg = args[0]; const coll_str = a(1); return ((fn_arg["node"] === "fn") ? (() => { const params = fn_arg["params"]; const p = params[0]; const pname = mangle(((p["type"] === "param") ? p["name"] : ("".concat(p)))); const body_expr = fn_arg["body"][0]; return ("".concat("[", pname, " for ", pname, " in ", coll_str, " if ", emit_expr(body_expr, ind), "]")); })() : ("".concat("[x for x in ", coll_str, " if ", emit_expr(fn_arg, ind), "(x)]"))); })() : (((fn_name === "reduce") && (n === 3))) ? ("".concat("__import__('functools').reduce(", a(0), ", ", a(1), ", ", a(2), ")")) : (((fn_name === "reduce") && (n === 2))) ? ("".concat("__import__('functools').reduce(", a(0), ", ", a(1), ")")) : ((fn_name === "range")) ? ("".concat("list(range(", args.map((x) => emit_expr(x, ind)).join(", "), "))")) : (((fn_name === "into") && (n === 2))) ? ("".concat("list(", a(1), ")")) : (((fn_name === "apply") && (n === 2))) ? ("".concat(a(0), "(*", a(1), ")")) : (((fn_name === "concat") && (n === 2))) ? ("".concat("(", a(0), " + ", a(1), ")")) : (((fn_name === "empty?") && (n === 1))) ? ("".concat("(len(", a(0), ") == 0)")) : (((fn_name === "first") && (n === 1))) ? ("".concat(a(0), "[0]")) : (((fn_name === "second") && (n === 1))) ? ("".concat(a(0), "[1]")) : (((fn_name === "last") && (n === 1))) ? ("".concat(a(0), "[-1]")) : (((fn_name === "rest") && (n === 1))) ? ("".concat(a(0), "[1:]")) : (((fn_name === "nth") && (n === 2))) ? ("".concat(a(0), "[", a(1), "]")) : (((fn_name === "identity") && (n === 1))) ? a(0) : (((fn_name === "+") && (n >= 2))) ? ("".concat("(", args.map((x) => emit_expr(x, ind)).join(" + "), ")")) : (((fn_name === "-") && (n >= 2))) ? ("".concat("(", args.map((x) => emit_expr(x, ind)).join(" - "), ")")) : (((fn_name === "*") && (n >= 2))) ? ("".concat("(", args.map((x) => emit_expr(x, ind)).join(" * "), ")")) : (((fn_name === "/") && (n >= 2))) ? ("".concat("(", args.map((x) => emit_expr(x, ind)).join(" / "), ")")) : (((fn_name === "=") && (n === 2))) ? ("".concat("(", a(0), " == ", a(1), ")")) : (((fn_name === "not=") && (n === 2))) ? ("".concat("(", a(0), " != ", a(1), ")")) : (((fn_name === "<") && (n === 2))) ? ("".concat("(", a(0), " < ", a(1), ")")) : (((fn_name === ">") && (n === 2))) ? ("".concat("(", a(0), " > ", a(1), ")")) : (((fn_name === "<=") && (n === 2))) ? ("".concat("(", a(0), " <= ", a(1), ")")) : (((fn_name === ">=") && (n === 2))) ? ("".concat("(", a(0), " >= ", a(1), ")")) : (((fn_name === "and") && (n === 2))) ? ("".concat("(", a(0), " and ", a(1), ")")) : (((fn_name === "or") && (n === 2))) ? ("".concat("(", a(0), " or ", a(1), ")")) : (((fn_name === "mod") && (n === 2))) ? ("".concat("(", a(0), " % ", a(1), ")")) : null; })();
}

function emit_record(e, ind) {
  return (() => { const name = mangle(e["name"]); const fields = e["fields"]; return ((fields.length === 0) ? ("".concat("@dataclass(frozen=True)\nclass ", name, ":\n    pass")) : (() => { const field_strs = fields.map((f) => ("".concat("    ", mangle(f["name"]), ": object"))); return ("".concat("@dataclass(frozen=True)\nclass ", name, ":\n", field_strs.join("\n"))); })()); })();
}

function emit_defenum(e, ind) {
  return (() => { const name = mangle(e["name"]); const vals = e["values"]; const val_strs = vals.map((v) => ("".concat("    ", mangle(v), " = ", JSON.stringify(v)))); return ("".concat("class ", name, ":\n", val_strs.join("\n"))); })();
}

function emit_defunion(e, ind) {
  return (() => { const name = mangle(e["name"]); const members = e["members"]; const mf = e["member-fields"]; const member_strs = members.map((m) => (() => { const fields = ((mf == null) ? [] : mf[m]); const safe_fields = ((fields == null) ? [] : fields); return ((safe_fields.length === 0) ? ("".concat("@dataclass(frozen=True)\nclass ", mangle(m), "(", name, "):\n    pass")) : (() => { const fstrs = safe_fields.map((f) => ("".concat("    ", mangle(f["name"]), ": object"))); return ("".concat("@dataclass(frozen=True)\nclass ", mangle(m), "(", name, "):\n", fstrs.join("\n"))); })()); })()); return ("".concat("class ", name, ":\n    pass\n\n", member_strs.join("\n\n"))); })();
}

function emit_deferror(e, ind) {
  return (() => { const name = mangle(e["name"]); const members = e["members"]; const mf = e["member-fields"]; const member_strs = members.map((m) => (() => { const fields = ((mf == null) ? [] : mf[m]); const safe_fields = ((fields == null) ? [] : fields); return ((safe_fields.length === 0) ? ("".concat("@dataclass(frozen=True)\nclass ", mangle(m), "(", name, "):\n    pass")) : (() => { const fstrs = safe_fields.map((f) => ("".concat("    ", mangle(f["name"]), ": object"))); return ("".concat("@dataclass(frozen=True)\nclass ", mangle(m), "(", name, "):\n", fstrs.join("\n"))); })()); })()); return ("".concat("class ", name, "(Exception):\n    pass\n\n", member_strs.join("\n\n"))); })();
}

function emit_defscalar(e, ind) {
  return (() => { const name = mangle(e["name"]); return ("".concat("@dataclass(frozen=True)\nclass ", name, ":\n    value: object")); })();
}

function emit_match(e, ind) {
  return (() => { const case_ind = indent_more(ind); const body_ind = indent_more(case_ind); const target_str = emit_expr(e["target"], ind); const clauses = e["clauses"]; const arm_strs = clauses.map((c) => (() => { const pat_str = emit_pattern(c["pattern"]); const body_str = emit_body_block(c["body"], body_ind); return ("".concat(case_ind, "case ", pat_str, ":\n", body_str)); })()); return ("".concat("match ", target_str, ":\n", arm_strs.join("\n"))); })();
}

function emit_case(e, ind) {
  return (() => { const case_ind = indent_more(ind); const body_ind = indent_more(case_ind); const target_str = emit_expr(e["test"], ind); const clauses = e["clauses"]; const arm_strs = clauses.map((c) => (() => { const val = c["value"]; const val_str = ((typeof val === 'object' && val !== null && !Array.isArray(val)) ? emit_expr(val, ind) : ((typeof val === 'string') ? JSON.stringify(val) : ("".concat(val)))); const body_node = c["body"]; const body_str = emit_body_block([body_node], body_ind); return ("".concat(case_ind, "case ", val_str, ":\n", body_str)); })()); const default_node = e["default"]; const default_str = (default_node ? (() => { const db = emit_body_block([default_node], body_ind); return ("".concat("\n", case_ind, "case _:\n", db)); })() : ""); return ("".concat("match ", target_str, ":\n", arm_strs.join("\n"), default_str)); })();
}

function contains_recur_p(e) {
  return ((e == null) ? false : (() => { const node = e["node"]; return ((node === "recur")) ? true : ((node === "if")) ? (contains_recur_p(e["then"]) || (e["else"] ? contains_recur_p(e["else"]) : false)) : ((node === "do")) ? e["body"].some((x) => contains_recur_p(x)) : ((node === "let")) ? e["body"].some((x) => contains_recur_p(x)) : ((node === "cond")) ? e["clauses"].some((c) => c["body"].some((x) => contains_recur_p(x))) : false; })());
}

function emit_recur_stmt(bindings, recur_args, ind) {
  return (() => { const assigns = $$bc.range(0, bindings.length).map((i) => ("".concat(ind, mangle(bindings[i]["name"]), " = ", emit_expr(recur_args[i], ind)))); return ("".concat(assigns.join("\n"), "\n", ind, "continue")); })();
}

function emit_loop_stmt(e, bindings, ind) {
  return (() => { const node = e["node"]; return ((node === "recur")) ? emit_recur_stmt(bindings, e["args"], ind) : ((node === "if")) ? (() => { const inner_ind = indent_more(ind); const then_str = emit_loop_stmt(e["then"], bindings, inner_ind); const else_node = e["else"]; const else_str = (else_node ? emit_loop_stmt(else_node, bindings, inner_ind) : ("".concat(inner_ind, "pass"))); return ("".concat(ind, "if ", emit_expr(e["cond"], ind), ":\n", then_str, "\n", ind, "else:\n", else_str)); })() : ("".concat(ind, "return ", emit_expr(e, ind))); })();
}

function emit_loop_body(body, bindings, ind) {
  return body.map((e) => (contains_recur_p(e) ? emit_loop_stmt(e, bindings, ind) : ("".concat(ind, emit_expr(e, ind))))).join("\n");
}

function emit_loop(e, ind) {
  return (() => { const bindings = e["bindings"]; const loop_ind = indent_more(ind); const init_strs = bindings.map((b) => ("".concat(mangle(b["name"]), " = ", emit_expr(b["value"], ind)))); const body_str = emit_loop_body(e["body"], bindings, loop_ind); return ("".concat(init_strs.join(("".concat("\n", ind))), "\n", ind, "while True:\n", body_str)); })();
}

function emit_for(e, ind) {
  return (() => { const clauses = e["clauses"]; const body = e["body"]; const body_expr = body[body.length - 1]; const parts = clauses.map((c) => (() => { const t = c["type"]; return ((t === "binding")) ? ("".concat("for ", mangle(c["name"]), " in ", emit_expr(c["expr"], ind))) : ((t === "when")) ? ("".concat("if ", emit_expr(c["test"], ind))) : ""; })()); const non_empty = parts.filter((s) => (s !== "")); return ("".concat("[", emit_expr(body_expr, ind), " ", non_empty.join(" "), "]")); })();
}

function emit_doseq(e, ind) {
  return (() => { const clauses = e["clauses"]; const body_ind = indent_more(ind); const binding = clauses[0]; const body_str = emit_stmt_block(e["body"], body_ind); return ("".concat("for ", mangle(binding["name"]), " in ", emit_expr(binding["expr"], ind), ":\n", body_str)); })();
}

function emit_cond_clause(c, keyword, ind, body_ind) {
  return (() => { const test = c["test"]; const body = c["body"]; const body_str = emit_body_block(body, body_ind); return ((((test["node"] === "literal") && (test["kind"] === "keyword") && (test["value"] === "else")) || ((test["node"] === "ref") && (test["name"] === "else"))) ? ("".concat("else:\n", body_str)) : ("".concat(keyword, " ", emit_expr(test, ind), ":\n", body_str))); })();
}

function emit_cond(e, ind) {
  return (() => { const clauses = e["clauses"]; const body_ind = indent_more(ind); const first_part = emit_cond_clause(clauses[0], "if", ind, body_ind); const rest_parts = clauses.slice(1).map((c) => emit_cond_clause(c, "elif", ind, body_ind)); return [first_part, ...rest_parts].join(("".concat("\n", ind))); })();
}

function emit_try(e, ind) {
  return (() => { const body_ind = indent_more(ind); const body_str = emit_body_block(e["body"], body_ind); const catches = e["catches"]; const catch_strs = catches.map((c) => (() => { const exc_type = (() => { const t = c["type"]; return ((t === "Exception") ? "Exception" : mangle(t)); })(); const catch_body = emit_body_block(c["body"], body_ind); return ("".concat("except ", exc_type, " as ", mangle(c["name"]), ":\n", catch_body)); })()); const finally_body = e["finally"]; const finally_str = (finally_body ? (() => { const fb = emit_body_block(finally_body, body_ind); return ("".concat("\n", ind, "finally:\n", fb)); })() : ""); return ("".concat("try:\n", body_str, "\n", ind, catch_strs.join(("".concat("\n", ind))), finally_str)); })();
}

function emit_condp(e, ind) {
  return (() => { const pred_fn = e["pred"]; const test_str = emit_expr(e["test"], ind); const clauses = e["clauses"]; const body_ind = indent_more(ind); const pred_name = ((pred_fn["node"] === "ref") ? pred_fn["name"] : null); const infix_op = ((pred_name === "=")) ? "==" : ((pred_name === "not=")) ? "!=" : ((pred_name === "<")) ? "<" : ((pred_name === ">")) ? ">" : ((pred_name === "<=")) ? "<=" : ((pred_name === ">=")) ? ">=" : null; const emit_condp_clause = (c, kw) => (() => { const test_clause = (infix_op ? ("".concat(emit_expr(c["test"], ind), " ", infix_op, " ", test_str)) : ("".concat(emit_expr(pred_fn, ind), "(", emit_expr(c["test"], ind), ", ", test_str, ")"))); const clause_body = ("".concat(body_ind, "return ", emit_expr(c["body"], body_ind))); return ("".concat(kw, " ", test_clause, ":\n", clause_body)); })(); const first_part = emit_condp_clause(clauses[0], "if"); const rest_parts = clauses.slice(1).map((c) => emit_condp_clause(c, "elif")); const parts = [first_part, ...rest_parts]; const default_node = e["default"]; const default_str = (default_node ? ("".concat("\n", ind, "else:\n", body_ind, "return ", emit_expr(default_node, body_ind))) : ""); return ("".concat(parts.join(("".concat("\n", ind))), default_str)); })();
}

function emit_let(e, ind) {
  return (() => { const bindings = e["bindings"]; const bind_strs = bindings.map((b) => ("".concat(mangle(b["name"]), " = ", emit_expr(b["value"], ind)))); const body = e["body"]; const body_strs = body.map((expr) => emit_expr(expr, ind)); return [].concat(bind_strs, body_strs).join(("".concat("\n", ind))); })();
}

function emit_fn(e, ind) {
  return (() => { const params_str = emit_params(e["params"], e["rest"]); const body = e["body"]; return ((body.length === 1) ? ("".concat("lambda ", params_str, ": ", emit_expr(body[0], ind))) : (() => { const body_str = emit_body_block(body, indent_more("")); return ("".concat("(lambda: (lambda ", params_str, ": (__fn := None, exec(\"\"\"def __fn(", params_str, "):\\n", body_str, "\"\"\"), __fn)[-1])(", params_str, "))()")); })()); })();
}

function emit_letfn(e, ind) {
  return (() => { const fns = e["fns"]; const fn_strs = fns.map((f) => (() => { const name = mangle(f["name"]); const params_str = emit_params(f["params"], f["rest"]); const body_ind = indent_more(ind); const body_str = emit_body_block(f["body"], body_ind); return ("".concat("def ", name, "(", params_str, "):\n", body_str)); })()); const body = e["body"]; const init = body.slice(0, (body.length - 1)); const init_strs = init.map((expr) => emit_expr(expr, ind)); const last_e = body[body.length - 1]; const last_str = (stmt_form_p(last_e) ? emit_expr(last_e, ind) : ("".concat("return ", emit_expr(last_e, ind)))); return [].concat(fn_strs, init_strs, [last_str]).join(("".concat("\n", ind))); })();
}

function emit_with(e, ind) {
  return (() => { const target_str = emit_expr(e["target"], ind); const updates = e["updates"]; const update_strs = updates.map((u) => (() => { const field_name = (() => { const f = u["field"]; return (f.startsWith(":") ? f.substring(1) : f); })(); return ("".concat(mangle(field_name), "=", emit_expr(u["value"], ind))); })()); return ("".concat("__import__('dataclasses').replace(", target_str, ", ", update_strs.join(", "), ")")); })();
}

function emit_expr(e, ind) {
  return ((e == null) ? "None" : (() => { const node = e["node"]; return ((node === "literal")) ? (() => { const kind = e["kind"]; return ((kind === "string")) ? JSON.stringify(e["value"]) : ((kind === "number")) ? ("".concat(e["value"])) : ((kind === "bool")) ? (e["value"] ? "True" : "False") : ((kind === "nil")) ? "None" : ((kind === "keyword")) ? JSON.stringify(e["value"]) : "None"; })() : ((node === "ref")) ? (() => { const name = e["name"]; return ((name === "nil")) ? "None" : ((name === "true")) ? "True" : ((name === "false")) ? "False" : (name.startsWith(":")) ? JSON.stringify(name.substring(1)) : mangle(name); })() : ((node === "def")) ? ("".concat(mangle(e["name"]), " = ", emit_expr(e["value"], ind))) : ((node === "defonce")) ? ("".concat(mangle(e["name"]), " = ", emit_expr(e["value"], ind))) : ((node === "defn")) ? (() => { const name = mangle(e["name"]); const params_str = emit_params(e["params"], e["rest"]); const body_ind = indent_more(ind); const body_str = emit_body_block(e["body"], body_ind); return ("".concat("def ", name, "(", params_str, "):\n", body_str)); })() : ((node === "defn-multi")) ? (() => { const name = mangle(e["name"]); const arities = e["arities"]; const deep_ind = indent_more(indent_more(ind)); const arity_strs = arities.map((a) => (() => { const body_str = emit_body_block(a["body"], deep_ind); return ("".concat("    if len(args) == ", a["params"].length, ":\n", body_str)); })()); return ("".concat("def ", name, "(*args):\n", arity_strs.join("\n"))); })() : ((node === "record")) ? emit_record(e, ind) : ((node === "defenum")) ? emit_defenum(e, ind) : ((node === "defunion")) ? emit_defunion(e, ind) : ((node === "deferror")) ? emit_deferror(e, ind) : ((node === "defscalar")) ? emit_defscalar(e, ind) : ((node === "if")) ? (() => { const then_str = emit_expr(e["then"], ind); const cond_str = emit_expr(e["cond"], ind); const else_node = e["else"]; const else_str = (else_node ? emit_expr(else_node, ind) : "None"); return ("".concat("(", then_str, " if ", cond_str, " else ", else_str, ")")); })() : ((node === "when")) ? (() => { const body_ind = indent_more(ind); const body_str = emit_body_block(e["body"], body_ind); return ("".concat("if ", emit_expr(e["cond"], ind), ":\n", body_str)); })() : ((node === "do")) ? emit_body_stmts(e["body"], ind) : ((node === "cond")) ? emit_cond(e, ind) : ((node === "let")) ? emit_let(e, ind) : ((node === "fn")) ? emit_fn(e, ind) : ((node === "call")) ? (() => { const fn_expr = e["fn"]; const args = e["args"]; return ((fn_expr["node"] === "ref") ? (() => { const fn_name = fn_expr["name"]; const core = emit_core_call(fn_name, args, ind); return ((core != null) ? core : ("".concat(mangle(fn_name), "(", args.map((x) => emit_expr(x, ind)).join(", "), ")"))); })() : ("".concat(emit_expr(fn_expr, ind), "(", args.map((x) => emit_expr(x, ind)).join(", "), ")"))); })() : ((node === "vec")) ? ("".concat("[", e["items"].map((x) => emit_expr(x, ind)).join(", "), "]")) : ((node === "map")) ? (() => { const pairs = e["pairs"]; const strs = pairs.map((p) => ("".concat(emit_expr(p["key"], ind), ": ", emit_expr(p["val"], ind)))); return ("".concat("{", strs.join(", "), "}")); })() : ((node === "set")) ? (() => { const items = e["items"]; return ((items.length === 0) ? "set()" : ("".concat("{", items.map((x) => emit_expr(x, ind)).join(", "), "}"))); })() : ((node === "method-call")) ? (() => { const method = e["method"]; const target_str = emit_expr(e["target"], ind); const args = e["args"]; const clean_name = (method.startsWith(".") ? method.substring(1) : method); return (method.startsWith(".-") ? ("".concat(target_str, ".", mangle(method.substring(2)))) : ("".concat(target_str, ".", mangle(clean_name), "(", args.map((x) => emit_expr(x, ind)).join(", "), ")"))); })() : ((node === "static-call")) ? (() => { const s = e["name"]; const args = e["args"]; const slash_idx = s.indexOf("/"); return ((slash_idx >= 0) ? ("".concat(mangle(s.substring(0, slash_idx)), ".", mangle(s.substring((slash_idx + 1))), "(", args.map((x) => emit_expr(x, ind)).join(", "), ")")) : ("".concat(mangle(s), "(", args.map((x) => emit_expr(x, ind)).join(", "), ")"))); })() : ((node === "new")) ? (() => { const cls = e["class"]; const clean = (cls.endsWith(".") ? cls.substring(0, (cls.length - 1)) : cls); return ("".concat(mangle(clean), "(", e["args"].map((x) => emit_expr(x, ind)).join(", "), ")")); })() : ((node === "kw-access")) ? (() => { const kw = e["kw"]; const key_str = kw.substring(1); const target_str = emit_expr(e["target"], ind); const default_val = e["default"]; return ((default_val && (default_val !== false)) ? ("".concat(target_str, ".get(", JSON.stringify(key_str), ", ", emit_expr(default_val, ind), ")")) : ("".concat(target_str, "[", JSON.stringify(key_str), "]"))); })() : ((node === "dynamic-var")) ? mangle(e["name"]) : ((node === "try")) ? emit_try(e, ind) : ((node === "for")) ? emit_for(e, ind) : ((node === "doseq")) ? emit_doseq(e, ind) : ((node === "dotimes")) ? (() => { const body_ind = indent_more(ind); const body_str = emit_stmt_block(e["body"], body_ind); return ("".concat("for ", mangle(e["name"]), " in range(", emit_expr(e["count"], ind), "):\n", body_str)); })() : ((node === "match")) ? emit_match(e, ind) : ((node === "case")) ? emit_case(e, ind) : ((node === "loop")) ? emit_loop(e, ind) : ((node === "recur")) ? "# ERROR: recur outside loop" : ((node === "with")) ? emit_with(e, ind) : ((node === "when-let")) ? (() => { const var_name = mangle(e["name"]); const body_ind = indent_more(ind); const body_str = emit_stmt_block(e["body"], body_ind); return ("".concat(var_name, " = ", emit_expr(e["expr"], ind), "\n", ind, "if ", var_name, " is not None:\n", body_str)); })() : ((node === "if-let")) ? (() => { const var_name = mangle(e["name"]); const then_str = emit_expr(e["then"], ind); const else_node = e["else"]; const else_str = (else_node ? emit_expr(else_node, ind) : "None"); return ("".concat(var_name, " = ", emit_expr(e["expr"], ind), "\n", then_str, " if ", var_name, " is not None else ", else_str)); })() : ((node === "await")) ? ("".concat("await ", emit_expr(e["expr"], ind))) : ((node === "set!")) ? ("".concat(emit_expr(e["target"], ind), " = ", emit_expr(e["value"], ind))) : ((node === "unsafe")) ? emit_expr(e["inner"], ind) : ((node === "unsafe-raw")) ? e["code"].trim() : ((node === "quoted")) ? emit_quoted(e["datum"]) : ((node === "regex")) ? ("".concat("re.compile(r\"", e["pattern"], "\")")) : ((node === "block-string")) ? ("".concat("\"\"\"", e["text"], "\"\"\"")) : ((node === "target-case")) ? (() => { const cases = e["cases"]; const branch = cases.filter((c) => (c["target"] === "py"))[0]; return (branch ? emit_expr(branch["body"], ind) : "None"); })() : ((node === "check")) ? (() => { const inner = emit_expr(e["expr"], ind); return ("".concat("(lambda r: r.value if r.is_ok() else (_ for _ in ()).throw(r.error))(", inner, ")")); })() : ((node === "rescue")) ? (() => { const inner = emit_expr(e["expr"], ind); const fallback = emit_expr(e["fallback"], ind); return ("".concat("(lambda r: r.value if r.is_ok() else ", fallback, ")(", inner, ")")); })() : ((node === "condp")) ? emit_condp(e, ind) : ((node === "letfn")) ? emit_letfn(e, ind) : ((node === "when-some")) ? (() => { const var_name = mangle(e["name"]); const body_ind = indent_more(ind); const body_str = emit_stmt_block(e["body"], body_ind); return ("".concat(var_name, " = ", emit_expr(e["expr"], ind), "\n", ind, "if ", var_name, " is not None:\n", body_str)); })() : ((node === "if-some")) ? (() => { const var_name = mangle(e["name"]); return ("".concat("(lambda __v: ", emit_expr(e["then"], ind), " if __v is not None else ", emit_expr(e["else"], ind), ")(", emit_expr(e["expr"], ind), ")")); })() : ((node === "unknown")) ? ("".concat("# UNSUPPORTED: ", e["raw"])) : ("".concat("# unknown node: ", node)); })());
}

function needs_dataclass_p(forms) {
  return forms.some((f) => (() => { const node = f["node"]; return ((node === "record") || (node === "defunion") || (node === "deferror")); })());
}

function emit_program(prog) {
  return (() => { const forms = prog["forms"]; const body = forms.map((f) => emit_expr(f, "")).join("\n\n"); const header = (needs_dataclass_p(forms) ? "from dataclasses import dataclass" : ""); return ((header === "") ? ("".concat(body, "\n")) : ("".concat(header, "\n\n", body, "\n"))); })();
}

function main() {
  return (() => { const chunks = ({value: [], watches: {}}); process.stdin.on("data", (chunk) => (() => { const _a = chunks, _v = [...chunks.value, chunk.toString()]; const _old = _a.value; _a.value = _v; for (const _k in _a.watches) _a.watches[_k](_k, _a, _old, _v); return _v; })());
return process.stdin.on("end", () => (() => { const input = chunks.value.join(""); const prog = JSON.parse(input); const output = emit_program(prog); return process.stdout.write(output); })()); })();
}

main();

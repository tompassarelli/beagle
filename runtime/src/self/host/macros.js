
const BRACKET_TAG = "#%brackets";

const MAP_TAG = "#%map";

const SET_TAG = "#%set";

const SPLICE_MARKER = "splice";

const MAX_EXPANSION_DEPTH = 64;

function make_root_ctx(name) {
  return {["macro-name"]: name, ["depth"]: 0, ["parent"]: null};
}

function push_ctx(parent, name) {
  return {["macro-name"]: name, ["depth"]: (1 + parent["depth"]), ["parent"]: parent};
}

function truncate_datum(datum) {
  return (() => { const s = unsafe_js("JSON.stringify(datum)", "", String); return ((s.length > 80) ? ("".concat(s.substring(0, 77), "...")) : s); })();
}

function collect_chain_lines(ctx) {
  return ((ctx == null) ? [] : [("".concat("  in macro: ", ctx["macro-name"], " (depth ", ctx["depth"], ")"))].concat(collect_chain_lines(ctx["parent"])));
}

function format_expansion_chain(ctx) {
  return (() => { const all_lines = collect_chain_lines(ctx); const n = all_lines.length; return ((n <= 10) ? all_lines.join("\n") : (() => { const top = all_lines.slice(0, 4); const bot = all_lines.slice((n - 4), n); return top.concat([("".concat("  ... (", (n - 8), " more)"))], bot).join("\n"); })()); })();
}

const KNOWN_FORM_HEADS = ["def", "defn", "defrecord", "defunion", "deferror", "defscalar", "defonce", "defmulti", "do", "let", "fn", "if", "cond", "when", "unless", "match", "case", "for", "doseq", "dotimes", "loop", "try", "println", "prn", "defn-", "ns", "require", "import", "define-macro", "declare-extern", "set!", "letfn", "when-let", "if-let", "when-some", "if-some", "condp"];

const gensym_state = {["counter"]: 0};

function gensym(prefix) {
  return (() => { const n = gensym_state["counter"]; (gensym_state["counter"] = (n + 1));
return ("".concat(prefix, "__g", ("".concat(n)))); })();
}

function datum_pair_p(d) {
  return (Array.isArray(d) && (d.length > 0));
}

function datum_car(d) {
  return d[0];
}

function datum_cdr(d) {
  return d.slice(1);
}

function datum_cons(h, t) {
  return (Array.isArray(t) ? [h].concat(t) : [h, t]);
}

function datum_null_p(d) {
  return (Array.isArray(d) && (d.length === 0));
}

function datum_append(a, b) {
  return a.concat(b);
}

function strip_reader_tags(datum) {
  return ((datum_pair_p(datum) && (datum_car(datum) === "quote"))) ? datum : ((datum_pair_p(datum) && (datum_car(datum) === BRACKET_TAG))) ? datum_cdr(datum).map(strip_reader_tags) : ((datum_pair_p(datum) && (datum_car(datum) === MAP_TAG))) ? datum_cons("hash", datum_cdr(datum).map(strip_reader_tags)) : ((datum_pair_p(datum) && (datum_car(datum) === SET_TAG))) ? datum_cons("set", datum_cdr(datum).map(strip_reader_tags)) : (datum_pair_p(datum)) ? datum.map(strip_reader_tags) : datum;
}

function make_macro_registry() {
  return {};
}

function register_macro_bang(reg, name, kind, params, template) {
  (() => { if ((!(reg[name] == null))) { return process.stderr.write(("".concat("beagle: duplicate macro definition: ", name, "\n"))); } })();
  return (() => { const amp_pos = params.indexOf("&"); const fixed_params = ((amp_pos > -1) ? params.slice(0, amp_pos) : params); const rest_param = ((amp_pos > -1) ? params[(amp_pos + 1)] : null); (reg[name] = {["kind"]: kind, ["fixed-params"]: fixed_params, ["rest-param"]: rest_param, ["template"]: template});
return null; })();
}

function lookup_macro(reg, name) {
  return reg[name];
}

function check_datum_contract(datum, contract, macro_name, position) {
  return ((contract === "Syntax")) ? true : ((contract === "Symbol")) ? ((typeof datum === 'string') ? true : (() => { process.stderr.write(("".concat("beagle: macro ", macro_name, ": ", position, ": expected Symbol\n")));
return false; })()) : ((contract === "String")) ? ((typeof datum === 'string') ? true : (() => { process.stderr.write(("".concat("beagle: macro ", macro_name, ": ", position, ": expected String\n")));
return false; })()) : ((contract === "Int")) ? ((typeof datum === 'number') ? true : (() => { process.stderr.write(("".concat("beagle: macro ", macro_name, ": ", position, ": expected Int\n")));
return false; })()) : ((contract === "Bool")) ? ((typeof datum === 'boolean') ? true : (() => { process.stderr.write(("".concat("beagle: macro ", macro_name, ": ", position, ": expected Bool\n")));
return false; })()) : ((contract === "Expr")) ? true : ((contract === "Form")) ? ((datum_pair_p(datum) && (typeof datum_car(datum) === 'string')) ? true : (() => { process.stderr.write(("".concat("beagle: macro ", macro_name, ": ", position, ": expected Form\n")));
return false; })()) : true;
}

function make_bindings(fixed_params, fixed_args, rest_name, rest_args) {
  return (() => { const bindings = {}; fixed_params.forEach((p, i) => (bindings[p] = fixed_args[i]));
(() => { if ((!(rest_name == null))) { return (bindings[rest_name] = rest_args); } })();
return bindings; })();
}

function splice_into_list(head, tail) {
  return ((datum_pair_p(head) && (datum_car(head) === "splice-marker")) ? datum_append(datum_cdr(head), tail) : datum_cons(head, tail));
}

function substitute(template, bindings, rest_name) {
  return ((datum_pair_p(template) && (template.length === 2) && (datum_car(template) === SPLICE_MARKER) && (typeof template[1] === 'string') && (!(bindings[template[1]] == null)))) ? (() => { const list_val = bindings[template[1]]; return datum_cons("splice-marker", list_val.map((e) => substitute(e, bindings, rest_name))); })() : (((typeof template === 'string') && (!(bindings[template] == null)))) ? (() => { const val = bindings[template]; return (((!(rest_name == null)) && (template === rest_name) && Array.isArray(val)) ? datum_cons(BRACKET_TAG, val) : val); })() : (datum_pair_p(template)) ? (() => { const head = substitute(datum_car(template), bindings, rest_name); const tail = substitute(datum_cdr(template), bindings, rest_name); return splice_into_list(head, tail); })() : template;
}

function unwrap_brackets(form) {
  return ((datum_pair_p(form) && (datum_car(form) === BRACKET_TAG))) ? datum_cdr(form) : (Array.isArray(form)) ? form : [];
}

function collect_param_binders(form, macro_params) {
  return (() => { const items = unwrap_brackets(form); const result = []; items.forEach((item) => (((typeof item === 'string') && (item !== "&") && (!macro_params.includes(item)))) ? (() => { result.push(item);
return null; })() : ((Array.isArray(item) && (item.length === 3) && (typeof item[0] === 'string') && (item[1] === ":") && (!macro_params.includes(item[0])))) ? (() => { result.push(item[0]);
return null; })() : null);
return result; })();
}

function collect_let_binders(form, macro_params) {
  return (() => { const items = unwrap_brackets(form); const result = []; items.forEach((item, i) => (() => { if ((((i % 2) === 0) && ((i + 1) < items.length))) { return ((Array.isArray(item) && (item.length === 3) && (typeof item[0] === 'string') && (item[1] === ":") && (!macro_params.includes(item[0])))) ? result.push(item[0]) : (((typeof item === 'string') && (!macro_params.includes(item)))) ? result.push(item) : null; } })());
return result; })();
}

function collect_template_binders(template, macro_params) {
  return (() => { const binders = []; return (() => { function add_unique(name) { return (() => { if ((!binders.includes(name))) { return binders.push(name); } })(); } function walk(datum) { return (() => { if (datum_pair_p(datum)) { return (() => { const head = datum_car(datum); return ((head === "let")) ? (() => { (() => { if ((datum.length > 2)) { return collect_let_binders(datum[1], macro_params).forEach(add_unique); } })();
datum_cdr(datum).forEach(walk);
return null; })() : ((head === "fn")) ? (() => { (() => { if ((datum.length > 2)) { return collect_param_binders(datum[1], macro_params).forEach(add_unique); } })();
datum_cdr(datum).forEach(walk);
return null; })() : ((head === "defn")) ? (() => { (() => { if ((datum.length > 3)) { (() => { const name_item = datum[1]; return (() => { if (((typeof name_item === 'string') && (!macro_params.includes(name_item)))) { return add_unique(name_item); } })(); })();
return collect_param_binders(datum[2], macro_params).forEach(add_unique); } })();
datum_cdr(datum).forEach(walk);
return null; })() : (() => { datum.forEach(walk);
return null; })(); })(); } })(); } walk(template);
return binders; })(); })();
}

function rename_in_template(template, renames) {
  return (((typeof template === 'string') && (!(renames[template] == null)))) ? renames[template] : ((datum_pair_p(template) && (datum_car(template) === "quote"))) ? template : (datum_pair_p(template)) ? template.map((item) => rename_in_template(item, renames)) : template;
}

function hygienize_template(template, fixed_params, rest_param) {
  return (() => { const macro_params = ((rest_param == null) ? fixed_params : [rest_param].concat(fixed_params)); const binders = collect_template_binders(template, macro_params); return ((binders.length === 0) ? template : (() => { const renames = {}; binders.forEach((b) => (renames[b] = Symbol(b)));
return rename_in_template(template, renames); })()); })();
}

function expand_template_macro(m, name, args) {
  return (() => { const fixed = m["fixed-params"]; const rest_name = m["rest-param"]; const template = ((m["kind"] === "safe") ? hygienize_template(m["template"], fixed, rest_name) : m["template"]); return ((!(rest_name == null)) ? (() => { const fixed_args = args.slice(0, fixed.length); const rest_args = args.slice(fixed.length); const bindings = make_bindings(fixed, fixed_args, rest_name, rest_args); return substitute(template, bindings, rest_name); })() : (() => { const bindings = make_bindings(fixed, args, null, []); return substitute(template, bindings, null); })()); })();
}

function expand_macro(reg, name, args, ctx) {
  return (() => { const m = lookup_macro(reg, name); return ((m == null) ? (() => { process.stderr.write(("".concat("beagle: no macro named ", name, "\n")));
return datum_cons(name, args); })() : expand_template_macro(m, name, args)); })();
}

function macro_application_p(reg, datum) {
  return (datum_pair_p(datum) && (typeof datum_car(datum) === 'string') && (!(lookup_macro(reg, datum_car(datum)) == null)));
}

function expand_fully(reg, datum, depth, ctx) {
  return ((depth >= MAX_EXPANSION_DEPTH)) ? (() => { const chain = ((ctx == null) ? "" : ("".concat("\n", format_expansion_chain(ctx)))); process.stderr.write(("".concat("beagle: macro expansion exceeded depth ", ("".concat(MAX_EXPANSION_DEPTH)), chain, "\n")));
return datum; })() : (macro_application_p(reg, datum)) ? (() => { const name = datum_car(datum); const next_ctx = ((ctx == null) ? make_root_ctx(name) : push_ctx(ctx, name)); const m = lookup_macro(reg, name); const expanded = expand_macro(reg, name, datum_cdr(datum), next_ctx); return ((m["kind"] === "unsafe") ? ["unsafe-expr", expand_fully_no_marker(reg, expanded, (depth + 1), next_ctx)] : expand_fully(reg, expanded, (depth + 1), next_ctx)); })() : (datum_pair_p(datum)) ? datum.map((item) => expand_fully(reg, item, depth, ctx)) : datum;
}

function expand_fully_no_marker(reg, datum, depth, ctx) {
  return ((depth >= MAX_EXPANSION_DEPTH)) ? (() => { const chain = ((ctx == null) ? "" : ("".concat("\n", format_expansion_chain(ctx)))); process.stderr.write(("".concat("beagle: macro expansion exceeded depth ", ("".concat(MAX_EXPANSION_DEPTH)), chain, "\n")));
return datum; })() : (macro_application_p(reg, datum)) ? (() => { const name = datum_car(datum); const next_ctx = ((ctx == null) ? make_root_ctx(name) : push_ctx(ctx, name)); const expanded = expand_macro(reg, name, datum_cdr(datum), next_ctx); return expand_fully_no_marker(reg, expanded, (depth + 1), next_ctx); })() : (datum_pair_p(datum)) ? datum.map((item) => expand_fully_no_marker(reg, item, depth, ctx)) : datum;
}

const passes = [];

const failures = [];

function check(label, result) {
  return (result ? (() => { passes.push(true);
return null; })() : (() => { failures.push(label);
return null; })());
}

function json_eq(a, b) {
  return (JSON.stringify(a) === JSON.stringify(b));
}

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "inc1", "safe", ["x"], ["+", "x", 1]);
return (() => { const result = expand_macro(reg, "inc1", [5], null); return check("simple substitution: (inc1 5) → (+ 5 1)", json_eq(result, ["+", 5, 1])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "add", "safe", ["a", "b"], ["+", "a", "b"]);
return (() => { const result = expand_macro(reg, "add", [3, 4], null); return check("multi-param: (add 3 4) → (+ 3 4)", json_eq(result, ["+", 3, 4])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "square", "safe", ["x"], ["*", "x", "x"]);
return (() => { const result = expand_macro(reg, "square", [7], null); return check("nested: (square 7) → (* 7 7)", json_eq(result, ["*", 7, 7])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "wrap-do", "safe", ["head", "&", "body"], ["do", "head", [SPLICE_MARKER, "body"]]);
return (() => { const result = expand_macro(reg, "wrap-do", ["a", "b", "c"], null); return check("variadic splice: (wrap-do a b c) → (do a b c)", json_eq(result, ["do", "a", "b", "c"])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "wrap-vec", "safe", ["head", "&", "rest"], ["list", "head", "rest"]);
return (() => { const result = expand_macro(reg, "wrap-vec", ["a", "b", "c"], null); return check("rest as vec: (wrap-vec a b c) → (list a [#%brackets b c])", json_eq(result, ["list", "a", [BRACKET_TAG, "b", "c"]])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "raw", "unsafe", ["form"], ["do", ["println", "trace"], "form"]);
return (() => { const result = expand_macro(reg, "raw", [["+ ", 1, 2]], null); return check("unsafe substitution", json_eq(result, ["do", ["println", "trace"], ["+ ", 1, 2]])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "with-tmp", "safe", ["body"], ["let", ["tmp", 0], "body"]);
return (() => { const result = expand_macro(reg, "with-tmp", [["println", "tmp"]], null); const binds = result[1]; const bind_name = binds[0]; check("hygiene: let result is let form", (result[0] === "let"));
check("hygiene: let binder renamed from tmp", (bind_name !== "tmp"));
return check("hygiene: user ref to tmp preserved", json_eq(result[2], ["println", "tmp"])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "with-fn", "safe", ["body"], ["fn", ["x"], "body"]);
return (() => { const result = expand_macro(reg, "with-fn", [["println", "x"]], null); const params = result[1]; const param_name = params[0]; check("hygiene: fn result is fn form", (result[0] === "fn"));
check("hygiene: fn param renamed from x", (param_name !== "x"));
return check("hygiene: user ref to x preserved", json_eq(result[2], ["println", "x"])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "inc1", "unsafe", ["x"], ["+", "x", 1]);
register_macro_bang(reg, "inc2", "unsafe", ["x"], ["inc1", ["inc1", "x"]]);
return (() => { const result = expand_fully(reg, ["inc2", 5], 0, null); return check("recursive expansion: (inc2 5) → (unsafe-expr (+ (+ 5 1) 1))", json_eq(result, ["unsafe-expr", ["+", ["+", 5, 1], 1]])); })(); })();

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "inc1", "unsafe", ["x"], ["+", "x", 1]);
return (() => { const result = expand_fully(reg, ["println", ["inc1", 5]], 0, null); return check("expand-fully: non-macro forms preserved", json_eq(result, ["println", ["unsafe-expr", ["+", 5, 1]]])); })(); })();

check("contract: Symbol accepts string", check_datum_contract("x", "Symbol", "test", "arg"));

check("contract: Symbol rejects number", (!check_datum_contract(42, "Symbol", "test", "arg")));

check("contract: Form accepts list with symbol head", check_datum_contract(["defn", "foo"], "Form", "test", "arg"));

check("contract: Form rejects non-list", (!check_datum_contract(42, "Form", "test", "arg")));

check("contract: Syntax accepts anything", check_datum_contract(42, "Syntax", "test", "arg"));

check("strip: bracket tag removed", json_eq(strip_reader_tags([BRACKET_TAG, "a", "b"]), ["a", "b"]));

check("strip: map tag → hash", json_eq(strip_reader_tags([MAP_TAG, "k", "v"]), ["hash", "k", "v"]));

check("strip: set tag → set", json_eq(strip_reader_tags([SET_TAG, "a"]), ["set", "a"]));

check("strip: nested", json_eq(strip_reader_tags(["fn", [BRACKET_TAG, "x"], [MAP_TAG, "k", "x"]]), ["fn", ["x"], ["hash", "k", "x"]]));

check("strip: quote preserved", json_eq(strip_reader_tags(["quote", [BRACKET_TAG, "a"]]), ["quote", [BRACKET_TAG, "a"]]));

(() => { const reg = make_macro_registry(); register_macro_bang(reg, "inc1", "safe", ["x"], ["+", "x", 1]);
check("macro-app?: true for registered", macro_application_p(reg, ["inc1", 5]));
check("macro-app?: false for unknown", (!macro_application_p(reg, ["unknown", 5])));
return check("macro-app?: false for non-pair", (!macro_application_p(reg, "atom"))); })();

failures.forEach((f) => process.stderr.write(("".concat("  FAIL: ", f, "\n"))));

process.stdout.write(("".concat("  MACROS: ", ("".concat(passes.length)), " passed, ", ("".concat(failures.length)), " failed\n")));

(() => { if ((failures.length > 0)) { return process.exit(1); } })();

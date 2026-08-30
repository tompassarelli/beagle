import { equivV as $$bc$equiv, map_indexed as $$bc$map_indexed } from 'beagle/core.js';
import { aset as $$bh$aset, js_obj as $$bh$js_obj } from 'beagle/host.js';

function delimiter_p(ch) {
  return (($$bc$equiv(ch, " ")) || ($$bc$equiv(ch, "\n")) || ($$bc$equiv(ch, "\r")) || ($$bc$equiv(ch, "\t")) || ($$bc$equiv(ch, ",")) || ($$bc$equiv(ch, "[")) || ($$bc$equiv(ch, "]")) || ($$bc$equiv(ch, "{")) || ($$bc$equiv(ch, "}")) || ($$bc$equiv(ch, "(")) || ($$bc$equiv(ch, ")")));
}

function token_end(text, start) {
  return (() => { let index = start; while (true) {
    if (((index >= text.length) || delimiter_p(text.substring(index, (index + 1))))) { return index; } else { const _recur_0 = (index + 1); index = _recur_0; continue; }
  } })();
}

function edn_whitespace_p(ch) {
  return (($$bc$equiv(ch, " ")) || ($$bc$equiv(ch, "\n")) || ($$bc$equiv(ch, "\r")) || ($$bc$equiv(ch, "\t")) || ($$bc$equiv(ch, ",")));
}

function quoted_token_end(text, start) {
  return (() => { let index = (start + 1); let escaped = false; while (true) {
    if ((index >= text.length)) { return index; } else { const ch = text.substring(index, (index + 1)); if (escaped) { const _recur_0 = (index + 1); const _recur_1 = false; index = _recur_0; escaped = _recur_1; continue; } else if (($$bc$equiv(ch, "\\"))) { const _recur_0 = (index + 1); const _recur_1 = true; index = _recur_0; escaped = _recur_1; continue; } else if (($$bc$equiv(ch, "\""))) { return (index + 1); } else { const _recur_0 = (index + 1); const _recur_1 = false; index = _recur_0; escaped = _recur_1; continue; } }
  } })();
}

function item_start(stack) {
  if (($$bc$equiv(0, stack.length))) {
    return ["", stack, false];
  } else {
    const last_index = (stack.length - 1);
    const state = stack[last_index];
    const parent = stack.slice(0, last_index);
    return ((($$bc$equiv(state, "array-first"))) ? ["", [...parent, "array-next"], false] : (($$bc$equiv(state, "array-next"))) ? [",", stack, false] : (($$bc$equiv(state, "map-first"))) ? ["", [...parent, "map-value"], true] : (($$bc$equiv(state, "map-next"))) ? [",", [...parent, "map-value"], true] : (($$bc$equiv(state, "map-value"))) ? ["", [...parent, "map-next"], false] : ["", stack, false]);
  }
}

function close_container(stack) {
  return (($$bc$equiv(0, stack.length)) ? stack : stack.slice(0, (stack.length - 1)));
}

function edn_json(text, term_mode) {
  return (() => { let index = 0; let output = ""; let stack = []; while (true) {
    if ((index >= text.length)) { return output; } else { const ch = text.substring(index, (index + 1)); if (edn_whitespace_p(ch)) { const _recur_0 = (index + 1); const _recur_1 = output; const _recur_2 = stack; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if (($$bc$equiv(ch, "{"))) { const started = item_start(stack); const _recur_0 = (index + 1); const _recur_1 = ("".concat(output, started[0], "{")); const _recur_2 = [...started[1], "map-first"]; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if (($$bc$equiv(ch, "}"))) { const _recur_0 = (index + 1); const _recur_1 = ("".concat(output, "}")); const _recur_2 = close_container(stack); index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if ((($$bc$equiv(ch, "[")) || ($$bc$equiv(ch, "(")))) { const started = item_start(stack); const _recur_0 = (index + 1); const _recur_1 = ("".concat(output, started[0], "[")); const _recur_2 = [...started[1], "array-first"]; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if ((($$bc$equiv(ch, "]")) || ($$bc$equiv(ch, ")")))) { const _recur_0 = (index + 1); const _recur_1 = ("".concat(output, "]")); const _recur_2 = close_container(stack); index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if (($$bc$equiv(ch, "\""))) { const end = quoted_token_end(text, index); const started = item_start(stack); const _recur_0 = end; const _recur_1 = ("".concat(output, started[0], text.substring(index, end), (started[2] ? ":" : ""))); const _recur_2 = started[1]; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if (($$bc$equiv(ch, ":"))) { const end = token_end(text, (index + 1)); const token = text.substring((index + 1), end); const value = (term_mode ? ("".concat("$kw:", token)) : token); const started = item_start(stack); const _recur_0 = end; const _recur_1 = ("".concat(output, started[0], JSON.stringify(value), (started[2] ? ":" : ""))); const _recur_2 = started[1]; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else if ((!delimiter_p(ch))) { const end = token_end(text, index); const token = text.substring(index, end); const value = (term_mode ? JSON.stringify(("".concat("$atom:", token))) : token); const started = item_start(stack); const _recur_0 = end; const _recur_1 = ("".concat(output, started[0], value, (started[2] ? ":" : ""))); const _recur_2 = started[1]; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } else { const _recur_0 = (index + 1); const _recur_1 = ("".concat(output, ch)); const _recur_2 = stack; index = _recur_0; output = _recur_1; stack = _recur_2; continue; } }
  } })();
}

function structural_query_keyword_p(context) {
  return (($$bc$equiv(context, "find")) || ($$bc$equiv(context, "rel")) || ($$bc$equiv(context, "var")) || ($$bc$equiv(context, "pred")) || ($$bc$equiv(context, "fn")) || ($$bc$equiv(context, "op")) || ($$bc$equiv(context, "direction")));
}

function query_value(bridge, value, context) {
  return (((typeof value === 'string')) ? ((($$bc$equiv("$kw:", value.substring(0, 4)))) ? (() => { const spelling = value.substring(4); return (structural_query_keyword_p(context) ? spelling : bridge.keywordTerm(spelling)); })() : (($$bc$equiv("$atom:", value.substring(0, 6)))) ? (() => { const token = value.substring(6); return ((($$bc$equiv(token, "true"))) ? true : (($$bc$equiv(token, "false"))) ? false : (($$bc$equiv(token, "nil"))) ? null : (((() => { const _r = /-?[0-9]+/, _f = _r.flags.replace(/[gy]/g, "") + (_r.flags.includes("u") ? "" : "u"), _m = token.match(new RegExp("^(?:" + _r.source + ")$", _f)); return _m == null ? null : (_m.length === 1 ? _m[0] : Array.from(_m, _x => _x ?? null)); })() != null)) ? bridge.integerValue(bridge.integerTerm(token)) : (((() => { const _r = /-?(?:[0-9]+\.[0-9]*|[0-9]*\.[0-9]+)(?:[eE][+-]?[0-9]+)?/, _f = _r.flags.replace(/[gy]/g, "") + (_r.flags.includes("u") ? "" : "u"), _m = token.match(new RegExp("^(?:" + _r.source + ")$", _f)); return _m == null ? null : (_m.length === 1 ? _m[0] : Array.from(_m, _x => _x ?? null)); })() != null)) ? Number.parseFloat(token) : token); })() : value) : (Array.isArray(value)) ? value.map((item) => query_value(bridge, item, context)) : ((() => { const _x = value; return typeof _x === 'object' && _x !== null && !Array.isArray(_x); })()) ? (() => { const result = $$bh$js_obj(); (() => { Object.entries(value).forEach((entry) => {
  const raw_key = entry[0];
  const key = (($$bc$equiv("$kw:", raw_key.substring(0, 4))) ? raw_key.substring(4) : raw_key);
  $$bh$aset(result, key, query_value(bridge, entry[1], key));
}); })();
return result; })() : value);
}

function parse_query(bridge, text) {
  return query_value(bridge, JSON.parse((((text.length > 1) && ($$bc$equiv("\"", text.substring(1, 2)))) ? text : edn_json(text, true))), "");
}

function atom_term(bridge, token) {
  return ((($$bc$equiv(token, "true"))) ? bridge.booleanTerm(true) : (($$bc$equiv(token, "false"))) ? bridge.booleanTerm(false) : (((() => { const _r = /-?[0-9]+/, _f = _r.flags.replace(/[gy]/g, "") + (_r.flags.includes("u") ? "" : "u"), _m = token.match(new RegExp("^(?:" + _r.source + ")$", _f)); return _m == null ? null : (_m.length === 1 ? _m[0] : Array.from(_m, _x => _x ?? null)); })() != null)) ? bridge.integerTerm(token) : (((() => { const _r = /-?(?:[0-9]+\.[0-9]*|[0-9]*\.[0-9]+)(?:[eE][+-]?[0-9]+)?/, _f = _r.flags.replace(/[gy]/g, "") + (_r.flags.includes("u") ? "" : "u"), _m = token.match(new RegExp("^(?:" + _r.source + ")$", _f)); return _m == null ? null : (_m.length === 1 ? _m[0] : Array.from(_m, _x => _x ?? null)); })() != null)) ? bridge.floatTerm(token) : bridge.stringTerm(token));
}

function parsed_term(bridge, value) {
  return (((typeof value === 'string')) ? ((($$bc$equiv("$kw:", value.substring(0, 4)))) ? bridge.keywordTerm(value.substring(4)) : (($$bc$equiv("$atom:", value.substring(0, 6)))) ? atom_term(bridge, value.substring(6)) : bridge.stringTerm(value)) : (Array.isArray(value)) ? (($$bc$equiv(3, value.length)) ? bridge.tripleTerm(parsed_term(bridge, value[0]), parsed_term(bridge, value[1]), parsed_term(bridge, value[2])) : bridge.fail("term vector must contain exactly three values")) : ((() => { const _x = value; return typeof _x === 'object' && _x !== null && !Array.isArray(_x); })()) ? (() => { const instant = host_get(value, "$kw:instant"); return ((Array.isArray(instant) && ($$bc$equiv(2, instant.length))) ? bridge.instantTerm(instant[0].substring(6), instant[1].substring(6)) : bridge.fail("term map must be {:instant [SECONDS NANOS]}")); })() : bridge.fail("unsupported human term"));
}

function parse_term(bridge, text) {
  return parsed_term(bridge, JSON.parse(edn_json(text, true)));
}

function parse_subject(bridge, text) {
  return parse_term(bridge, ((($$bc$equiv("@", text.substring(0, 1))) || ($$bc$equiv("[", text.substring(0, 1))) || ($$bc$equiv("{", text.substring(0, 1))) || ($$bc$equiv("\"", text.substring(0, 1))) || ($$bc$equiv(":", text.substring(0, 1)))) ? text : ("".concat("@", text))));
}

function render_term(bridge, value) {
  const tag = host_get(value, 0);
  return ((($$bc$equiv(tag, "string"))) ? host_get(value, 1) : (($$bc$equiv(tag, "integer"))) ? host_get(value, 1) : (($$bc$equiv(tag, "float64"))) ? ("".concat(bridge.floatValue(value))) : (($$bc$equiv(tag, "boolean"))) ? (host_get(value, 1) ? "true" : "false") : (($$bc$equiv(tag, "keyword"))) ? ("".concat(":", host_get(value, 1))) : (($$bc$equiv(tag, "instant"))) ? ("".concat("{:instant [", host_get(value, 1), " ", host_get(value, 2), "]}")) : (($$bc$equiv(tag, "triple"))) ? ("".concat("[", render_term(bridge, host_get(value, 1)), " ", render_term(bridge, host_get(value, 2)), " ", render_term(bridge, host_get(value, 3)), "]")) : bridge.fail(("".concat("unknown Term tag ", tag))));
}

function render_row(bridge, row) {
  return ("".concat("[", ((..._xs) => "".concat(..._xs))(...$$bc$map_indexed((index, value) => ("".concat((($$bc$equiv(index, 0)) ? "" : " "), render_term(bridge, value))), row)), "]"));
}

function require_count(bridge, arguments$, expected, usage) {
  if ((!($$bc$equiv(expected, arguments$.length)))) {
    return bridge.fail(usage);
  }
}

function scan_pattern(bridge, arguments$) {
  const pattern = $$bh$js_obj();
  if ((!($$bc$equiv("_", arguments$[0])))) {
    $$bh$aset(pattern, "t1", parse_term(bridge, arguments$[0]));
  }
  if ((!($$bc$equiv("_", arguments$[1])))) {
    $$bh$aset(pattern, "t2", parse_term(bridge, arguments$[1]));
  }
  if ((!($$bc$equiv("_", arguments$[2])))) {
    $$bh$aset(pattern, "t3", parse_term(bridge, arguments$[2]));
  }
  return pattern;
}

async function call(bridge, operation, arguments$) {
  return await host_call(bridge, operation, arguments$);
}

async function write_command(bridge, command, arguments$) {
  require_count(bridge, arguments$, 3, "usage: store tell|retract SUBJECT SLOT VALUE");
  const asserting = (($$bc$equiv(command, "tell")) || ($$bc$equiv(command, "tell-existing")));
  const existing = (($$bc$equiv(command, "tell-existing")) || ($$bc$equiv(command, "retract-existing")));
  const base = await call(bridge, "version", null);
  const request = $$bh$js_obj("t1", parse_subject(bridge, arguments$[0]), "t2", parse_term(bridge, arguments$[1]), "t3", parse_term(bridge, arguments$[2]), "existing", existing, "expectedVersion", host_get(base, "servedVersion"));
  const response = await call(bridge, (asserting ? "assert" : "retract"), request);
  const result = host_get(response, "result")[0];
  const proposition = $$bh$js_obj("subject", host_get(request, "t1"), "predicate", host_get(request, "t2"), "value", host_get(request, "t3"));
  bridge.out(("".concat((host_get(result, "stateChanged") ? "committed" : "no change"), " via server (v", host_get(response, "servedVersion"), "): ", render_term(bridge, host_get(proposition, "subject")), " ", render_term(bridge, host_get(proposition, "predicate")), " = ", render_term(bridge, host_get(proposition, "value")), " [input 0, occurrence ", render_term(bridge, host_get(result, "occurrence")), "]")));
  return 0;
}

function normalized_argv(argv) {
  return (((argv.length > 0) && ($$bc$equiv("store", argv[0]))) ? Array.from(argv.slice(1)) : argv);
}

async function run(bridge, raw_argv) {
  const argv = normalized_argv(raw_argv);
  const command = ((argv.length === 0) ? "" : argv[0]);
  const arguments$ = Array.from(argv.slice(1));
  return ((($$bc$equiv(command, "version"))) ? (async () => { require_count(bridge, arguments$, 0, "usage: store version");
bridge.out(("".concat(host_get(await call(bridge, "version", null), "servedVersion"))));
return 0; })() : (($$bc$equiv(command, "status"))) ? (async () => { require_count(bridge, arguments$, 0, "usage: store status");
const response = await call(bridge, "status", null);
const result = host_get(response, "result");
bridge.out(("".concat("up|", host_get(response, "servedVersion"), "|", host_get(result, "liveCount"), "|", host_get(result, "state"), "|", host_get(result, "engine"))));
return 0; })() : (($$bc$equiv(command, "validate"))) ? (async () => { require_count(bridge, arguments$, 0, "usage: store validate");
const response = await call(bridge, "validate", null);
const result = host_get(response, "result");
(() => { host_get(result, "violations").forEach((violation) => {
  bridge.out(("".concat((host_get(result, "valid") ? "advisory: " : "violation: "), render_term(bridge, violation))));
}); })();
if (host_get(result, "valid")) {
  bridge.out("valid");
  return 0;
} else {
  return 1;
} })() : (($$bc$equiv(command, "show"))) ? (async () => { require_count(bridge, arguments$, 1, "usage: store show SUBJECT");
const subject = parse_subject(bridge, arguments$[0]);
const response = await call(bridge, "scan", $$bh$js_obj("t1", subject));
const triples = host_get(response, "result");
if ((triples.length === 0)) {
  bridge.out(("".concat("no triples for ", render_term(bridge, subject))));
} else {
  (() => { triples.forEach((triple) => {
  bridge.out(("".concat("  ", render_term(bridge, host_get(triple, 2)), "  ", render_term(bridge, host_get(triple, 3)))));
}); })();
}
return 0; })() : (($$bc$equiv(command, "query"))) ? (async () => { require_count(bridge, arguments$, 1, "usage: store query EDN-QUERY");
const response = await call(bridge, "query", parse_query(bridge, arguments$[0]));
const rows = host_get(response, "result");
if ((rows.length === 0)) {
  bridge.out("  (no results)");
} else {
  (() => { rows.forEach((row) => {
  bridge.out(("".concat("  ", render_row(bridge, row))));
}); })();
}
return 0; })() : (($$bc$equiv(command, "scan"))) ? (async () => { require_count(bridge, arguments$, 3, "usage: store scan T1|_ T2|_ T3|_");
const response = await call(bridge, "scan", scan_pattern(bridge, arguments$));
(() => { host_get(response, "result").forEach((triple) => {
  bridge.out(render_term(bridge, triple));
}); })();
return 0; })() : (($$bc$equiv(command, "occurrences"))) ? (async () => { require_count(bridge, arguments$, 0, "usage: store occurrences");
return (async () => { let cursor = null; while (true) {
    const response = await call(bridge, "occurrences", cursor); (() => { host_get(response, "result").forEach((occurrence) => {
  bridge.out(("".concat("{:type :occurrence, :coordinate ", render_term(bridge, host_get(occurrence, "coordinate")), ", :action :", host_get(occurrence, "action"), ", :proposition ", render_term(bridge, host_get(occurrence, "proposition")), "}")));
}); })(); if (host_get(host_get(response, "page"), "done")) { return 0; } else { const _recur_0 = host_get(host_get(response, "page"), "nextCursor"); cursor = _recur_0; continue; }
  } })(); })() : ((($$bc$equiv(command, "tell")) || ($$bc$equiv(command, "retract")) || ($$bc$equiv(command, "tell-existing")) || ($$bc$equiv(command, "retract-existing")))) ? await write_command(bridge, command, arguments$) : bridge.fail(("".concat("unsupported data command: ", command))));
}
export { run as "run" };

function classify_error(error) {
  const name = host_error_field(error, "name");
  const code = host_error_field(error, "code");
  return ((($$bc$equiv(code, "rpc/subject-not-found"))) ? 3 : (($$bc$equiv(name, "StoreTransportError"))) ? 4 : ((($$bc$equiv(name, "StoreProtocolError")) && (!(($$bc$equiv(code, "client/invalid-input")) || ($$bc$equiv(code, "client/invalid-integer")) || ($$bc$equiv(code, "client/integer-range")) || ($$bc$equiv(code, "client/invalid-term")) || ($$bc$equiv(code, "client/invalid-keyword")) || ($$bc$equiv(code, "client/invalid-float")) || ($$bc$equiv(code, "client/query-syntax")) || ($$bc$equiv(code, "client/invalid-host")) || ($$bc$equiv(code, "client/invalid-port")))))) ? 4 : 1);
}
export { classify_error as "classify-error" };

function error_message(error) {
  const message = host_error_field(error, "message");
  return (($$bc$equiv(message, "")) ? ("".concat(error)) : message);
}
export { error_message as "error-message" };

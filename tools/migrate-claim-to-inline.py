#!/usr/bin/env python3
"""Migrate (claim NAME T) + (def NAME V) pairs to inline (def NAME :- T V).

Patterns handled (per file, scanning top-level forms):

  (claim NAME T)
  (def NAME V)
  →
  (def NAME :- T V)

  (claim NAME [T1 T2 ... -> R])     ; bracketed function type
  (defn NAME [params...] BODY...)
  →
  (defn NAME [params... with types folded in] :- R BODY...)

  (claim NAME (-> T1 T2 ... R))    ; paren arrow function type
  (defn NAME ...)
  →  same as above.

  (claim NAME [-> R])              ; no-arg function
  (defn NAME [] BODY...)
  →
  (defn NAME [] :- R BODY...)

Defn param-folding policy:
  Defn params that are already in wrapped `(name : T)` form retain that
  form (still parseable as a typed param). The claim's per-param type
  fills in for bare-named params; if both sides give a type, the existing
  defn-side annotation wins (it's the more local fact).

Both .bclj and .bcljs are handled identically. .rkt test files are also
swept for `'(claim NAME T)`/`'(def NAME V)` paired-quoted forms.
"""

import re
import sys
import os
import glob

# ----------------- paren-balanced extractor -----------------

def read_form_at(text, i):
    """If text[i] == '(' or '[', return (form_string, j) where j is index
    after the form. Else returns (None, i)."""
    if i >= len(text):
        return None, i
    c = text[i]
    if c not in '([':
        return None, i
    close = ')' if c == '(' else ']'
    depth = 0
    j = i
    in_str = False
    while j < len(text):
        ch = text[j]
        if in_str:
            if ch == '\\':
                j += 2
                continue
            if ch == '"':
                in_str = False
            j += 1
            continue
        if ch == '"':
            in_str = True
            j += 1
            continue
        if ch == ';':
            # consume to EOL
            while j < len(text) and text[j] != '\n':
                j += 1
            continue
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
            if depth == 0:
                return text[i:j+1], j+1
        j += 1
    raise ValueError(f"unterminated form starting at {i}")

# ----------------- s-expr lite parser -----------------

# Lightweight, just enough for our needs. Returns nested lists where
# atoms are raw strings preserving their source text. The first-class
# value is a string for atom, or a tuple (open_char, items) for a list.

def tokenize(src):
    """Yields ('open', '(' | '['), ('close', ')' | ']'), or ('atom', str)."""
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        if c == ';':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c in '([':
            yield ('open', c); i += 1; continue
        if c in ')]':
            yield ('close', c); i += 1; continue
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2; continue
                if src[j] == '"':
                    j += 1; break
                j += 1
            yield ('atom', src[i:j]); i = j; continue
        # atom: read non-whitespace non-bracket non-semicolon
        j = i
        while j < n and not src[j].isspace() and src[j] not in '()[];"':
            j += 1
        yield ('atom', src[i:j]); i = j

def parse_form(src):
    toks = list(tokenize(src))
    pos = [0]
    def parse():
        kind, val = toks[pos[0]]
        pos[0] += 1
        if kind == 'atom':
            return val
        if kind == 'open':
            items = []
            while True:
                k2, v2 = toks[pos[0]]
                if k2 == 'close':
                    pos[0] += 1
                    return (val, items)
                items.append(parse())
        raise ValueError(f"unexpected: {kind} {val}")
    result = parse()
    return result

def tokenize_with_pos(src):
    """Like tokenize but yields (kind, value, start, end)."""
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1; continue
        if c == ';':
            while i < n and src[i] != '\n': i += 1
            continue
        if c in '([':
            yield ('open', c, i, i+1); i += 1; continue
        if c in ')]':
            yield ('close', c, i, i+1); i += 1; continue
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '\\': j += 2; continue
                if src[j] == '"': j += 1; break
                j += 1
            yield ('atom', src[i:j], i, j); i = j; continue
        j = i
        while j < n and not src[j].isspace() and src[j] not in '()[];"':
            j += 1
        yield ('atom', src[i:j], i, j); i = j

def parse_form_with_spans(src):
    """Parse and return tree where each node is either a str atom (no
    span) or a tuple ('list', open_char, items, src_start, src_end).
    Atoms are bare strings."""
    toks = list(tokenize_with_pos(src))
    pos = [0]
    def parse():
        kind, val, s, e = toks[pos[0]]
        pos[0] += 1
        if kind == 'atom':
            return val
        if kind == 'open':
            start = s
            items = []
            while True:
                k2, v2, s2, e2 = toks[pos[0]]
                if k2 == 'close':
                    pos[0] += 1
                    return ('list', val, items, start, e2)
                items.append(parse())
        raise ValueError(f"unexpected: {kind} {val}")
    return parse()

def is_list(node):
    return isinstance(node, tuple)

def list_items(node):
    return node[1]

def list_open(node):
    return node[0]

def atom_eq(node, s):
    return isinstance(node, str) and node == s

# ----------------- type extractor -----------------

def is_arrow_type(node):
    """Return list of param-types and return-type if node is a function type.
    Forms: [T1 T2 ... -> R]  or  (-> T1 T2 ... R)
    Returns (param_types, return_type) or None."""
    if not is_list(node):
        return None
    items = list_items(node)
    if list_open(node) == '[':
        # [T1 T2 -> R] : find '->' separator
        try:
            arrow_idx = next(i for i, x in enumerate(items) if x == '->')
        except StopIteration:
            return None
        param_types = items[:arrow_idx]
        ret_items = items[arrow_idx+1:]
        if len(ret_items) != 1:
            return None
        return (param_types, ret_items[0])
    if list_open(node) == '(':
        if len(items) >= 2 and items[0] == '->':
            rest = items[1:]
            return (rest[:-1], rest[-1])
    return None

def unparse(node):
    if isinstance(node, str):
        return node
    open_c, items = node
    close_c = ')' if open_c == '(' else ']'
    return open_c + ' '.join(unparse(x) for x in items) + close_c

# ----------------- defn param manipulation -----------------

def fold_param_types(params_node, claim_param_types):
    """Given a params list (open='[' or '(', items=...) and a list of types
    from the claim arrow, produce a new params list with types folded in.

    Strategy:
      For each (param, type) zipped:
        - If param is already a typed wrapped form `(name : T)`, leave alone.
        - If param is a typed wrapped form `(name :- T)`, leave alone.
        - If param is a bare-name string AND we have a claim type, rewrite
          to `(name :- T)` form.
    If lengths differ, give up and return None (caller falls back).
    """
    if not is_list(params_node):
        return None
    items = list_items(params_node)
    if len(items) != len(claim_param_types):
        return None
    new_items = []
    for p, t in zip(items, claim_param_types):
        if isinstance(p, str):
            # bare name → wrap with :-
            new_items.append(('(', [p, ':-', t]))
        else:
            # already structured — leave (it has its own annotation)
            new_items.append(p)
    return (list_open(params_node), new_items)

# ----------------- migration core -----------------

def find_top_forms(text):
    """Yield (start, end, form_string) for each top-level (...) form."""
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1; continue
        if c == ';':
            while i < n and text[i] != '\n': i += 1
            continue
        if c == '#' and i+1 < n and text[i+1] == 'l':
            # #lang line — skip to EOL
            while i < n and text[i] != '\n': i += 1
            continue
        if c in '([':
            form, j = read_form_at(text, i)
            yield (i, j, form)
            i = j
            continue
        # stray atom — skip
        i += 1

def claim_info(form_str):
    """If form is `(claim NAME TYPE)`, return (name, type_node_str)."""
    try:
        node = parse_form(form_str)
    except Exception:
        return None
    if not is_list(node): return None
    items = list_items(node)
    if len(items) != 3: return None
    if not atom_eq(items[0], 'claim'): return None
    if not isinstance(items[1], str): return None
    return items[1], items[2]  # name, type-node

def def_info(form_str):
    try:
        node = parse_form(form_str)
    except Exception:
        return None
    if not is_list(node): return None
    items = list_items(node)
    if len(items) < 1: return None
    head = items[0]
    if head == 'def' and len(items) == 3 and isinstance(items[1], str):
        return ('def', items[1], items[2])
    if head == 'defn' and len(items) >= 3 and isinstance(items[1], str):
        # (defn NAME PARAMS BODY...)
        return ('defn', items[1], items[2:])
    return None

def rebuild_def(name, type_node, value_node):
    """(def NAME :- T V) with original source text where possible."""
    t = unparse(type_node) if not isinstance(type_node, str) else type_node
    v = unparse(value_node) if not isinstance(value_node, str) else value_node
    return f"(def {name} :- {t} {v})"

def rebuild_defn(name, type_node, params_node, body_nodes):
    """(defn NAME [params w/types folded] :- R BODY...)"""
    arrow = is_arrow_type(type_node)
    if arrow is None:
        # Non-arrow claim with defn? Pathological. Skip.
        return None
    claim_param_types, return_type = arrow
    new_params = fold_param_types(params_node, claim_param_types)
    if new_params is None:
        # Length mismatch — leave params alone, just append return type.
        new_params = params_node
    body_text = ' '.join(unparse(b) for b in body_nodes)
    ret = unparse(return_type) if not isinstance(return_type, str) else return_type
    return f"(defn {name} {unparse(new_params)} :- {ret} {body_text})"

# ----------------- surgical defn patcher -----------------

def patch_defn_in_source(defn_src, claim_type_node):
    """Given the source of a (defn NAME PARAMS BODY...) form and a claim's
    type node, produce the modified source string with:
      - return-type `:- R` inserted right after the params closing bracket
      - param-types folded into bare-name params (only when params are on
        one line and rewriting is mechanical).

    For param folding we keep the original params text and patch in-place.
    """
    # tokenize-with-pos against defn_src to find:
    #   open of defn list, NAME atom, params list span
    toks = list(tokenize_with_pos(defn_src))
    # walk: expect ('open','('), ('atom','defn'), ('atom',name), then params open...
    if not toks:
        return None
    # Find the params node: it is the 3rd subform (index 2 if we count
    # tokens at depth 1).
    # Easier path: parse fully and use spans.
    tree = parse_form_with_spans(defn_src)
    if not (isinstance(tree, tuple) and tree[0] == 'list'):
        return None
    _, _, items, _, _ = tree
    if len(items) < 3:
        return None
    if items[0] != 'defn':
        return None
    name = items[1]
    params = items[2]
    if not (isinstance(params, tuple) and params[0] == 'list'):
        return None
    _, p_open, p_items, p_start, p_end = params

    arrow = is_arrow_type(_strip_spans(params))  # not arrow
    # Compute arrow types from claim:
    arrow = is_arrow_type(claim_type_node)
    if arrow is None:
        return None
    claim_param_types, return_type = arrow

    # Build new params text by walking the original items:
    new_params_text = build_new_params(defn_src, p_open, p_items, p_start, p_end,
                                       claim_param_types)
    # Append return type after the params:
    ret_text = unparse(return_type) if not isinstance(return_type, str) else return_type

    # Compose: defn_src[:start_of_defn] -- but we want to rebuild from scratch
    # the prefix up through params, then insert :- R, then the original body.
    # Use spans:
    #   - keep "(defn NAME " prefix exactly: from form-start through end of NAME atom + whitespace before params open
    #   - replace params span with new_params_text
    #   - insert " :- RET" after params
    #   - keep body verbatim
    form_start = tree[3]
    form_end = tree[4]
    # Find end-of-name token to know where to start params region. Use spans:
    name_tok = None
    for t in toks:
        if t[0] == 'atom' and t[1] == name:
            name_tok = t; break
    if name_tok is None:
        return None
    _, _, _, name_end = name_tok

    prefix = defn_src[form_start:name_end]   # "(defn handle"
    middle_ws = defn_src[name_end:p_start]   # " " before params open
    suffix_after_params = defn_src[p_end:form_end]  # " (body...)"
    # suffix_after_params starts with the body. We insert :- RET before body.

    return f"{prefix}{middle_ws}{new_params_text} :- {ret_text}{suffix_after_params}"

def _strip_spans(node):
    """Convert span-tree to plain tree (list-of-strings/tuples)."""
    if isinstance(node, str):
        return node
    if isinstance(node, tuple) and node[0] == 'list':
        return (node[1], [_strip_spans(x) for x in node[2]])
    return node

def build_new_params(src, p_open, p_items, p_start, p_end, claim_types):
    """Reconstruct params source with bare-name params wrapped as (name :- T).
    Preserves original whitespace as much as possible by leaving each item's
    original text in place, except bare-name items get rewritten."""
    if len(p_items) != len(claim_types):
        # mismatch: leave as-is
        return src[p_start:p_end]

    # Iterate items. For each item, get its span. If it's a bare-name atom,
    # rewrite the source span to "(name :- T)".
    close_c = ']' if p_open == '[' else ')'
    # Walk: we need atom spans. We have tokens. Let's re-tokenize the
    # params slice.
    inner = src[p_start+1:p_end-1]
    toks_inner = list(tokenize_with_pos(inner))
    # Re-parse to align with p_items count.
    # Simpler approach: walk p_items in order, using a fresh parse to
    # extract each item's span within the inner slice.
    # Build a tree of items with spans by re-parsing.
    # We'll parse the params node fresh from src[p_start:p_end].
    full = src[p_start:p_end]
    tree = parse_form_with_spans(full)
    if not (isinstance(tree, tuple) and tree[0] == 'list'):
        return full
    _, _, items_with_spans, _, _ = tree
    # items_with_spans may be atoms (strings) or list-tuples with spans.
    # We need spans for both. Atoms come back as bare strings — no span.
    # Re-do: walk tokens and pair atoms with their spans.
    toks_full = list(tokenize_with_pos(full))
    # Skip first open and last close.
    parts = []
    # We'll walk the tokens; we need per-item text spans (relative to full).
    pos = [1]  # skip the first '['/'('
    # End is len(full)-1 (closing bracket)
    def read_item_span():
        # returns (start, end) of next item in full, or None if no more
        # consume whitespace/comments
        i = pos[0]
        n = len(full)
        while i < n:
            c = full[i]
            if c.isspace(): i += 1; continue
            if c == ';':
                while i < n and full[i] != '\n': i += 1
                continue
            break
        if i >= n - 1:
            pos[0] = i
            return None
        start = i
        c = full[i]
        if c in '([':
            # parse balanced
            depth = 0
            j = i
            in_str = False
            while j < n:
                ch = full[j]
                if in_str:
                    if ch == '\\': j += 2; continue
                    if ch == '"': in_str = False
                    j += 1; continue
                if ch == '"': in_str = True; j += 1; continue
                if ch == ';':
                    while j < n and full[j] != '\n': j += 1
                    continue
                if ch in '([': depth += 1
                elif ch in ')]':
                    depth -= 1
                    if depth == 0:
                        j += 1
                        pos[0] = j
                        return (start, j)
                j += 1
            return None
        if c == '"':
            j = i + 1
            while j < n:
                if full[j] == '\\': j += 2; continue
                if full[j] == '"': j += 1; break
                j += 1
            pos[0] = j
            return (start, j)
        # atom
        j = i
        while j < n and not full[j].isspace() and full[j] not in '()[];"':
            j += 1
        pos[0] = j
        return (start, j)

    spans = []
    while True:
        sp = read_item_span()
        if sp is None: break
        spans.append(sp)

    if len(spans) != len(claim_types):
        return full

    # Now rebuild:
    out = ['[' if p_open == '[' else '(']
    prev_end = 1   # position after open bracket
    for (s, e), t in zip(spans, claim_types):
        # Preserve whitespace between prev_end and s
        out.append(full[prev_end:s])
        item_src = full[s:e]
        # Decide: is item_src a bare-name atom?
        if _is_bare_symbol(item_src):
            tt = unparse(t) if not isinstance(t, str) else t
            out.append(f"({item_src} :- {tt})")
        else:
            out.append(item_src)
        prev_end = e
    # Preserve any whitespace before closing bracket
    out.append(full[prev_end:len(full)-1])
    out.append(']' if p_open == '[' else ')')
    return ''.join(out)

def _is_bare_symbol(s):
    """True if s is a bare identifier (atom-only, no brackets, no quotes,
    no `:` etc)."""
    if not s: return False
    if s[0] in '([{"': return False
    if any(c in '()[]{};"' for c in s): return False
    if ':' in s: return False
    return True

def migrate_text(text):
    """Returns (new_text, n_def_migrations, n_defn_migrations)."""
    forms = list(find_top_forms(text))
    n_def = 0
    n_defn = 0

    edits = []  # list of (start, end, replacement)

    i = 0
    while i < len(forms):
        s, e, fs = forms[i]
        ci = claim_info(fs)
        if ci is None:
            i += 1
            continue
        cname, ctype = ci
        # Look at next form
        if i+1 >= len(forms):
            # orphan claim — drop it? Better to leave & report
            i += 1
            continue
        ns, ne, nfs = forms[i+1]
        di = def_info(nfs)
        if di is None or di[1] != cname:
            i += 1
            continue
        kind = di[0]
        if kind == 'def':
            _, _, value_node = di
            new_form = rebuild_def(cname, ctype, value_node)
            # Replace claim + def span (preserving inter-form whitespace
            # between def_end and end of file? We replace s..ne with new_form.)
            # To preserve trailing newline structure, we look at whitespace
            # between the two forms — typically a single \n — and collapse.
            edits.append((s, ne, new_form))
            n_def += 1
            i += 2
            continue
        if kind == 'defn':
            # Use surgical patcher to preserve body formatting.
            new_defn = patch_defn_in_source(nfs, ctype)
            if new_defn is None:
                i += 1
                continue
            # Replace span: from claim start to defn start (drop claim + ws),
            # leaving new defn text in defn's place. We replace claim form
            # span and the inter-form whitespace with empty, then defn span
            # with new defn text.
            # To do this as a single edit: replace (s..ne) where s = claim
            # start, ne = defn end, with new_defn. Preserve any leading
            # whitespace before claim? The replaced region is exactly the
            # claim form + whitespace + defn form.
            edits.append((s, ne, new_defn))
            n_defn += 1
            i += 2
            continue
        i += 1

    if not edits:
        return text, 0, 0

    # Apply edits in reverse.
    out = text
    for (s, e, repl) in reversed(edits):
        out = out[:s] + repl + out[e:]
    return out, n_def, n_defn

# ----------------- main -----------------

def main():
    paths = []
    for arg in sys.argv[1:]:
        if os.path.isdir(arg):
            for ext in ('bclj', 'bcljs', 'rkt', 'bnix'):
                paths.extend(glob.glob(os.path.join(arg, '**', f'*.{ext}'),
                                       recursive=True))
        else:
            paths.append(arg)

    total_def = 0
    total_defn = 0
    changed_files = []
    for p in paths:
        try:
            with open(p) as f:
                txt = f.read()
        except UnicodeDecodeError:
            continue
        if '(claim ' not in txt:
            continue
        new_txt, nd, ndfn = migrate_text(txt)
        if new_txt == txt:
            continue
        with open(p, 'w') as f:
            f.write(new_txt)
        total_def += nd
        total_defn += ndfn
        changed_files.append((p, nd, ndfn))

    for (p, nd, ndfn) in changed_files:
        print(f"  {p}: def={nd} defn={ndfn}")
    print(f"\nTotal: {len(changed_files)} files, {total_def} def, {total_defn} defn migrations")

if __name__ == '__main__':
    main()

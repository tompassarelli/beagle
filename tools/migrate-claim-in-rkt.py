#!/usr/bin/env python3
"""Migrate inline `'(claim NAME T)` + `'(def NAME V)` pairs in .rkt test
files to inline `'(def NAME :- T V)`.

Patterns handled:

  Pattern A (simple quote pair):
    '(claim X T)
    '(def X V)
    →
    '(def X :- T V)

  Pattern B (quasi-quote pair):
    `(claim X T)            (or '(claim X T))
    `(def X V)              (where V may use ,(...) splice)
    →
    `(def X :- T V)

  Pattern C (claim with splice + defn):
    `(claim N ,(br 'T1 '-> 'R))
    `(defn N PARAMS BODY)
    →
    `(defn N PARAMS :- 'R BODY)
    (only if the type form is exactly `,(br ... '-> 'R)` and `'R` is
    a simple quoted symbol — drops the function-shape, takes only the
    return type. Defn params keep their existing type annotations.)

Anything more complex is left alone with a printed note.
"""

import re, sys, os, glob

# Match a (claim ...) form at the start of a line (possibly indented),
# capturing everything inside the parens.
CLAIM_LINE = re.compile(r"^(\s*)([`'])(\(claim\s+([^\s)]+)\s+(.+?)\))\s*$")
# Match a (def NAME ...) form OR (defn NAME ...) line.
DEFN_OPEN  = re.compile(r"^(\s*)([`'])(\(defn?\s+([^\s)]+))\b")
# Match a (claim ...) form ANYWHERE on a line, with `'` or backtick prefix.
CLAIM_INLINE = re.compile(r"([`'])\(claim\s+([^\s)]+)\s+")

def extract_balanced(s, start):
    """From s[start] == '(', return index after matching close paren."""
    depth = 0
    in_str = False
    i = start
    while i < len(s):
        c = s[i]
        if in_str:
            if c == '\\': i += 2; continue
            if c == '"': in_str = False
            i += 1; continue
        if c == '"': in_str = True; i += 1; continue
        if c == ';':
            while i < len(s) and s[i] != '\n': i += 1
            continue
        if c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")

def parse_claim_line(line):
    """Return (indent, quote, name, type_text) or None."""
    m = CLAIM_LINE.match(line)
    if not m:
        return None
    return m.group(1), m.group(2), m.group(4), m.group(5).strip()

def find_form_end(lines, line_idx, col_0idx):
    """Given 0-indexed position col_0idx in lines[line_idx] which is '(',
    find (end_line_idx, end_col_exclusive_0idx) for the matching ')'."""
    text = '\n'.join(lines)
    abs_offset = sum(len(l) + 1 for l in lines[:line_idx]) + col_0idx
    assert text[abs_offset] == '(', f"expected '(' at offset {abs_offset}, got {text[abs_offset]!r}"
    end = extract_balanced(text, abs_offset)
    # Convert back to (line, col).
    cum = 0
    for i, l in enumerate(lines):
        nxt = cum + len(l) + 1
        if end <= nxt:
            return i, end - cum
        cum = nxt
    return len(lines)-1, len(lines[-1])

def migrate_file(path):
    with open(path) as f:
        text = f.read()
    lines = text.split('\n')
    out_lines = []
    i = 0
    n_def = 0
    n_defn = 0
    n_skipped = 0
    while i < len(lines):
        line = lines[i]
        ci = parse_claim_line(line)
        if ci is None:
            out_lines.append(line)
            i += 1
            continue
        indent, quote, name, ctype = ci
        # Look at next non-blank, non-comment line
        j = i + 1
        while j < len(lines) and (lines[j].strip() == '' or
                                  re.match(r'\s*;', lines[j])):
            j += 1
        if j >= len(lines):
            out_lines.append(line); i += 1; continue
        nxt = lines[j]
        # Check if it's a def or defn for the same name
        m_open = DEFN_OPEN.match(nxt)
        if m_open is None or m_open.group(4) != name:
            out_lines.append(line); i += 1; continue
        head = m_open.group(3)  # like "(def x" or "(defn x"
        is_defn = '(defn' in head
        next_quote = m_open.group(2)
        # Compute next line's column where '(' starts
        col = len(m_open.group(1)) + 1  # after leading quote
        # Locate end of the def/defn form (multiline).
        # The '(' starts at column `col`; need its end.
        try:
            end_l, end_c = find_form_end(lines, j, col)
        except ValueError:
            out_lines.append(line); i += 1; continue
        if not is_defn:
            # def case
            # Build the def form prefix "(def NAME" then insert " :- T " then the
            # value text, then closing paren.
            # Locate the position right after NAME in the def form.
            def_form_open = j
            def_form_close = end_l
            # Extract full def text
            if def_form_open == def_form_close:
                def_text = lines[def_form_open][col-1:end_c]
                inner = def_text[1:-1]  # strip outer parens
                # inner starts like "def NAME VALUE..."
                # split off head + name
                m = re.match(r'(def\s+'+re.escape(name)+r'\s+)(.*)', inner, re.S)
                if not m:
                    out_lines.append(line); i += 1; continue
                new_inner = f"def {name} :- {ctype} {m.group(2)}"
                new_def = f"({new_inner})"
                # Replace line j's def-form text:
                lines[j] = (lines[j][:col-1] + new_def + lines[j][end_c:])
            else:
                # multi-line def
                first = lines[def_form_open][col-1:]
                last = lines[def_form_close][:end_c]
                middle = lines[def_form_open+1:def_form_close]
                # first looks like "(def NAME ..." possibly with value starting on same line
                m = re.match(r'\((def\s+'+re.escape(name)+r')(\s+)(.*)$', first, re.S)
                if not m:
                    out_lines.append(line); i += 1; continue
                new_first = f"({m.group(1)} :- {ctype}{m.group(2)}{m.group(3)}"
                lines[def_form_open] = lines[def_form_open][:col-1] + new_first
                # Last/middle lines unchanged.
            # Drop the claim line. Also drop any trailing comment-free blank
            # lines? Keep simple: just skip line i.
            # We've already not appended `line`; advance past it.
            # Use indent + maybe re-add blank... actually we already
            # appended nothing for line i. But we *did* append previous
            # lines. Need to also output the modified def lines now.
            # Use new lines structure: skip i, copy rest from j onward.
            # Simpler: rebuild out_lines logic.
            i += 1
            n_def += 1
            continue
        else:
            # defn case
            # Parse claim type as a Racket form to extract return type if it's
            # a (br ... '-> 'X) splice or [T -> R] bracket form.
            ret_type = extract_return_type(ctype)
            if ret_type is None:
                # Unrecognized arrow shape — leave as-is and report.
                print(f"  SKIP {path}:{i+1}: claim type not recognized: {ctype}")
                out_lines.append(line); i += 1
                n_skipped += 1
                continue
            # We need to insert " :- RET" after defn's params node. Find
            # the params node within the defn form.
            # Defn form spans lines[j..end_l]. The text is between col-1
            # and end_c in those lines (relative to abs).
            # Easier: locate the params in the defn form by token-walking.
            # Construct the full defn text:
            if j == end_l:
                defn_text = lines[j][col-1:end_c]
            else:
                parts = [lines[j][col-1:]]
                parts.extend(lines[j+1:end_l])
                parts.append(lines[end_l][:end_c])
                defn_text = '\n'.join(parts)
            new_defn = patch_defn_text(defn_text, name, ret_type)
            if new_defn is None:
                print(f"  SKIP {path}:{j+1}: defn patch failed")
                out_lines.append(line); i += 1
                n_skipped += 1
                continue
            # Splice new_defn back into lines.
            new_defn_lines = new_defn.split('\n')
            if j == end_l:
                lines[j] = lines[j][:col-1] + new_defn + lines[j][end_c:]
            else:
                # Replace lines j..end_l with new content + tails
                head_prefix = lines[j][:col-1]
                tail_suffix = lines[end_l][end_c:]
                new_first_line = head_prefix + new_defn_lines[0]
                new_last_line = new_defn_lines[-1] + tail_suffix
                replacement = [new_first_line] + new_defn_lines[1:-1] + [new_last_line]
                lines[j:end_l+1] = replacement
            i += 1
            n_defn += 1
            continue
    # Filter: we modified `lines` in place. The claim lines (line i)
    # need to be dropped. We tracked which ones via the i loop above —
    # but we appended every line we hadn't matched. Let me restructure:
    return None  # signal: use the second-pass approach
    # (intentionally unreachable; see migrate_file_v2)

def extract_return_type(type_text):
    """Given a type form text like:
       (br 'T1 '-> 'R)
       (br '-> 'R)
       [T1 T2 -> R]
       (-> T1 R)
       ,(br 'T '-> 'R)
       Some Type expressions (Vec Int)
     return the RETURN-TYPE text (as a Racket form/quoted expr suitable
     for use after `:-` in the defn form) or None if unrecognized.

     For bracket calls `(br ... '-> 'R)` the return type is the last
     argument: the literal 'R.

     For a bare type like 'Int' we'd return None — that means the
     claim is a value type, not a function type, and shouldn't be
     applied to a defn anyway.
    """
    t = type_text.strip()
    # Strip leading , (unquote in quasi-quote context).
    if t.startswith(','):
        t = t[1:].strip()
    # Try (br ... '-> 'R) pattern.
    m = re.match(r'\(br\s+(.*)\)\s*$', t, re.S)
    if m:
        # Parse args: must end with `'-> 'R` where 'R is a quoted return.
        # Inside a quasi-quote context the `br` helper concatenates raw
        # symbols/lists into a bracket form. So 'R evaluates to the symbol
        # R. When we splice this into a `(defn ...) :- R …)` quasi-quote
        # the bare R is the correct literal type symbol; the leading
        # ` ' ` must NOT be carried over (that would lower as (quote R)).
        args = m.group(1).strip()
        # Find last quoted return: '<symbol> or '(<list>)
        m2 = re.search(r"'->\s+('[^\s)]+|'\([^)]*\))\s*$", args)
        if m2:
            return m2.group(1).lstrip("'")  # drop the quote
        return None
    # Try bracketed [T1 T2 -> R]
    m = re.match(r'\[(.+)\]\s*$', t, re.S)
    if m:
        inner = m.group(1).strip()
        # find last "-> X" tail
        m2 = re.search(r'->\s+(.+?)\s*$', inner, re.S)
        if m2:
            return m2.group(1).strip()
        return None
    # Try (-> ... R)
    m = re.match(r'\(->\s+(.+)\)\s*$', t, re.S)
    if m:
        inner = m.group(1).strip()
        # last token is R; but may be a list. Take the last balanced item.
        last = take_last_form(inner)
        return last
    return None

def take_last_form(s):
    """Take the last s-expression-like token (atom or balanced list)
    from s."""
    s = s.rstrip()
    if not s: return None
    # If ends with ')': find balanced opener.
    if s.endswith(')'):
        depth = 0
        for i in range(len(s)-1, -1, -1):
            if s[i] == ')': depth += 1
            elif s[i] == '(':
                depth -= 1
                if depth == 0:
                    return s[i:].strip()
    # else atom — read backwards
    i = len(s) - 1
    while i >= 0 and not s[i].isspace():
        i -= 1
    return s[i+1:]

def patch_defn_text(defn_text, name, ret_type):
    """Insert ` :- RET` immediately after the params node in defn_text.
    Returns new text or None on failure."""
    # Find "(defn NAME"
    m = re.match(r'\((defn)\s+'+re.escape(name)+r'(\s+)', defn_text, re.S)
    if not m:
        return None
    after_name = m.end()
    # Now skip whitespace (already consumed by \s+), and expect '['/'(' params.
    # Actually we matched up to after the whitespace.
    # The next char should start the params node.
    rest = defn_text[after_name:]
    rs = rest.lstrip(' \t')
    # leading ws absorbed by \s+; but if more ws, account for it.
    leading_ws = rest[:len(rest)-len(rs)]
    params_start = after_name + len(leading_ws)
    if not rest.lstrip():
        return None
    # Check for unquote: `,(br ...)` — skip the comma
    skip = 0
    while params_start + skip < len(defn_text) and defn_text[params_start+skip] in ',':
        skip += 1
    bracket_open_idx = params_start + skip
    if bracket_open_idx >= len(defn_text):
        return None
    open_c = defn_text[bracket_open_idx]
    if open_c not in '([':
        return None
    # Find balanced close
    close_c = ')' if open_c == '(' else ']'
    depth = 0
    in_str = False
    i = bracket_open_idx
    while i < len(defn_text):
        c = defn_text[i]
        if in_str:
            if c == '\\': i += 2; continue
            if c == '"': in_str = False
            i += 1; continue
        if c == '"': in_str = True; i += 1; continue
        if c == ';':
            while i < len(defn_text) and defn_text[i] != '\n': i += 1
            continue
        if c in '([': depth += 1
        elif c in ')]':
            depth -= 1
            if depth == 0:
                end_params = i + 1
                # Insert ` :- RET` after end_params.
                return defn_text[:end_params] + f" :- {ret_type}" + defn_text[end_params:]
        i += 1
    return None


# ========== second-pass file driver ==========

def find_all_pairs_absolute(text):
    """Find every (claim NAME T) form (line-anchored or mid-line) followed
    by a (def NAME ...) or (defn NAME ...) form. Returns a list of dicts:
      {claim_start, claim_end, def_start, def_end, name, type_text,
       is_defn, on_own_line}
    """
    results = []
    # Pattern matches a quote-char then "(claim "
    pattern = re.compile(r"([`'])\(claim\s+")
    pos = 0
    while True:
        m = pattern.search(text, pos)
        if not m: break
        quote_idx = m.start()
        paren_idx = quote_idx + 1
        try:
            claim_end = extract_balanced(text, paren_idx)
        except ValueError:
            pos = m.end(); continue
        claim_form = text[paren_idx:claim_end]  # "(claim NAME TYPE)"
        inside = claim_form[1:-1].strip()
        mm = re.match(r'claim\s+([^\s)]+)\s+(.+)\s*$', inside, re.S)
        if not mm:
            pos = m.end(); continue
        name = mm.group(1)
        ctype = mm.group(2).strip()

        # Find next form (skipping ws/comments).
        nxt = claim_end
        while nxt < len(text):
            c = text[nxt]
            if c in ' \t\r\n':
                nxt += 1; continue
            if c == ';':
                while nxt < len(text) and text[nxt] != '\n': nxt += 1
                continue
            break
        if nxt >= len(text):
            pos = m.end(); continue
        if text[nxt] not in "'`":
            pos = m.end(); continue
        paren2 = nxt + 1
        if paren2 >= len(text) or text[paren2] != '(':
            pos = m.end(); continue
        head_m = re.match(r'\((defn?|defonce)\s+([^\s)]+)', text[paren2:])
        if not head_m:
            pos = m.end(); continue
        def_kind = head_m.group(1)
        def_name = head_m.group(2)
        if def_name != name:
            pos = m.end(); continue
        is_defn = (def_kind == 'defn')
        try:
            def_end = extract_balanced(text, paren2)
        except ValueError:
            pos = m.end(); continue

        # Is the claim "on its own line"? — i.e. only whitespace before
        # the claim's quote on the same line, and only whitespace after
        # the claim's close paren until the newline.
        line_start = text.rfind('\n', 0, quote_idx) + 1
        line_end = text.find('\n', claim_end)
        if line_end < 0: line_end = len(text)
        before = text[line_start:quote_idx]
        after = text[claim_end:line_end]
        on_own_line = (before.strip() == '' and after.strip() == '')

        results.append({
            'claim_start': quote_idx,    # include the quote char
            'claim_end': claim_end,
            'def_start': paren2 - 1,     # include the quote char before '('
            'def_end': def_end,
            'name': name,
            'type_text': ctype,
            'is_defn': is_defn,
            'on_own_line': on_own_line,
            'def_quote_idx': paren2 - 1,
            'def_paren_idx': paren2,
        })
        pos = def_end
    return results


def find_midline_pairs(lines):
    """Find (claim ...) forms that aren't anchored at line start (after
    indent + quote char). Returns list of pair-tuples shaped like the
    line-anchored ones, where claim_col is the 0-indexed col of the
    QUOTE char that precedes (claim ...).
    """
    text = '\n'.join(lines)
    results = []
    # Search whole text
    pos = 0
    while True:
        m = CLAIM_INLINE.search(text, pos)
        if not m: break
        quote_idx = m.start()
        # Translate quote_idx to (line, col):
        prefix = text[:quote_idx]
        line_idx = prefix.count('\n')
        line_start = prefix.rfind('\n') + 1
        col_of_quote = quote_idx - line_start
        # Check if this is "anchored at line start": indent then quote
        before = text[line_start:quote_idx]
        if before.strip() == '':
            # already handled by line-anchored pass
            pos = m.end()
            continue
        # Mid-line claim. Find end of claim form.
        paren_idx = quote_idx + 1  # '(' position
        try:
            claim_end = extract_balanced(text, paren_idx)
        except ValueError:
            pos = m.end()
            continue
        # Extract claim type-text:
        claim_form = text[paren_idx:claim_end]  # "(claim NAME TYPE)"
        ci = parse_claim_line('  ' + text[quote_idx:claim_end])  # fake indent
        # CLAIM_LINE matches at line start; we need a tolerant parse.
        # Simpler: do the same parse manually.
        inside = claim_form[1:-1].strip()  # "claim NAME TYPE"
        mm = re.match(r'claim\s+([^\s)]+)\s+(.+)\s*$', inside, re.S)
        if not mm:
            pos = m.end()
            continue
        name = mm.group(1)
        ctype = mm.group(2).strip()
        # Now find the NEXT non-whitespace form after claim_end.
        nxt = claim_end
        while nxt < len(text) and text[nxt] in ' \t\r\n':
            nxt += 1
        if nxt >= len(text):
            pos = m.end()
            continue
        # Must be a quote (' or `) followed by (def NAME or (defn NAME ...
        if text[nxt] not in "'`":
            pos = m.end()
            continue
        quote2 = text[nxt]
        paren2 = nxt + 1
        if paren2 >= len(text) or text[paren2] != '(':
            pos = m.end()
            continue
        # Parse the (def...) form name
        defn_open_match = re.match(r'\((defn?)\s+([^\s)]+)', text[paren2:])
        if not defn_open_match:
            pos = m.end()
            continue
        def_kind = defn_open_match.group(1)
        def_name = defn_open_match.group(2)
        if def_name != name:
            pos = m.end()
            continue
        is_defn = (def_kind == 'defn')
        try:
            def_end_abs = extract_balanced(text, paren2)
        except ValueError:
            pos = m.end()
            continue
        # Translate paren2 → (def_l, def_col), def_end_abs → (end_l, end_c)
        def abs_to_lc(off):
            pre = text[:off]
            ln = pre.count('\n')
            lns = pre.rfind('\n') + 1
            return ln, off - lns
        def_l, def_col = abs_to_lc(paren2)
        end_l, end_c = abs_to_lc(def_end_abs)
        # Build a fake ci: (indent, quote, name, ctype)
        # Use the claim's quote char.
        results.append((line_idx, ('', quote, name, ctype),
                        def_l, def_col, end_l, end_c, is_defn,
                        col_of_quote))  # col of the claim's QUOTE char
        # Store extra: also remember claim's span via line_idx + col_of_quote +
        # claim_end's line/col so we know exactly what to erase.
        # Stash absolute spans for erasure in a parallel dict:
        midline_erase_spans[(line_idx, col_of_quote)] = (quote_idx, claim_end)
        pos = def_end_abs
    return results


midline_erase_spans = {}

def migrate_file_v2(path):
    midline_erase_spans.clear()
    with open(path) as f:
        text = f.read()
    lines = text.split('\n')

    # Find claim+def/defn pairs by line index.
    pairs = []   # list of (claim_line, def_open_line, def_end_line, def_end_col)
    i = 0
    while i < len(lines):
        ci = parse_claim_line(lines[i])
        if ci is None:
            i += 1
            continue
        indent, quote, name, ctype = ci
        j = i + 1
        while j < len(lines) and (lines[j].strip() == '' or
                                  re.match(r'\s*;', lines[j])):
            j += 1
        if j >= len(lines):
            i += 1; continue
        m_open = DEFN_OPEN.match(lines[j])
        if m_open is None or m_open.group(4) != name:
            i += 1; continue
        head = m_open.group(3)
        is_defn = '(defn' in head
        # 0-indexed column of '('. After indent (len(group(1))) + 1 quote char.
        col = len(m_open.group(1)) + 1
        try:
            end_l, end_c = find_form_end(lines, j, col)
        except ValueError:
            i += 1; continue
        # Sentinel: claim_l, ci, def_l, def_col, def_end_l, def_end_c, is_defn,
        # claim_start_col_0idx (or None = whole-line replace)
        pairs.append((i, ci, j, col, end_l, end_c, is_defn, None))
        i = j + 1  # skip ahead past def

    # Second pass: mid-line claim+defn (claim is not the first form on its line).
    pairs.extend(find_midline_pairs(lines))

    # Apply rewrites bottom-up to keep indices valid.
    n_def = 0
    n_defn = 0
    n_skipped = []
    # Sort: bottom-up by claim_l, then by claim_col descending.
    def _key(p):
        # claim_l, claim_col (from ci or stored)
        return (p[0], p[7] if p[7] is not None else -1)
    pairs.sort(key=_key, reverse=True)
    for (claim_l, ci, def_l, col, end_l, end_c, is_defn, claim_col) in pairs:
        indent, quote, name, ctype = ci
        # Build the def/defn text — col is the 0-indexed pos of '('.
        if def_l == end_l:
            def_text = lines[def_l][col:end_c]
        else:
            parts = [lines[def_l][col:]]
            parts.extend(lines[def_l+1:end_l])
            parts.append(lines[end_l][:end_c])
            def_text = '\n'.join(parts)

        if not is_defn:
            # Pattern: (def NAME VALUE...)
            m = re.match(r'\((def)\s+'+re.escape(name)+r'\b(\s+)', def_text, re.S)
            if not m:
                n_skipped.append((def_l+1, 'def-shape')); continue
            # Insert " :- TYPE" right before the value (preserving the
            # whitespace from m.group(2)).
            new_def_text = (def_text[:m.start(2)] +
                            f" :- {ctype}" + def_text[m.start(2):])
        else:
            ret = extract_return_type(ctype)
            if ret is None:
                n_skipped.append((def_l+1, f'unparsable arrow: {ctype}'))
                continue
            new_def_text = patch_defn_text(def_text, name, ret)
            if new_def_text is None:
                n_skipped.append((def_l+1, 'patch failed'))
                continue

        # Splice new def_text into lines.
        new_def_lines = new_def_text.split('\n')
        if def_l == end_l:
            lines[def_l] = lines[def_l][:col] + new_def_text + lines[def_l][end_c:]
        else:
            head_prefix = lines[def_l][:col]
            tail_suffix = lines[end_l][end_c:]
            new_first_line = head_prefix + new_def_lines[0]
            new_last_line = new_def_lines[-1] + tail_suffix
            replacement = [new_first_line] + new_def_lines[1:-1] + [new_last_line]
            lines[def_l:end_l+1] = replacement

        # Drop the claim line.
        del lines[claim_l]
        if is_defn:
            n_defn += 1
        else:
            n_def += 1

    new_text = '\n'.join(lines)
    if new_text == text:
        return 0, 0, n_skipped
    with open(path, 'w') as f:
        f.write(new_text)
    return n_def, n_defn, n_skipped


def migrate_file_v3(path):
    """Cleaner reimplementation using absolute offsets.

    Strategy:
      1. Find all claim+def(n) pairs as absolute spans.
      2. For each pair (in reverse order to keep offsets valid):
         - Compute the new def/defn form text.
         - Replace claim_start..def_end with new text. We preserve the
           leading whitespace before the claim (already outside the span)
           and the original whitespace between claim and def IF we want
           to keep it pretty.

      For "on_own_line" claims: we just delete the claim line entirely
      (including its trailing newline) and rewrite the def line.

      For mid-line claims: we replace `'(claim …)<ws>'(defn …)` with the
      new defn form text only.
    """
    with open(path) as f:
        text = f.read()
    pairs = find_all_pairs_absolute(text)
    if not pairs:
        return 0, 0, []

    n_def = 0
    n_defn = 0
    skipped = []
    # Process in reverse so earlier offsets stay valid.
    for p in reversed(pairs):
        cstart = p['claim_start']
        cend = p['claim_end']
        dstart = p['def_start']
        dend = p['def_end']
        name = p['name']
        ctype = p['type_text']
        is_defn = p['is_defn']

        # Extract def text (with leading quote char).
        def_text = text[p['def_quote_idx']:dend]
        # def_text looks like "'(def NAME VALUE…)" or "`(defn NAME PARAMS BODY)".
        if not is_defn:
            # Insert " :- TYPE " after "NAME ". Both def and defonce share
            # the same shape: (def[once]? NAME VALUE).
            inner = def_text  # includes leading quote
            quote_char = inner[0]
            rest = inner[1:]
            mm = re.match(r'\((def|defonce)\s+'+re.escape(name)+r'\b(\s+)',
                          rest, re.S)
            if not mm:
                skipped.append((cstart, 'def-shape'))
                continue
            insert_at = mm.start(2) + 1  # +1 to account for stripped quote
            new_def_text = (def_text[:insert_at] + f" :- {ctype}"
                            + def_text[insert_at:])
            n_def += 1
        else:
            # Defn case: extract return type.
            ret = extract_return_type(ctype)
            if ret is None:
                skipped.append((cstart, f'unparsable arrow: {ctype}'))
                continue
            # Patch the defn — but the def_text has a leading quote.
            quote_char = def_text[0]
            paren_text = def_text[1:]
            patched = patch_defn_text(paren_text, name, ret)
            if patched is None:
                skipped.append((cstart, 'patch failed'))
                continue
            new_def_text = quote_char + patched
            n_defn += 1

        if p['on_own_line']:
            # Erase the whole claim line (including trailing newline) and
            # rewrite def line(s).
            # Find start of claim's line and end of claim's line+newline.
            line_start = text.rfind('\n', 0, cstart) + 1
            line_end = text.find('\n', cend)
            if line_end < 0:
                line_end = len(text)
            else:
                line_end += 1  # include the newline
            # Build replacement: empty for claim region + new_def_text in
            # place of original def region.
            # Combined span: [line_start, dend)
            # We need to keep the def's leading whitespace (its indent).
            def_line_start = text.rfind('\n', 0, dstart) + 1
            def_indent = text[def_line_start:dstart]
            replacement = new_def_text  # new_def_text starts with quote+paren
            # Combine: original prefix up to claim_line_start unchanged;
            # delete claim line entirely; replace [def_line_start..dend) with
            # def_indent + new_def_text.
            new_segment = def_indent + new_def_text
            text = (text[:line_start]
                    + new_segment
                    + text[dend:])
        else:
            # Mid-line: replace [claim_start, def_end) with new_def_text.
            # Erase any whitespace between claim and def along the way
            # (already encompassed).
            text = text[:cstart] + new_def_text + text[dend:]

    with open(path, 'w') as f:
        f.write(text)
    return n_def, n_defn, skipped


def main():
    paths = sys.argv[1:]
    if not paths:
        print("usage: migrate-claim-in-rkt.py FILE.rkt ...")
        sys.exit(1)
    total_def = 0
    total_defn = 0
    total_skipped = []
    for p in paths:
        if not os.path.isfile(p): continue
        with open(p) as f:
            if '(claim ' not in f.read(): continue
        nd, ndfn, skipped = migrate_file_v3(p)
        print(f"  {p}: def={nd} defn={ndfn} skipped={len(skipped)}")
        for s in skipped:
            print(f"    skipped at offset {s[0]}: {s[1]}")
        total_def += nd
        total_defn += ndfn
        total_skipped.extend(skipped)
    print(f"\nTotal: def={total_def} defn={total_defn} skipped={len(total_skipped)}")

if __name__ == '__main__':
    main()

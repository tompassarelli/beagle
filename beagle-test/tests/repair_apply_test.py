#!/usr/bin/env python3
"""Unit tests for the beagle-repair clause-insertion helper (pure text, no
pipeline). Run directly (exit 0/1) or via repair-apply.rkt. See:
  ~/code/life-os/threads/20260615005103-beagle_python_repair_consume_structured.md
"""
import sys, os, tempfile, shutil

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'bin'))
from beagle_repair_apply import insert_match_clauses, resolve_source_file

fails = []


def check(name, got, want):
    if got != want:
        fails.append("%s\n  got:  %r\n  want: %r" % (name, got, want))


# resolve_source_file returns the first matching extension, so each case below
# uses an isolated dir with one candidate (a shared dir would assert list order).
def _with_file(name, probe):
    d = tempfile.mkdtemp(prefix='beagle-repair-resolve-test-')
    try:
        open(os.path.join(d, name), 'w').close()
        return probe(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)

check("as-is absolute path",
      _with_file('mod.bzig', lambda d: resolve_source_file(os.path.join(d, 'mod.bzig'), d) == os.path.join(d, 'mod.bzig')),
      True)
check("zig output ext maps back to .bzig",
      _with_file('mod.bzig', lambda d: resolve_source_file('mod.zig', d) == os.path.join(d, 'mod.bzig')),
      True)
check("odin output ext maps back to .bodin",
      _with_file('mod.bodin', lambda d: resolve_source_file('mod.odin', d) == os.path.join(d, 'mod.bodin')),
      True)
check("scriptc output ext maps back to .bsc",
      _with_file('mod.bsc', lambda d: resolve_source_file('mod.ts', d) == os.path.join(d, 'mod.bsc')),
      True)
check("bare basename fallback",
      _with_file('mod.bzig', lambda d: resolve_source_file('mod.bzig', d) == os.path.join(d, 'mod.bzig')),
      True)
check("unresolvable file is None",
      _with_file('mod.bzig', lambda d: resolve_source_file('nope.zig', d)), None)
check("missing file field is None",
      _with_file('mod.bzig', lambda d: resolve_source_file('?', d)), None)


CL = ['[(Square side) (throw "TODO: handle Square")]']

# 1. single-line match: insert inline, space-separated, well-formed (this was
#    the adversarial-review bug — used to emit a broken extra line).
src1 = '(defn f [(s : Shape)] :- Int (match s [(Circle r) r]))'
check("single-line",
      insert_match_clauses(src1, 1, CL),
      '(defn f [(s : Shape)] :- Int (match s [(Circle r) r] '
      '[(Square side) (throw "TODO: handle Square")]))')

# 2. multi-line match: own-line clause at the existing clause indent.
src2 = '(defn f [(s : Shape)] :- Int\n  (match s\n    [(Circle r) r]))'
check("multi-line",
      insert_match_clauses(src2, 2, CL),
      '(defn f [(s : Shape)] :- Int\n  (match s\n    [(Circle r) r]\n'
      '    [(Square side) (throw "TODO: handle Square")]))')

# 3. string decoy: a `(match` inside a string before the real form must not win.
src3 = '(def x "(match fake") (match s [(Circle r) r])'
out3 = insert_match_clauses(src3, 1, CL)
check("string-decoy-keeps-prefix",
      out3 is not None and out3.startswith('(def x "(match fake")'), True)
check("string-decoy-inserts-once", out3.count('[(Square side)'), 1)

# 4. two clauses inserted together (single-line).
CL2 = ['[(Square side) (throw "x")]', '[(Triangle b h) (throw "y")]']
check("two-clauses",
      insert_match_clauses(src1, 1, CL2),
      '(defn f [(s : Shape)] :- Int (match s [(Circle r) r] '
      '[(Square side) (throw "x")] [(Triangle b h) (throw "y")]))')

# 5. graceful failures → None (so the caller skips rather than corrupts).
check("bad-anchor-none", insert_match_clauses(src1, 99, CL), None)
check("non-int-anchor-none", insert_match_clauses(src1, None, CL), None)
check("no-match-none", insert_match_clauses('(def x 1)', 1, CL), None)

if fails:
    print("FAIL:\n" + "\n\n".join(fails))
    sys.exit(1)
print("repair_apply_test: all passed")
sys.exit(0)

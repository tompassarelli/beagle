#!/usr/bin/env bash
# run-epoch-stage.sh [--out DIR] MODULE...
#
# Phase-2 S1 epoch analysis driver, report-only. MODULE is a native.* module
# name (native.body-c17 -> native-core/src/native/body_c17.bclj). Per module:
# bin/beagle-ast on the module source and its native.* require closure,
# affordance.clj escape/affordance analysis (module = item, closure =
# context), then the epoch-stage.clj fold. Writes <out>/<module>.report.json,
# <module>.epoch-map.json, and <module>.summary.txt. Never mutates anything
# outside <out>.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
src_dir="$repo/native-core/src/native"

command -v bb >/dev/null 2>&1 || { echo "run-epoch-stage.sh: babashka (bb) is required" >&2; exit 2; }

out=""
mods=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) mods+=("$1"); shift ;;
  esac
done
[[ ${#mods[@]} -ge 1 ]] || { echo "usage: run-epoch-stage.sh [--out DIR] native.<module>..." >&2; exit 2; }
[[ -n "$out" ]] || out="$(mktemp -d "${TMPDIR:-/tmp}/epoch-stage.XXXXXX")"
mkdir -p "$out/ast"

path_of() {  # native.foo-bar -> $src_dir/foo_bar.bclj
  local name="${1#native.}"
  printf '%s/%s.bclj\n' "$src_dir" "${name//-/_}"
}

ast_of() {  # source path -> AST JSON path, generated once per run
  local src="$1" base json
  base="$(basename "$src")"
  json="$out/ast/${base}.ast.json"
  if [[ ! -s "$json" ]]; then
    "$repo/bin/beagle-ast" "$src" > "$json"
  fi
  printf '%s\n' "$json"
}

deps_of() {  # AST JSON path -> native.* module names it requires
  bb -e '(require (quote [cheshire.core :as json])
                  (quote [clojure.string :as str]))
         (doseq [r (get (json/parse-string (slurp (first *command-line-args*)))
                        "requires")
                 :let [n (str (get r "ns"))]
                 :when (str/starts-with? n "native.")]
           (println n))' "$1"
}

for mod in "${mods[@]}"; do
  echo "== $mod" >&2
  src="$(path_of "$mod")"
  [[ -f "$src" ]] || { echo "run-epoch-stage.sh: no source for $mod at $src" >&2; exit 1; }
  ast="$(ast_of "$src")"
  args=(--item "$mod" --out "$out/$mod.report.json" --ast "$ast=$src")
  declare -A seen=()
  seen["$mod"]=1
  pending=()
  while IFS= read -r dep; do
    [[ -n "$dep" && -z "${seen[$dep]:-}" ]] && { seen["$dep"]=1; pending+=("$dep"); }
  done < <(deps_of "$ast")
  while [[ ${#pending[@]} -gt 0 ]]; do
    dep="${pending[0]}"
    pending=("${pending[@]:1}")
    dsrc="$(path_of "$dep")"
    if [[ -f "$dsrc" ]]; then
      dast="$(ast_of "$dsrc")"
      args+=(--context "$dast=$dsrc")
      while IFS= read -r sub; do
        [[ -n "$sub" && -z "${seen[$sub]:-}" ]] && { seen["$sub"]=1; pending+=("$sub"); }
      done < <(deps_of "$dast")
    else
      echo "  (context module missing, continuing without it: $dep)" >&2
    fi
  done
  unset seen
  bb "$here/affordance.clj" "${args[@]}"
  bb "$here/epoch-stage.clj" "$out/$mod.report.json" "$out/$mod.epoch-map.json" \
    | tee "$out/$mod.summary.txt"
done
echo "artifacts: $out" >&2

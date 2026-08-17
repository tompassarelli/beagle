#!/usr/bin/env bash
# Recompile Fram's hosted runtime into out/ from its sources.
#
# You do NOT need this to run Fram — out/ is committed and runs on babashka
# (bin/fram). Rebuilding needs Beagle at $BEAGLE_HOME, entered via direnv.
#
# Kind `beagle` compiles hosted .bclj; kind `beagle-core` projects a canonical
# .bgl Native Core module onto the same hosted tree, so the one source that
# fram:bin/fram-native-build materializes natively cannot drift from out/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
BEAGLE="${BEAGLE_HOME:-$HOME/code/beagle/main}"
MANIFEST_DIR="$HERE/build/generated-targets.d"
UNGENERATED="$HERE/build/ungenerated-out.tsv"

shopt -s nullglob
fragments=("$MANIFEST_DIR"/*.tsv)
shopt -u nullglob
if ((${#fragments[@]} == 0)); then
  echo "build.sh: no generation manifests in $MANIFEST_DIR" >&2
  exit 1
fi

for fragment in "${fragments[@]}"; do
  line_number=0
  while IFS=$'\t' read -r kind source destination extra ||
        [[ -n "$kind$source$destination$extra" ]]; do
    ((line_number += 1))
    [[ -z "$kind" || "$kind" == \#* ]] && continue
    if [[ -n "$extra" || -z "$source" || -z "$destination" ]]; then
      echo "build.sh: invalid manifest row at $fragment:$line_number" >&2
      exit 1
    fi

    source_path="$HERE/$source"
    destination_path="$HERE/$destination"
    mkdir -p "$(dirname "$destination_path")"
    case "$kind" in
      beagle)
        BEAGLE_EMIT_SRCLOC=0 direnv exec "$BEAGLE" "$BEAGLE/bin/beagle-build" \
          "$source_path" "$destination_path" >/dev/null
        label="${destination#out/}"
        echo "  built ${label%.clj}"
        ;;
      beagle-core)
        # --target clj is required: beagle-build refuses a bare .bgl so that a
        # Core module is never projected hosted by accident.
        BEAGLE_EMIT_SRCLOC=0 direnv exec "$BEAGLE" "$BEAGLE/bin/beagle-build" \
          --target clj "$source_path" "$destination_path" >/dev/null
        label="${destination#out/}"
        echo "  built ${label%.clj} (core)"
        ;;
      copy)
        cp "$source_path" "$destination_path"
        ;;
      *)
        echo "build.sh: unknown generation kind '$kind' at $fragment:$line_number" >&2
        exit 1
        ;;
    esac
  done < "$fragment"
done
echo "fram built -> $OUT"

# Coverage: every committed out/*.clj is generated above, or is declared
# ungenerated with a reason. Anything else is a file the build silently skips.
generated="$(mktemp)"; declared="$(mktemp)"; committed="$(mktemp)"
trap 'rm -f "$generated" "$declared" "$committed"' EXIT

grep -hv '^[[:space:]]*#' "${fragments[@]}" | cut -f3 | grep -v '^$' | sort -u >"$generated"

if [[ -f "$UNGENERATED" ]]; then
  grep -v '^[[:space:]]*#' "$UNGENERATED" | cut -f1 | grep -v '^$' | sort -u >"$declared"
else
  : >"$declared"
fi

if ! git -C "$HERE" ls-files --error-unmatch out >/dev/null 2>&1; then
  echo "build.sh: out/ is not a tracked git tree; skipping coverage check" >&2
  exit 0
fi
git -C "$HERE" ls-files 'out/*.clj' | sort -u >"$committed"

if [[ -s "$declared" ]]; then
  echo
  echo "NOT GENERATED — committed out/ files this build does not produce:"
  while IFS=$'\t' read -r path reason; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    echo "  $path — ${reason:-no reason recorded}"
  done < <(grep -v '^[[:space:]]*#' "$UNGENERATED")
  echo "  (out/ is NOT fully in sync with src/; see build/ungenerated-out.tsv)"
fi

unaccounted="$(comm -23 "$committed" <(sort -u "$generated" "$declared"))"
if [[ -n "$unaccounted" ]]; then
  echo >&2
  echo "build.sh: committed out/ files with NO generation route and no declared reason:" >&2
  echo "$unaccounted" | sed 's/^/  /' >&2
  echo "Add a manifest row under $MANIFEST_DIR, or declare it in $UNGENERATED." >&2
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-extract-schema-stdout.XXXXXX")"
cleanup() { rm -rf "${scratch:?}"; }
trap cleanup EXIT

mkdir -p "$scratch/bin" "$scratch/flake"
cat > "$scratch/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 4 ]]
[[ "$1" == "eval" ]]
[[ "$2" == "--json" ]]
[[ "$3" == "--file" ]]
[[ -s "$4" ]]
printf '%s\n' '[{"name":"fixture.enabled","t":"bool"}]'
EOF
chmod +x "$scratch/bin/nix"

PATH="$scratch/bin:$PATH" timeout 5s \
    "$root/bin/beagle-extract-schema" \
    --target fixture.options \
    --out /dev/stdout \
    --flake "$scratch/flake" \
    > "$scratch/schema.json" \
    2> "$scratch/stderr"

cmp <(printf '%s\n' '[{"name":"fixture.enabled","t":"bool"}]') \
    "$scratch/schema.json"
grep -Fqx 'beagle-extract-schema: evaluating fixture.options ...' "$scratch/stderr"
grep -Fqx 'beagle-extract-schema: wrote 1 options to /dev/stdout' "$scratch/stderr"

printf '%s\n' 'extract-schema-stdout: piped JSON and option count PASS'

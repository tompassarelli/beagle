#!/usr/bin/env bash
# Installed server-closure smoke: native-only fail-closed launch and package shape.
set -euo pipefail

package_root="${1:?usage: package_server_smoke.sh /nix/store/...-store}"
env_bin="${BEAGLE_STORE_SMOKE_ENV:?BEAGLE_STORE_SMOKE_ENV is required}"
grep_bin="${BEAGLE_STORE_SMOKE_GREP:?BEAGLE_STORE_SMOKE_GREP is required}"

case "$package_root" in /nix/store/*) ;; *)
  echo "store package smoke: refusing non-store package root: $package_root" >&2
  exit 2;; esac

runtime="$package_root/libexec/store"
required=(
  "$package_root/bin/beagle-store-server"
  "$package_root/bin/beagle-store-backup" "$package_root/bin/beagle-store-mcp"
  "$runtime/clients/bun/backup.mjs" "$runtime/clients/bun/store-rpc.mjs"
  "$runtime/bin/beagle-store-cli.clj"
  "$runtime/database.clj" "$runtime/server.clj"
  "$runtime/writer_authority.clj" "$runtime/rotations.clj"
  "$runtime/out/store/rpc.clj" "$runtime/out/store/rt.clj"
  "$runtime/out/store/types.clj" "$runtime/tests/store_mcp.clj"
)
for path in "${required[@]}"; do
  [[ -e "$path" ]] || { echo "store package smoke: missing runtime asset: $path" >&2; exit 1; }
done
if ! "$env_bin" -i "$package_root/bin/beagle-store-backup" --help \
    | "$grep_bin" -Fq 'beagle-store-backup create'; then
  echo "store package smoke: packaged backup operator did not start under an empty environment" >&2
  exit 1
fi

hidden_commands=(beagle-store-code-off beagle-store-code-on beagle-store-code-status
  beagle-store-defcheck beagle-store-defcheck-server.rkt beagle-store-ingest-code beagle-store-up)
for name in "${hidden_commands[@]}"; do
  [[ ! -e "$package_root/bin/$name" ]] || {
    echo "store package smoke: non-core helper exposed as public command: $name" >&2; exit 1; }
done
[[ ! -e "$runtime/.cpcache" ]] || {
  echo "store package smoke: tools.deps cache leaked into runtime" >&2; exit 1; }
if checkout_hits="$("$grep_bin" -R -a -n -m 5 -F "/home/" "$package_root" 2>/dev/null)"; then
  echo "store package smoke: checkout-local path leaked into runtime" >&2
  printf '%s\n' "$checkout_hits" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT INT TERM
native_error="$work/native-error.out"
if "$env_bin" -i BEAGLE_STORE_SPACE_ID=package-native-rpc \
    "$package_root/bin/beagle-store-server" serve 7977 "$work/history.storelog" \
    >"$native_error" 2>&1; then
  echo "store package smoke: native launch ran without an artifact" >&2
  exit 1
fi
"$grep_bin" -Fxq \
  "beagle-store-server: BEAGLE_STORE_NATIVE_ARTIFACT_DIR is required" \
  "$native_error" || {
    echo "store package smoke: missing native artifact did not fail exactly" >&2
    sed -n '1,40p' "$native_error" >&2
    exit 1
  }

echo "store package smoke: native-only launcher fails closed without an artifact"

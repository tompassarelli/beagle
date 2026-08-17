#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Miniflare process hook: put only the real workerd runtime subtree under the
# 128 MiB ceiling. The Bun controller stays outside the measurement because it
# is not part of Cloudflare's Worker isolate.
set -euo pipefail
export LC_ALL=C

real_workerd="${FRAM_CF_REAL_WORKERD:?set FRAM_CF_REAL_WORKERD}"
locator="${FRAM_CF_CGROUP_LOCATOR:?set FRAM_CF_CGROUP_LOCATOR}"
inventory="${FRAM_CF_CGROUP_INVENTORY:?set FRAM_CF_CGROUP_INVENTORY}"
limit_bytes=134217728
uid="$(id -u)"
base="/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/app.slice"
group="$base/fram-cloudflare-workerd-$$"

[[ -x "$real_workerd" ]] || {
  echo "workerd-cgroup-wrapper: real workerd is not executable" >&2
  exit 2
}
mkdir "$group"
printf '%s\n' "$limit_bytes" >"$group/memory.max"
printf '0\n' >"$group/memory.swap.max"
if [[ -f "$group/memory.zswap.max" ]]; then
  printf '0\n' >"$group/memory.zswap.max"
fi
stat="$(</proc/self/stat)"
tail="${stat##*) }"
read -r -a fields <<<"$tail"
start_time="${fields[19]:?workerd wrapper could not read its process start time}"
printf '%s %s %s\n' "$$" "$start_time" "$group" >>"$inventory"
current_locator="$locator.current.$$"
printf '%s\n' "$group" >"$current_locator"
mv "$current_locator" "$locator"
printf '%s\n' "$$" >"$group/cgroup.procs"
exec "$real_workerd" "$@"

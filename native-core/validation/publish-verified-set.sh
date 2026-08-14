#!/usr/bin/env bash

# Publish an already-validated flat artifact set. Every byte is first staged on
# the destination filesystem; only then is each destination replaced by one
# atomic rename. Callers must not invoke this until every required probe passes.
publish_verified_set() {
  local source_dir="$1"
  local target_dir="$2"
  shift 2
  local name stage pending
  local -a pending_paths=()

  [[ "$#" -gt 0 ]] || {
    echo "publish_verified_set: empty artifact set" >&2
    return 2
  }
  mkdir -p "$target_dir"
  for name in "$@"; do
    [[ "$name" != */* && -f "$source_dir/$name" ]] || {
      echo "publish_verified_set: missing or nested artifact: $source_dir/$name" >&2
      return 2
    }
  done

  stage="$(mktemp -d "$target_dir/.verified-publish.XXXXXX")"
  for name in "$@"; do
    if ! cp -- "$source_dir/$name" "$stage/$name"; then
      rm -rf "${stage:?}"
      return 1
    fi
  done
  for name in "$@"; do
    pending="$target_dir/.${name}.pending.$$"
    if ! mv -- "$stage/$name" "$pending"; then
      rm -f -- "${pending_paths[@]}"
      rm -rf "${stage:?}"
      return 1
    fi
    pending_paths+=("$pending")
  done
  rmdir -- "$stage"
  for name in "$@"; do
    pending="$target_dir/.${name}.pending.$$"
    mv -f -- "$pending" "$target_dir/$name"
  done
}

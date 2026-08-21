#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$repo/bin/beagle-store-native-build"
beagle_pin="$(<"$repo/beagle-pin.txt")"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch:?}"' EXIT INT TERM

fail() {
  echo "store native build cache smoke: FAIL: $*" >&2
  exit 1
}

mkdir -p "$scratch/tool/bin" "$scratch/cache" "$scratch/sources"
calls="$scratch/materializer.calls"
: >"$calls"

cat >"$scratch/tool/bin/beagle" <<'FAKE_BEAGLE'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
shift
if [[ "$command" == "build" ]]; then
  out=""
  abi=""
  materializers=()
  module_roots=()
  sources=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --materializer) materializers+=("$2"); shift 2 ;;
      --abi) abi="$2"; shift 2 ;;
      --entry) shift 2 ;;
      --module-root) module_roots+=("$2"); shift 2 ;;
      --) shift; sources+=("$@"); break ;;
      *) sources+=("$1"); shift ;;
    esac
  done
  want_qbe=0
  case "${materializers[*]}" in
    "c17 qbe") want_qbe=1 ;;
    "c17") ;;
    *) exit 96 ;;
  esac
  [[ -n "$out" && -n "$abi" && ${#sources[@]} -gt 0 ]] || exit 96
  if [[ -n "${FAKE_MODULE_ROOT_OBSERVATIONS:-}" ]]; then
    printf '%s\n' "${module_roots[@]}" >>"$FAKE_MODULE_ROOT_OBSERVATIONS"
  fi
  if [[ -n "${FAKE_TIMEOUT_OBSERVATIONS:-}" ]]; then
    printf 'ast=%s facts=%s compiler=%s lowering=%s validation=%s lock=%s grace=%s overall=%s\n' \
      "${BEAGLE_CORE_AST_TIMEOUT_SECONDS:-}" \
      "${BEAGLE_CORE_FACTS_TIMEOUT_SECONDS:-}" \
      "${BEAGLE_CORE_COMPILER_TIMEOUT_SECONDS:-}" \
      "${BEAGLE_CORE_LOWERING_TIMEOUT_SECONDS:-}" \
      "${BEAGLE_CORE_VALIDATION_TIMEOUT_SECONDS:-}" \
      "${BEAGLE_CORE_LOCK_TIMEOUT_SECONDS:-}" \
      "${BEAGLE_CORE_KILL_GRACE_SECONDS:-}" \
      "${BEAGLE_CORE_OVERALL_TIMEOUT_SECONDS:-}" \
      >>"$FAKE_TIMEOUT_OBSERVATIONS"
  fi
  if [[ "${FAKE_CORE_LOWERING_TIMEOUT:-0}" == 1 ]]; then
    echo 'beagle build: phase core-lowering TIMEOUT (124)' >&2
    exit 124
  fi
  printf '%s\n' "build-$(IFS=+; printf '%s' "${materializers[*]}")" \
    >>"$FAKE_NATIVE_CALLS"
  if [[ -n "${FAKE_SOURCE_OBSERVATIONS:-}" ]]; then
    for source in "${sources[@]}"; do
      printf '%s\t%s\t%s\n' "$PWD" "$source" \
        "$(sha256sum "$source" | sed 's/ .*//')" \
        >>"$FAKE_SOURCE_OBSERVATIONS"
    done
  fi
  mkdir -p "$out"
  # Mimic beagle-build-core: managed artifacts are wiped before the run.
  rm -f "$out/module_0.h" "$out/module_0.c" "$out/module_0.ssa" \
    "$out/native_shim.h" "$out/native_shim.c" "$out/report.txt" \
    "$out/native_unicode15_data.h" "$out/UNICODE-LICENSE.txt"
  printf '%s\n' 'fake source facts' >"$out/source.facts"
  {
    printf '%s\n' 'fake frozen native program'
    for source in "${sources[@]}"; do
      sha256sum "$source" | sed 's/ .*//'
    done
  } >"$out/module.native-program"
  if [[ "$want_qbe" == 0 && -n "${FAKE_C17_PROGRAM_SUFFIX:-}" ]]; then
    printf '%s\n' "$FAKE_C17_PROGRAM_SUFFIX" >>"$out/module.native-program"
  fi
  native_program_digest="$(sha256sum "$out/module.native-program" | sed 's/ .*//')"
  printf '%s\n' "$native_program_digest" >"$out/module.native-program.sha256"
  cat >"$out/module_0.h" <<'C'
#ifndef FAKE_MODULE_0_H
#define FAKE_MODULE_0_H

#include "native_shim.h"

#include <stdbool.h>
#include <stdint.h>

typedef int64_t native_m0_type_0;
typedef struct native_m0_type_1 {
  int64_t field_0;
  uint64_t field_1;
  uint64_t field_2;
  int64_t field_3;
  native_vec *field_4;
} native_m0_type_1;
typedef const char *native_m0_type_2;
typedef native_vec *native_m0_type_4;
typedef struct native_m0_type_5 {
  int64_t field_0;
  uint64_t field_1;
  uint64_t field_2;
  native_vec *field_3;
  native_m0_type_1 field_4;
  bool field_5;
} native_m0_type_5;
typedef struct native_m0_type_6 {
  int64_t field_0;
  native_vec *field_1;
} native_m0_type_6;
typedef struct native_m0_type_7 { int64_t field_0; } native_m0_type_7;
typedef uint64_t native_m0_type_8;
typedef struct native_m0_type_9 {
  int64_t field_0;
  uint64_t field_1;
} native_m0_type_9;
typedef struct native_m0_type_10_option {
  int64_t tag;
  union {
    void *variant_0;
  } payload;
} native_m0_type_10_option;
typedef struct native_m0_type_10 {
  int64_t field_0;
  bool field_1;
  uint8_t padding_1[7];
  native_m0_type_10_option field_2;
  native_m0_type_10_option field_3;
} native_m0_type_10;
typedef struct native_m0_type_11 {
  int64_t field_0;
  int64_t field_1;
  native_m0_type_10_option field_2;
  native_m0_type_10_option field_3;
  native_vec *field_4;
  native_m0_type_1 field_5;
  uint8_t padding_5[24];
  bool field_6;
  uint8_t padding_6[sizeof(void *) == 8u ? 7 : 3];
  native_vec *field_7;
} native_m0_type_11;

native_m0_type_1 native_m0_fn_2(native_arena *arena, const native_capability *capability, native_m0_type_2 native_v_0, native_m0_type_2 native_v_1, native_m0_type_4 native_v_2, native_m0_type_4 native_v_3);
native_m0_type_9 native_m0_fn_3(native_m0_type_1 native_v_0);
native_m0_type_6 native_m0_fn_5(native_arena *arena, const native_capability *capability, native_m0_type_5 native_v_0);
native_m0_type_0 native_m0_fn_7(void);
native_m0_type_5 native_m0_fn_11(native_arena *arena, const native_capability *capability, native_m0_type_1 native_v_0, native_m0_type_7 native_v_1, native_m0_type_0 native_v_2);
native_m0_type_8 native_m0_fn_13(native_m0_type_7 native_v_0);
native_m0_type_8 native_m0_fn_17(const native_capability *capability, native_m0_type_5 native_v_0);
native_m0_type_7 native_m0_fn_19(native_arena *arena, native_m0_type_4 native_v_0);
native_m0_type_10 native_m0_fn_23(native_arena *arena, const native_capability *capability, native_m0_type_1 native_v_0, uint64_t native_v_1, uint64_t native_v_2, uint64_t native_v_3, native_m0_type_4 native_v_4, uint64_t native_v_5, uint64_t native_v_6, uint64_t native_v_7);
native_m0_type_11 native_m0_fn_29(native_arena *arena, const native_capability *capability, native_m0_type_1 native_v_0, uint64_t native_v_1, uint64_t native_v_2, uint64_t native_v_3, native_m0_type_4 native_v_4, uint64_t native_v_5, uint64_t native_v_6, uint64_t native_v_7, uint64_t native_v_8, uint64_t native_v_9, uint64_t native_v_10, uint64_t native_v_11, uint64_t native_v_12);

#endif
C
  cat >"$out/module_0.c" <<'C'
#include "module_0.h"

native_m0_type_1 native_m0_fn_2(native_arena *arena,
                                  const native_capability *capability,
                                  native_m0_type_2 native_v_0,
                                  native_m0_type_2 native_v_1,
                                  native_m0_type_4 native_v_2,
                                  native_m0_type_4 native_v_3) {
  (void)arena;
  (void)capability;
  (void)native_v_0;
  (void)native_v_1;
  (void)native_v_2;
  (void)native_v_3;
  return (native_m0_type_1){.field_0 = 0};
}

native_m0_type_9 native_m0_fn_3(native_m0_type_1 native_v_0) {
  return (native_m0_type_9){.field_0 = native_v_0.field_0, .field_1 = 0};
}

native_m0_type_6 native_m0_fn_5(native_arena *arena,
                                  const native_capability *capability,
                                  native_m0_type_5 native_v_0) {
  (void)arena;
  (void)capability;
  return (native_m0_type_6){.field_0 = native_v_0.field_0,
                            .field_1 = (native_vec *)0};
}

native_m0_type_0 native_m0_fn_7(void) { return 4; }

native_m0_type_5 native_m0_fn_11(native_arena *arena,
                                   const native_capability *capability,
                                   native_m0_type_1 native_v_0,
                                   native_m0_type_7 native_v_1,
                                   native_m0_type_0 native_v_2) {
  (void)arena;
  (void)capability;
  return (native_m0_type_5){
      .field_0 = native_v_0.field_0 + native_v_1.field_0 + native_v_2};
}

native_m0_type_8 native_m0_fn_13(native_m0_type_7 native_v_0) {
  (void)native_v_0;
  return 0;
}

native_m0_type_8 native_m0_fn_17(const native_capability *capability,
                                   native_m0_type_5 native_v_0) {
  (void)capability;
  (void)native_v_0;
  return 0;
}

native_m0_type_7 native_m0_fn_19(native_arena *arena,
                                   native_m0_type_4 native_v_0) {
  (void)arena;
  return (native_m0_type_7){.field_0 = native_v_0 == (native_vec *)0 ? 2 : 0};
}

native_m0_type_10 native_m0_fn_23(native_arena *arena,
                                    const native_capability *capability,
                                    native_m0_type_1 native_v_0,
                                    uint64_t native_v_1,
                                    uint64_t native_v_2,
                                    uint64_t native_v_3,
                                    native_m0_type_4 native_v_4,
                                    uint64_t native_v_5,
                                    uint64_t native_v_6,
                                    uint64_t native_v_7) {
  (void)arena;
  (void)capability;
  (void)native_v_0;
  (void)native_v_1;
  (void)native_v_2;
  (void)native_v_3;
  (void)native_v_4;
  (void)native_v_5;
  (void)native_v_6;
  (void)native_v_7;
  return (native_m0_type_10){.field_0 = 0};
}

native_m0_type_11 native_m0_fn_29(native_arena *arena,
                                    const native_capability *capability,
                                    native_m0_type_1 native_v_0,
                                    uint64_t native_v_1,
                                    uint64_t native_v_2,
                                    uint64_t native_v_3,
                                    native_m0_type_4 native_v_4,
                                    uint64_t native_v_5,
                                    uint64_t native_v_6,
                                    uint64_t native_v_7,
                                    uint64_t native_v_8,
                                    uint64_t native_v_9,
                                    uint64_t native_v_10,
                                    uint64_t native_v_11,
                                    uint64_t native_v_12) {
  (void)arena;
  (void)capability;
  (void)native_v_0;
  (void)native_v_1;
  (void)native_v_2;
  (void)native_v_3;
  (void)native_v_4;
  (void)native_v_5;
  (void)native_v_6;
  (void)native_v_7;
  (void)native_v_8;
  (void)native_v_9;
  (void)native_v_10;
  (void)native_v_11;
  (void)native_v_12;
  return (native_m0_type_11){.field_0 = 0};
}

C
  cat >"$out/native_shim.h" <<'C'
#ifndef FAKE_NATIVE_SHIM_H
#define FAKE_NATIVE_SHIM_H

#include <stdint.h>

typedef struct native_arena { int marker; } native_arena;
typedef struct native_capability { int marker; } native_capability;
typedef struct native_vec { int64_t length; } native_vec;

#define NATIVE_TRAP_INVALID_ARGUMENT UINT32_C(1)
#define NATIVE_TRAP_OVERFLOW UINT32_C(2)
#define NATIVE_TRAP_ARENA_EXHAUSTED UINT32_C(3)
#define NATIVE_TRAP_OUT_OF_RANGE UINT32_C(4)
#define NATIVE_TRAP_IO UINT32_C(5)

typedef void (*native_trap_reporter)(uint32_t code);
void native_set_trap_reporter(native_trap_reporter reporter);

int fake_native_shim(void);
#endif
C
    printf '%s\n' '/* fake Unicode data */' >"$out/native_unicode15_data.h"
    printf '%s\n' 'fake Unicode license' >"$out/UNICODE-LICENSE.txt"
  [[ "$want_qbe" == 0 ]] ||
    printf '%s\n' 'export function w $main() { ret 0 }' >"$out/module_0.ssa"
  cat >"$out/native_shim.c" <<'C'
#include "native_shim.h"
int fake_native_shim(void) { return 0; }
void native_set_trap_reporter(native_trap_reporter reporter) { (void)reporter; }
C
  missing_symbol=0
  duplicate_symbol=0
  bad_arity=0
  for source in "${sources[@]}"; do
    grep -Fq MISSING_SERVER_SYMBOL "$source" && missing_symbol=1
    grep -Fq DUPLICATE_SERVER_SYMBOL "$source" && duplicate_symbol=1
    grep -Fq BAD_SERVER_ARITY "$source" && bad_arity=1
  done
  if [[ "$bad_arity" == 1 ]]; then
    sed -i \
      '/native_m0_fn_5/s/);$/, native_m0_type_0 native_v_1);/' \
      "$out/module_0.h"
  fi
  {
    printf '%s\n' "${FAKE_NATIVE_REPORT_FORMAT:-beagle-native-report/v1}"
    printf '%s\n' \
      'stage source-freeze ACCEPTED' \
      'stage source-to-typed ACCEPTED' \
      'stage typed-to-native COMPLETE' \
      'native-lowering-result NativeLoweringCompleteV0' \
      'stage native-to-epoch COMPLETE' \
      'epoch-regions-minted 0' \
      "native-provenance-v0 epoch sha256:$native_program_digest"
    printf '%s\n' 'materialize-c17 OK module_0.h module_0.c'
    if [[ "$want_qbe" == 1 ]]; then
      if [[ -n "${FAKE_QBE_REFUSAL:-}" ]]; then
        printf 'materialize-qbe REFUSED %s\n' "$FAKE_QBE_REFUSAL"
      else
        printf '%s\n' 'materialize-qbe OK module_0.ssa'
      fi
    fi
    printf '%s\n' \
      'lowered fn_7 server-generated-abi 1 blocks' \
      'lowered fn_2 server-store-boot! 1 blocks' \
      'lowered fn_11 server-store-dispatch! 1 blocks' \
      'lowered fn_3 server-store-shutdown 1 blocks' \
      'lowered fn_19 server-codec-read-request! 1 blocks' \
      'lowered fn_5 server-codec-write-response! 1 blocks' \
      'lowered fn_13 server-codec-release-request 1 blocks'
    [[ "$missing_symbol" == 1 ]] ||
      printf '%s\n' 'lowered fn_17 server-codec-release-response 1 blocks'
    [[ "$duplicate_symbol" == 0 ]] ||
      printf '%s\n' 'lowered fn_23 server-store-boot! 1 blocks'
    printf '%s\n' \
      'lowered fn_23 server-compile-query! 1 blocks' \
      'lowered fn_29 server-compile-append! 1 blocks'
    printf '%s\n' \
      'obligation-projection PASS valid-ssa' \
      'obligation-projection PASS exhaustive-matches' \
      'obligation-projection PASS closed-layouts' \
      'obligation-projection PASS checked-arithmetic' \
      'obligation-projection PASS legal-abi' \
      'obligation-projection PASS discharged-tokens' \
      'obligation-projection PASS bounded-effects' \
      'obligation-projection PASS epoch-soundness' \
      'obligation-projection PASS leak-freedom' \
      'obligation-projection PASS deterministic-parallelism'
    if [[ "$want_qbe" == 1 && -n "${FAKE_QBE_REFUSAL:-}" ]]; then
      printf '%s\n' 'result FAIL materialization'
    else
      printf '%s\n' 'result PASS'
    fi
  } >"$out/report.txt"
  if [[ "$want_qbe" == 1 && -n "${FAKE_MUTATE_SOURCE:-}" ]]; then
    printf '%s\n' '#lang beagle' '(ns demo.main)' \
      '(defn start [] Nil nil)' ';; changed during materialization' \
      >"$FAKE_MUTATE_SOURCE"
  fi
  if [[ "$want_qbe" == 1 && -n "${FAKE_MUTATE_HOST_ROOT:-}" ]]; then
    for input in server_host.c server_host.h server_generated.c; do
      printf '%s\n' 'changed during materialization' \
        >"$FAKE_MUTATE_HOST_ROOT/native/$input"
    done
  fi
  # A refused generation is reported on stderr but publishes no artifacts.
  if [[ "$want_qbe" == 1 && -n "${FAKE_QBE_REFUSAL:-}" ]]; then
    cat "$out/report.txt" >&2
    rm -f "$out/source.facts" "$out/report.txt" \
      "$out/module.native-program" "$out/module.native-program.sha256" \
      "$out/module_0.h" "$out/module_0.c" "$out/module_0.ssa" \
      "$out/native_shim.h" "$out/native_shim.c" \
      "$out/native_unicode15_data.h" "$out/UNICODE-LICENSE.txt"
    exit 1
  fi
  exit 0
fi
exit 97
FAKE_BEAGLE
chmod +x "$scratch/tool/bin/beagle"

# The builder identifies Beagle by hashing every file its compiler reads out of
# the tree -- bin/, share/, beagle-lib/, native-core/{bin,shim,src} -- and
# refuses a sweep too small to be one. The fake compiler above IS the whole
# materializer here, so its tree is fabricated to match: deterministic
# stand-ins under each swept root, plus one file under each path the sweep
# prunes, so the content-keying assertions at the end have both cases to check.
seed_beagle_tree() {
  local root="$1" directory index
  for directory in bin share beagle-lib native-core/bin native-core/shim \
    native-core/src; do
    mkdir -p "$root/$directory"
    for index in $(seq -w 1 20); do
      printf 'fixture %s/%s\n' "$directory" "$index" \
        >"$root/$directory/module_$index.txt"
    done
  done
  mkdir -p "$root/beagle-lib/compiled" "$root/bin/test"
  mkdir -p "$root/native-core/shim/third_party/ffc"
  printf '%s\n' 'fixture bytecode' >"$root/beagle-lib/compiled/module_01.zo"
  printf '%s\n' 'fixture bin fixture' >"$root/bin/test/fixture.txt"
  printf '%s\n' 'fixture corpus' >"$root/native-core/src/shapes_corpus.bclj"
  cat >"$root/share/targets.sh" <<'TARGETS'
declare -A BEAGLE_MATERIALIZER_ABIS=([c17]='lp64 wasm32' [qbe]=lp64 [wasm]=wasm32)
TARGETS
  printf '%s\n' 'fixture ffc MIT license' \
    >"$root/native-core/shim/third_party/ffc/LICENSE-MIT"
  printf '%s\n' 'fixture ffc provenance' \
    >"$root/native-core/shim/third_party/ffc/PROVENANCE"
  printf '%s\n' "$beagle_pin" >"$root/BEAGLE_REVISION"
}
seed_beagle_tree "$scratch/tool"

cat >"$scratch/tool/bin/wasi-cc" <<'FAKE_WASI_CC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' 'fixture wasi clang 21.1.8'
  exit 0
fi
output=""
compile=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) compile=1; shift ;;
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]] || exit 94
if [[ "$compile" == 1 ]]; then
  printf '%s\n' 'fixture wasm object' >"$output"
else
  printf '\0asm\1\0\0\0' >"$output"
fi
FAKE_WASI_CC
chmod +x "$scratch/tool/bin/wasi-cc"

cat >"$scratch/tool/bin/wasm-tools" <<'FAKE_WASM_TOOLS'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) printf '%s\n' 'wasm-tools fixture 1.244.0' ;;
  print) printf '%s\n' '(module)' ;;
  *) exit 95 ;;
esac
FAKE_WASM_TOOLS
chmod +x "$scratch/tool/bin/wasm-tools"

printf '%s\n' 'store-wasm-embed-seams/v1' >"$scratch/wasm-embed.seams"
printf '%s\n' 'fixture wasi toolchain licenses' >"$scratch/wasi-notices.txt"

ffc_notice_root="$scratch/tool/native-core/shim/third_party/ffc"
assert_ffc_notices() {
  local artifact_root="$1" notice
  for notice in LICENSE-MIT PROVENANCE; do
    [[ -f "$artifact_root/THIRD-PARTY/ffc/$notice" &&
      ! -L "$artifact_root/THIRD-PARTY/ffc/$notice" ]] ||
      fail "artifact omitted its regular ffc $notice"
    cmp -s "$ffc_notice_root/$notice" \
      "$artifact_root/THIRD-PARTY/ffc/$notice" ||
      fail "artifact changed its ffc $notice"
  done
}

printf '%s\n' '#lang beagle' '(ns demo.main)' '(defn start [] Nil nil)' \
  >"$scratch/sources/good.bgl"
ledger="$scratch/qbe-frontier.ledger"
printf '%s\n' '# scratch QBE frontier ledger' >"$ledger"
build_env=(
  env
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle"
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache"
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}"
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger"
  FAKE_NATIVE_CALLS="$calls"
)

# The wrapper's outer deadline is a containment backstop: it reserves the
# entire lowerer budget after every named prerequisite, plus Core's named TERM
# grace. Observe the exported values through the fake compiler rather than run
# a Store product build.
timeout_observations="$scratch/timeout-observations"
: >"$timeout_observations"
timeout_contract_artifact="$("${build_env[@]}" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-timeout-contract" \
  FAKE_TIMEOUT_OBSERVATIONS="$timeout_observations" \
  "$builder" --host program --entry demo.main/start \
  "$scratch/sources/good.bgl")" ||
  fail "timeout contract observation build failed"
[[ -f "$timeout_contract_artifact/READY" ]] ||
  fail "timeout contract observation build produced no ready artifact"
grep -Fqx \
  'ast=120 facts=120 compiler=900 lowering=720 validation=360 lock=30 grace=5 overall=2405' \
  "$timeout_observations" ||
  fail "Store defaults did not derive the outer timeout from named phase budgets"

# A lowerer-owned timeout must still reach the caller's captured diagnostics;
# the wrapper may not replace it with a silent outer-supervisor expiration.
if "${build_env[@]}" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-timeout-report" \
  FAKE_CORE_LOWERING_TIMEOUT=1 \
  "$builder" --host program --entry demo.main/start \
  "$scratch/sources/good.bgl" \
  >"$scratch/lower-timeout.out" 2>"$scratch/lower-timeout.err"; then
  fail "lowerer timeout unexpectedly succeeded"
fi
grep -Fq 'beagle build: phase core-lowering TIMEOUT (124)' \
  "$scratch/lower-timeout.err" ||
  fail "lowerer timeout was not reported by the Store wrapper"
grep -Fq 'beagle-store-native-build: Beagle native program materialization' \
  "$scratch/lower-timeout.err" ||
  fail "Store wrapper did not preserve its materialization failure report"

printf '%s\n' '1111111111111111111111111111111111111111' \
  >"$scratch/tool/BEAGLE_REVISION"
if "${build_env[@]}" "$builder" --host program --entry demo.main/start \
    "$scratch/sources/good.bgl" \
    >"$scratch/beagle-pin-mismatch.out" 2>"$scratch/beagle-pin-mismatch.err"; then
  fail "native builder accepted a mismatched Beagle revision"
fi
grep -Fq "differs from pinned revision $beagle_pin" \
  "$scratch/beagle-pin-mismatch.err" ||
  fail "Beagle pin mismatch failed for the wrong reason"
if "${build_env[@]}" BEAGLE_STORE_ALLOW_UNPINNED_BEAGLE=yes \
    "$builder" --host program --entry demo.main/start \
    "$scratch/sources/good.bgl" \
    >"$scratch/beagle-pin-invalid-override.out" \
    2>"$scratch/beagle-pin-invalid-override.err"; then
  fail "native builder accepted an invalid Beagle pin override"
fi
grep -Fq 'BEAGLE_STORE_ALLOW_UNPINNED_BEAGLE must be 1 or unset' \
  "$scratch/beagle-pin-invalid-override.err" ||
  fail "invalid Beagle pin override failed for the wrong reason"
override_artifact="$("${build_env[@]}" \
  BEAGLE_STORE_ALLOW_UNPINNED_BEAGLE=1 \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-pin-override" \
  "$builder" --host program --entry demo.main/start \
  "$scratch/sources/good.bgl")" ||
  fail "explicit Beagle pin override did not permit a local build"
[[ -f "$override_artifact/READY" ]] ||
  fail "explicit Beagle pin override produced no ready artifact"
override_calls="$(wc -l <"$calls")"
printf '%s\n' "$beagle_pin" >"$scratch/tool/BEAGLE_REVISION"
pinned_hit="$("${build_env[@]}" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-pin-override" \
  "$builder" --host program --entry demo.main/start \
  "$scratch/sources/good.bgl")" ||
  fail "pinned Beagle revision did not reuse a content-equivalent cache entry"
[[ "$pinned_hit" == "$override_artifact" &&
  "$(wc -l <"$calls")" == "$override_calls" ]] ||
  fail "Beagle revision changed the content-keyed native program cache"
! grep -Fq "$beagle_pin" "$pinned_hit/input.manifest" ||
  fail "Beagle revision leaked into the native program cache identity"

# A checkout-owned launch snapshot carries the checkout-relative module root
# into Core, so its logical source ID survives the random snapshot directory.
root_observations="$scratch/module-root.observations"
: >"$root_observations"
checkout_artifact="$(env \
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-checkout-source" \
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}" \
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger" \
  FAKE_NATIVE_CALLS="$calls" \
  FAKE_MODULE_ROOT_OBSERVATIONS="$root_observations" \
  "$builder" --host program --entry demo.main/start \
  "$repo/src/commit_plan.bgl")" ||
  fail "checkout-owned source snapshot build failed"
[[ -f "$checkout_artifact/READY" ]] ||
  fail "checkout-owned source snapshot produced no ready artifact"
[[ "$(sort -u "$root_observations")" == \
  store/src=*'/sources.'* ]] ||
  fail "checkout-owned source snapshot omitted its stable git-relative root"

# A QBE refusal invokes a second C17 materialization. Both passes must consume
# the launch snapshot even when the original worktree source changes between
# them, and the private staging path must not become the source's logical name.
snapshot_source="$scratch/sources/snapshot-drift.bgl"
printf '%s\n' '#lang beagle' '(ns demo.main)' \
  '(defn start [] Nil nil)' ';; launch bytes' >"$snapshot_source"
snapshot_launch_digest="$(sha256sum "$snapshot_source" | sed 's/ .*//')"
snapshot_observations="$scratch/snapshot-source.observations"
: >"$snapshot_observations"
snapshot_ledger="$scratch/snapshot-qbe-frontier.ledger"
printf '%s\n' '# snapshot QBE frontier ledger' \
  "$(printf 'demo.main/start\tunsupported-value-semantics\thash')" \
  >"$snapshot_ledger"
snapshot_artifact="$(env \
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-snapshot" \
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}" \
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$snapshot_ledger" \
  FAKE_NATIVE_CALLS="$calls" \
  FAKE_QBE_REFUSAL='unsupported native value-semantics op: hash' \
  FAKE_MUTATE_SOURCE="$snapshot_source" \
  FAKE_SOURCE_OBSERVATIONS="$snapshot_observations" \
  "$builder" --host program --entry demo.main/start "$snapshot_source")" ||
  fail "source snapshot did not survive mutation between materializers"
[[ -f "$snapshot_artifact/READY" ]] ||
  fail "source snapshot build did not publish a ready native program"
grep -Fqx ';; changed during materialization' <(tail -n 1 "$snapshot_source") ||
  fail "source snapshot regression did not mutate the original source"
[[ "$(wc -l <"$snapshot_observations")" == "2" ]] ||
  fail "source snapshot build did not run both materializer passes"
[[ "$(awk -F '\t' -v digest="$snapshot_launch_digest" \
  '$3 == digest { count += 1 } END { print count + 0 }' \
  "$snapshot_observations")" == "2" ]] ||
  fail "a repeated materializer did not consume the launch source bytes"
! grep -Fq "$snapshot_source" "$snapshot_observations" ||
  fail "a materializer received the mutable worktree source path"
[[ "$(awk -F '\t' '$2 == "snapshot-drift.bgl" { count += 1 } \
  END { print count + 0 }' "$snapshot_observations")" == "2" ]] ||
  fail "the source snapshot did not preserve its relative logical path"

adapter="$scratch/sources/server_generated.c"
cat >"$adapter" <<'C'
#include "server_host.h"
#include "server_symbols.h"

#include <stdlib.h>

static void clear_error(char *error, size_t capacity) {
  if (capacity > 0u) {
    error[0] = '\0';
  }
}

uint32_t store_server_generated_abi(void) {
  native_arena arena = {0};
  native_capability capability = {0};
  native_vec bytes = {0};
  store_server_store_boot_return boot =
      BEAGLE_STORE_SERVER_CALL_STORE_BOOT(
          &arena, &capability, "log", "space", &bytes, &bytes);
  store_server_codec_read_request_return request =
      BEAGLE_STORE_SERVER_CALL_CODEC_READ_REQUEST(
          &arena, &capability, &bytes);
  store_server_store_dispatch_return dispatched =
      BEAGLE_STORE_SERVER_CALL_STORE_DISPATCH(
          &arena, &capability, boot, request, 0);
  store_server_store_shutdown_return stopped =
      BEAGLE_STORE_SERVER_CALL_STORE_SHUTDOWN(&arena, &capability, boot);
  store_server_codec_write_response_return written =
      BEAGLE_STORE_SERVER_CALL_CODEC_WRITE_RESPONSE(
          &arena, &capability, dispatched);
  store_server_codec_release_request_return request_released =
      BEAGLE_STORE_SERVER_CALL_CODEC_RELEASE_REQUEST(
          &arena, &capability, request);
  store_server_codec_release_response_return response_released =
      BEAGLE_STORE_SERVER_CALL_CODEC_RELEASE_RESPONSE(
          &arena, &capability, dispatched);
  store_server_generated_abi_return abi =
      BEAGLE_STORE_SERVER_CALL_GENERATED_ABI(&arena, &capability);
  store_server_compile_query_return compile_query =
      BEAGLE_STORE_SERVER_CALL_COMPILE_QUERY(
          &arena, &capability, boot, UINT64_C(0), UINT64_C(0),
          UINT64_C(0), &bytes, UINT64_C(0), UINT64_C(0), UINT64_C(0));
  store_server_compile_append_return compile_append =
      BEAGLE_STORE_SERVER_CALL_COMPILE_APPEND(
          &arena, &capability, boot, UINT64_C(0), UINT64_C(0),
          UINT64_C(0), &bytes, UINT64_C(0), UINT64_C(0), UINT64_C(0),
          UINT64_C(0), UINT64_C(0), UINT64_C(0), UINT64_C(0), UINT64_C(0));
  int64_t direct_status = stopped.field_0 + written.field_0;
  int64_t valid_log_bytes = boot.field_3;
  native_vec *boot_append = boot.field_4;
  native_vec *response_append = dispatched.field_3;
  native_vec *response_bytes = written.field_1;

  (void)direct_status;
  (void)valid_log_bytes;
  (void)boot_append;
  (void)response_append;
  (void)response_bytes;
  (void)request_released;
  (void)response_released;
  (void)compile_query;
  (void)compile_append;
  return (uint32_t)abi;
}

int store_server_store_boot(const char *log_path,
                               const char *space_id,
                               uint64_t memory_budget_bytes,
                               store_server_store **store_out,
                               char *error,
                               size_t capacity) {
  (void)log_path;
  (void)space_id;
  (void)memory_budget_bytes;
  *store_out = NULL;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

int store_server_store_boot_with_host(const char *log_path,
                                     const char *space_id,
                                     const store_server_host_v1 *host,
                                     store_server_store **store_out,
                                     char *error, size_t capacity) {
  (void)log_path;
  (void)space_id;
  (void)host;
  *store_out = NULL;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

int store_server_store_dispatch(store_server_store *store,
                                   const store_server_request *request,
                                   store_server_response **response_out,
                                   char *error,
                                   size_t capacity) {
  (void)store;
  (void)request;
  *response_out = NULL;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

int store_server_compile_query(
    store_server_store *store, const store_server_compile_key *key,
    store_server_compile_value *value,
    store_server_compile_query_result *result, char *error,
    size_t capacity) {
  (void)store;
  (void)key;
  if (value != NULL) {
    *value = (store_server_compile_value){0};
  }
  if (result != NULL) {
    *result = (store_server_compile_query_result){
        .status = BEAGLE_STORE_SERVER_FATAL,
        .found = false,
        .outcome = BEAGLE_STORE_SERVER_COMPILE_COLD,
    };
  }
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

int store_server_compile_append(
    store_server_store *store, const store_server_compile_key *key,
    const store_server_compile_value *value,
    store_server_compile_query_result *result, char *error,
    size_t capacity) {
  (void)store;
  (void)key;
  (void)value;
  if (result != NULL) {
    *result = (store_server_compile_query_result){
        .status = BEAGLE_STORE_SERVER_FATAL,
        .found = false,
        .outcome = BEAGLE_STORE_SERVER_COMPILE_RETAINED,
    };
  }
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

void store_server_compile_value_release(store_server_compile_value *value) {
  if (value != NULL) {
    *value = (store_server_compile_value){0};
  }
}

int store_server_store_shutdown(store_server_store *store,
                                   char *error,
                                   size_t capacity) {
  (void)store;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_OK;
}

int store_server_store_compact_idle(store_server_store *store,
                                       int *compacted_out,
                                       char *error,
                                       size_t capacity) {
  (void)store;
  if (compacted_out != NULL) {
    *compacted_out = 0;
  }
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_OK;
}

int store_server_codec_read_request(int fd,
                                       store_server_request **request_out,
                                       char *error,
                                       size_t capacity) {
  (void)fd;
  *request_out = NULL;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

int store_server_codec_decode_request(const uint8_t *bytes, size_t length,
                                     store_server_request **request_out,
                                     char *error, size_t capacity) {
  (void)bytes;
  (void)length;
  *request_out = NULL;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

int store_server_codec_encode_response(const store_server_response *response,
                                      uint8_t **bytes_out,
                                      size_t *length_out, char *error,
                                      size_t capacity) {
  (void)response;
  *bytes_out = NULL;
  *length_out = 0u;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

void store_server_codec_release_bytes(uint8_t *bytes) { free(bytes); }

int store_server_codec_write_response(
    int fd,
    const store_server_response *response,
    char *error,
    size_t capacity) {
  (void)fd;
  (void)response;
  clear_error(error, capacity);
  return BEAGLE_STORE_SERVER_FATAL;
}

void store_server_codec_release_request(store_server_request *request) {
  (void)request;
}

void store_server_codec_release_response(store_server_response *response) {
  (void)response;
}
C

cp "$adapter" "$scratch/server_generated.pristine.c"

calls_before_host="$(wc -l <"$calls")"
host_artifact="$("${build_env[@]}" "$builder" --host server \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "server host build failed"
[[ -f "$host_artifact/READY" && -x "$host_artifact/bin/beagle-store-server-native" ]] ||
  fail "server host artifact is not ready and executable"
assert_ffc_notices "$host_artifact"
host_program="$scratch/cache/.programs/$(sed -n 's/^program=//p' \
  "$host_artifact/input.manifest")"
assert_ffc_notices "$host_program"
grep -Fqx 'native-host-abi PASS host=server exports=10' \
  "$host_artifact/native-host.report.txt" ||
  fail "server host artifact omitted its ten-export receipt"
symbols_header="$host_artifact/server_symbols.h"
[[ -f "$symbols_header" ]] || fail "server host omitted its generated symbol header"
[[ "$(grep -c '^#define BEAGLE_STORE_SERVER_SYMBOL_' "$symbols_header")" == "10" ]] ||
  fail "server symbol header did not contain exactly ten symbol mappings"
[[ "$(grep -c '^#define BEAGLE_STORE_SERVER_CALL_' "$symbols_header")" == "10" ]] ||
  fail "server symbol header did not contain exactly ten normalized calls"
[[ "$(grep -Ec '^typedef [A-Za-z_][A-Za-z0-9_]* store_server_[a-z_]+_(return|arg_[0-9]+);$' "$symbols_header")" == "43" ]] ||
  fail "server symbol header did not contain all forty-three stable type aliases"
required_symbol_lines=(
  '#define BEAGLE_STORE_SERVER_SYMBOL_GENERATED_ABI native_m0_fn_7'
  '#define BEAGLE_STORE_SERVER_SYMBOL_STORE_BOOT native_m0_fn_2'
  '#define BEAGLE_STORE_SERVER_SYMBOL_STORE_DISPATCH native_m0_fn_11'
  '#define BEAGLE_STORE_SERVER_SYMBOL_STORE_SHUTDOWN native_m0_fn_3'
  '#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_READ_REQUEST native_m0_fn_19'
  '#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_WRITE_RESPONSE native_m0_fn_5'
  '#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_REQUEST native_m0_fn_13'
  '#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_RESPONSE native_m0_fn_17'
  '#define BEAGLE_STORE_SERVER_SYMBOL_COMPILE_QUERY native_m0_fn_23'
  '#define BEAGLE_STORE_SERVER_SYMBOL_COMPILE_APPEND native_m0_fn_29'
  'typedef native_m0_type_1 store_server_store_boot_return;'
  'typedef native_m0_type_2 store_server_store_boot_arg_0;'
  'typedef native_m0_type_2 store_server_store_boot_arg_1;'
  'typedef native_m0_type_4 store_server_store_boot_arg_2;'
  'typedef native_m0_type_4 store_server_store_boot_arg_3;'
  'typedef native_m0_type_5 store_server_store_dispatch_return;'
  'typedef native_m0_type_0 store_server_store_dispatch_arg_2;'
  'typedef native_m0_type_9 store_server_store_shutdown_return;'
  'typedef native_m0_type_7 store_server_codec_read_request_return;'
  'typedef native_m0_type_4 store_server_codec_read_request_arg_0;'
  'typedef native_m0_type_6 store_server_codec_write_response_return;'
  'typedef native_m0_type_5 store_server_codec_write_response_arg_0;'
  'typedef native_m0_type_8 store_server_codec_release_request_return;'
  'typedef native_m0_type_7 store_server_codec_release_request_arg_0;'
  'typedef native_m0_type_8 store_server_codec_release_response_return;'
  'typedef native_m0_type_5 store_server_codec_release_response_arg_0;'
  'typedef native_m0_type_10 store_server_compile_query_return;'
  'typedef native_m0_type_1 store_server_compile_query_arg_0;'
  'typedef uint64_t store_server_compile_query_arg_1;'
  'typedef uint64_t store_server_compile_query_arg_2;'
  'typedef uint64_t store_server_compile_query_arg_3;'
  'typedef native_m0_type_4 store_server_compile_query_arg_4;'
  'typedef uint64_t store_server_compile_query_arg_5;'
  'typedef uint64_t store_server_compile_query_arg_6;'
  'typedef uint64_t store_server_compile_query_arg_7;'
  'typedef native_m0_type_11 store_server_compile_append_return;'
  'typedef native_m0_type_1 store_server_compile_append_arg_0;'
  'typedef uint64_t store_server_compile_append_arg_1;'
  'typedef uint64_t store_server_compile_append_arg_2;'
  'typedef uint64_t store_server_compile_append_arg_3;'
  'typedef native_m0_type_4 store_server_compile_append_arg_4;'
  'typedef uint64_t store_server_compile_append_arg_5;'
  'typedef uint64_t store_server_compile_append_arg_6;'
  'typedef uint64_t store_server_compile_append_arg_7;'
  'typedef uint64_t store_server_compile_append_arg_8;'
  'typedef uint64_t store_server_compile_append_arg_9;'
  'typedef uint64_t store_server_compile_append_arg_10;'
  'typedef uint64_t store_server_compile_append_arg_11;'
  'typedef uint64_t store_server_compile_append_arg_12;'
  '#define BEAGLE_STORE_SERVER_CALL_GENERATED_ABI(arena, capability) BEAGLE_STORE_SERVER_SYMBOL_GENERATED_ABI()'
  '#define BEAGLE_STORE_SERVER_CALL_STORE_BOOT(arena, capability, arg_0, arg_1, arg_2, arg_3) BEAGLE_STORE_SERVER_SYMBOL_STORE_BOOT((arena), (capability), (arg_0), (arg_1), (arg_2), (arg_3))'
  '#define BEAGLE_STORE_SERVER_CALL_STORE_DISPATCH(arena, capability, arg_0, arg_1, arg_2) BEAGLE_STORE_SERVER_SYMBOL_STORE_DISPATCH((arena), (capability), (arg_0), (arg_1), (arg_2))'
  '#define BEAGLE_STORE_SERVER_CALL_STORE_SHUTDOWN(arena, capability, arg_0) BEAGLE_STORE_SERVER_SYMBOL_STORE_SHUTDOWN((arg_0))'
  '#define BEAGLE_STORE_SERVER_CALL_CODEC_READ_REQUEST(arena, capability, arg_0) BEAGLE_STORE_SERVER_SYMBOL_CODEC_READ_REQUEST((arena), (arg_0))'
  '#define BEAGLE_STORE_SERVER_CALL_CODEC_WRITE_RESPONSE(arena, capability, arg_0) BEAGLE_STORE_SERVER_SYMBOL_CODEC_WRITE_RESPONSE((arena), (capability), (arg_0))'
  '#define BEAGLE_STORE_SERVER_CALL_CODEC_RELEASE_RESPONSE(arena, capability, arg_0) BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_RESPONSE((capability), (arg_0))'
  '#define BEAGLE_STORE_SERVER_CALL_COMPILE_QUERY(arena, capability, arg_0, arg_1, arg_2, arg_3, arg_4, arg_5, arg_6, arg_7) BEAGLE_STORE_SERVER_SYMBOL_COMPILE_QUERY((arena), (capability), (arg_0), (arg_1), (arg_2), (arg_3), (arg_4), (arg_5), (arg_6), (arg_7))'
  '#define BEAGLE_STORE_SERVER_CALL_COMPILE_APPEND(arena, capability, arg_0, arg_1, arg_2, arg_3, arg_4, arg_5, arg_6, arg_7, arg_8, arg_9, arg_10, arg_11, arg_12) BEAGLE_STORE_SERVER_SYMBOL_COMPILE_APPEND((arena), (capability), (arg_0), (arg_1), (arg_2), (arg_3), (arg_4), (arg_5), (arg_6), (arg_7), (arg_8), (arg_9), (arg_10), (arg_11), (arg_12))'
)
for required_line in "${required_symbol_lines[@]}"; do
  grep -Fqx -- "$required_line" "$symbols_header" ||
    fail "server symbol header omitted: $required_line"
done
if "$host_artifact/bin/beagle-store-server-native" serve not-a-port \
    >"$scratch/host.out" 2>"$scratch/host.err"; then
  fail "server host accepted an invalid port"
fi
grep -Fq 'beagle-store-server-native: invalid port: not-a-port' \
  "$scratch/host.err" || fail "linked server host main did not run"

rm "$host_program/THIRD-PARTY/ffc/PROVENANCE"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/good.bgl" \
    >"$scratch/program-notice.out" 2>"$scratch/program-notice.err"; then
  fail "native program cache hit accepted a missing ffc notice"
fi
grep -Fq 'native artifact omitted its ffc notice:' \
  "$scratch/program-notice.err" ||
  fail "missing native program ffc notice failed for the wrong reason"
cp "$ffc_notice_root/PROVENANCE" \
  "$host_program/THIRD-PARTY/ffc/PROVENANCE"

printf '%s\n' 'tampered license' \
  >"$host_artifact/THIRD-PARTY/ffc/LICENSE-MIT"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/good.bgl" \
    >"$scratch/host-notice.out" 2>"$scratch/host-notice.err"; then
  fail "native host cache hit accepted a changed ffc notice"
fi
grep -Fq 'native artifact ffc notice differs from the Beagle source:' \
  "$scratch/host-notice.err" ||
  fail "changed native host ffc notice failed for the wrong reason"
cp "$ffc_notice_root/LICENSE-MIT" \
  "$host_artifact/THIRD-PARTY/ffc/LICENSE-MIT"

host_hit="$("${build_env[@]}" "$builder" --host server \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "server host cache hit failed"
[[ "$host_hit" == "$host_artifact" ]] || fail "server host missed the cache"
[[ "$(wc -l <"$calls")" == "$((calls_before_host + 1))" ]] ||
  fail "server host cache hit rebuilt a materializer projection"

calls_before_embed="$(wc -l <"$calls")"
embed_artifact="$("${build_env[@]}" "$builder" --host embed \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "embed host build failed"
[[ -f "$embed_artifact/READY" && -f "$embed_artifact/include/store.h" &&
  -f "$embed_artifact/lib/libbeagle_store.a" &&
  -f "$embed_artifact/lib/libbeagle_store.so" ]] ||
  fail "embed host artifact omitted its public libraries"
assert_ffc_notices "$embed_artifact"
grep -Fqx 'native-host-abi PASS host=embed exports=10 version=1' \
  "$embed_artifact/native-host.report.txt" ||
  fail "embed host artifact omitted its public ABI receipt"
cat >"$scratch/embed-consumer.c" <<'C'
#include <store.h>
int main(void) { return store_abi_version() == BEAGLE_STORE_ABI_VERSION ? 0 : 1; }
C
"${CC:-cc}" -std=c17 -pedantic -Wall -Wextra -Werror -pthread \
  -I"$embed_artifact/include" "$scratch/embed-consumer.c" \
  "$embed_artifact/lib/libbeagle_store.a" -o "$scratch/embed-static"
"$scratch/embed-static" || fail "static embed library did not run"
"${CC:-cc}" -std=c17 -pedantic -Wall -Wextra -Werror -pthread \
  -I"$embed_artifact/include" "$scratch/embed-consumer.c" \
  -L"$embed_artifact/lib" -Wl,-rpath,"$embed_artifact/lib" -lbeagle_store \
  -o "$scratch/embed-shared"
"$scratch/embed-shared" || fail "shared embed library did not run"
embed_hit="$("${build_env[@]}" "$builder" --host embed \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "embed host cache hit failed"
[[ "$embed_hit" == "$embed_artifact" ]] || fail "embed host missed the cache"
[[ "$(wc -l <"$calls")" == "$calls_before_embed" ]] ||
  fail "embed host rebuilt the shared native program"
[[ "$(find "$scratch/cache/.programs" -mindepth 2 -maxdepth 2 \
  -name READY | wc -l)" == "1" ]] ||
  fail "server and embed did not share exactly one native program"

# The wasm-embed host is refusal-visible without its toolchain: it names the
# missing tool instead of degrading to the native compiler. Its positive path
# needs a real wasi link and lives in tests/store_wasm_embed_smoke.sh.
if env -u BEAGLE_STORE_WASI_CC -u WASI_CC "${build_env[@]}" "$builder" \
    --host wasm-embed --abi wasm32 "$scratch/sources/good.bgl" \
    >"$scratch/wasm-no-cc.out" 2>"$scratch/wasm-no-cc.err"; then
  fail "wasm-embed host built without a wasi compiler"
fi
grep -Fq 'set BEAGLE_STORE_WASI_CC to an executable wasi C17 compiler' \
  "$scratch/wasm-no-cc.err" ||
  fail "wasm-embed host did not name the missing BEAGLE_STORE_WASI_CC"
if "${build_env[@]}" "$builder" --host wasm-embed \
    "$scratch/sources/good.bgl" \
    >"$scratch/wasm-no-abi.out" 2>"$scratch/wasm-no-abi.err"; then
  fail "wasm-embed host built at the default ABI"
fi
grep -Fq -- '--host wasm-embed needs --abi wasm32' "$scratch/wasm-no-abi.err" ||
  fail "wasm-embed host did not name its ABI coupling"
if "${build_env[@]}" "$builder" --host embed --abi wasm32 \
    "$scratch/sources/good.bgl" \
    >"$scratch/embed-wasm-abi.out" 2>"$scratch/embed-wasm-abi.err"; then
  fail "embed host accepted a non-native ABI"
fi
grep -Fq -- '--abi wasm32 needs --host program' "$scratch/embed-wasm-abi.err" ||
  fail "embed host did not refuse a non-native ABI by name"

wasm_build_env=(
  env
  PATH="$scratch/tool/bin:$PATH"
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle"
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-wasm"
  BEAGLE_STORE_WASI_CC="$scratch/tool/bin/wasi-cc"
  BEAGLE_STORE_WASI_NOTICES="$scratch/wasi-notices.txt"
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger"
  BEAGLE_STORE_WASM_SEAMS_LEDGER="$scratch/wasm-embed.seams"
  FAKE_NATIVE_CALLS="$calls"
)
if env -u BEAGLE_STORE_WASI_NOTICES PATH="$scratch/tool/bin:$PATH" \
    BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle" \
    BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-wasm-missing-notices" \
    BEAGLE_STORE_WASI_CC="$scratch/tool/bin/wasi-cc" \
    BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger" \
    BEAGLE_STORE_WASM_SEAMS_LEDGER="$scratch/wasm-embed.seams" \
    FAKE_NATIVE_CALLS="$calls" \
    "$builder" --host wasm-embed --abi wasm32 \
    "$scratch/sources/good.bgl" \
    >"$scratch/wasm-no-notices.out" 2>"$scratch/wasm-no-notices.err"; then
  fail "wasm-embed host built without its toolchain license bundle"
fi
grep -Fq 'set BEAGLE_STORE_WASI_NOTICES to the wasi toolchain license bundle' \
  "$scratch/wasm-no-notices.err" ||
  fail "wasm-embed host did not name the missing BEAGLE_STORE_WASI_NOTICES"

printf '%s\n' \
  "$(printf 'store-native-server@wasm32\tabi-profile\twasm32')" >>"$ledger"
calls_before_wasm="$(wc -l <"$calls")"
wasm_artifact="$("${wasm_build_env[@]}" "$builder" \
  --host wasm-embed --abi wasm32 "$scratch/sources/good.bgl")" ||
  fail "fixture wasm-embed host build failed"
[[ "$(sed -n "$((calls_before_wasm + 1)),\$p" "$calls" | tr '\n' ' ')" == \
  "build-c17 " ]] ||
  fail "wasm32 build did not use exactly one C17 materialization"
grep -Fqx 'qbe-profile-boundary/v1' \
  "$wasm_artifact/qbe-probe.report.txt" ||
  fail "wasm32 build omitted its declared QBE profile boundary"
grep -Fqx 'native-qbe-frontier REFUSED scope=store-native-server@wasm32 ledger=abi-profile/wasm32' \
  "$wasm_artifact/native-host.report.txt" ||
  fail "wasm32 build omitted its QBE profile boundary receipt"
wasm_notice="$wasm_artifact/THIRD-PARTY/WASI-TOOLCHAIN-LICENSES.txt"
[[ -f "$wasm_artifact/READY" && -f "$wasm_artifact/lib/libstore.wasm" &&
  -f "$wasm_notice" && ! -L "$wasm_notice" &&
  -f "$wasm_artifact/provenance.manifest" &&
  ! -L "$wasm_artifact/provenance.manifest" ]] ||
  fail "wasm-embed artifact omitted its regular toolchain license bundle"
cmp -s "$scratch/wasi-notices.txt" "$wasm_notice" ||
  fail "wasm-embed artifact changed its toolchain license bundle"
wasi_notice_sha256="$(sha256sum "$scratch/wasi-notices.txt" | sed 's/ .*//')"
grep -Fqx "wasi-notices-sha256 $wasi_notice_sha256" \
  "$wasm_artifact/input.manifest" ||
  fail "wasm-embed input manifest omitted the toolchain license digest"
wasm_hit="$("${wasm_build_env[@]}" "$builder" \
  --host wasm-embed --abi wasm32 "$scratch/sources/good.bgl")" ||
  fail "fixture wasm-embed cache hit failed"
[[ "$wasm_hit" == "$wasm_artifact" ]] || fail "fixture wasm-embed missed the cache"

provenance="$wasm_artifact/provenance.manifest"
grep -Fqx 'beagle-store-native-build-provenance/v2' "$provenance" ||
  fail "wasm-embed provenance omitted its format"
grep -Fqx "beagle-revision $beagle_pin" "$provenance" ||
  fail "wasm-embed provenance omitted its pinned Beagle revision"
grep -Fqx 'abi wasm32' "$provenance" ||
  fail "wasm-embed provenance omitted its ABI"
grep -Fqx 'host wasm-embed' "$provenance" ||
  fail "wasm-embed provenance omitted its host"
! grep -Fq "$scratch" "$provenance" ||
  fail "wasm-embed provenance leaked a build-local path"
cp "$provenance" "$scratch/provenance.pristine"
printf '%s\n' 'tampered provenance' >"$provenance"
if "${wasm_build_env[@]}" "$builder" --host wasm-embed --abi wasm32 \
    "$scratch/sources/good.bgl" \
    >"$scratch/wasm-provenance-tamper.out" \
    2>"$scratch/wasm-provenance-tamper.err"; then
  fail "wasm-embed cache hit accepted changed provenance"
fi
grep -Fq 'wasm-embed cache entry has invalid Beagle revision provenance:' \
  "$scratch/wasm-provenance-tamper.err" ||
  fail "changed wasm provenance failed for the wrong reason"
cp "$scratch/provenance.pristine" "$provenance"

printf '%s\n' 'tampered wasi licenses' >"$wasm_notice"
if "${wasm_build_env[@]}" "$builder" --host wasm-embed --abi wasm32 \
    "$scratch/sources/good.bgl" \
    >"$scratch/wasm-notice-tamper.out" 2>"$scratch/wasm-notice-tamper.err"; then
  fail "wasm-embed cache hit accepted a changed toolchain license bundle"
fi
grep -Fq 'wasm artifact wasi toolchain license bundle differs from its build input:' \
  "$scratch/wasm-notice-tamper.err" ||
  fail "changed wasm toolchain license bundle failed for the wrong reason"
cp "$scratch/wasi-notices.txt" "$wasm_notice"

printf '%s\n' '#lang beagle' '(ns demo.missing-symbol)' \
  ';; MISSING_SERVER_SYMBOL' >"$scratch/sources/missing-symbol.bgl"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/missing-symbol.bgl" \
    >"$scratch/missing-symbol.out" 2>"$scratch/missing-symbol.err"; then
  fail "server host accepted a missing logical symbol"
fi
grep -Fq \
  'exactly one lowered row for server-codec-release-response (found 0)' \
  "$scratch/missing-symbol.err" ||
  fail "missing server logical symbol did not fail before link"

printf '%s\n' '#lang beagle' '(ns demo.duplicate-symbol)' \
  ';; DUPLICATE_SERVER_SYMBOL' >"$scratch/sources/duplicate-symbol.bgl"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/duplicate-symbol.bgl" \
    >"$scratch/duplicate-symbol.out" 2>"$scratch/duplicate-symbol.err"; then
  fail "server host accepted a duplicate logical symbol"
fi
grep -Fq 'exactly one lowered row for server-store-boot! (found 2)' \
  "$scratch/duplicate-symbol.err" ||
  fail "duplicate server logical symbol did not fail before link"

printf '%s\n' '#lang beagle' '(ns demo.bad-arity)' ';; BAD_SERVER_ARITY' \
  >"$scratch/sources/bad-arity.bgl"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/bad-arity.bgl" \
    >"$scratch/bad-arity.out" 2>"$scratch/bad-arity.err"; then
  fail "server host accepted an unexpected generated arity"
fi
grep -Fq \
  'server-codec-write-response! has 2 source arguments; expected 1' \
  "$scratch/bad-arity.err" ||
  fail "unexpected server prototype arity did not fail before link"

sed '/^void store_server_codec_release_response/,/^}/d' \
  "$adapter" >"$adapter.incomplete"
mv "$adapter.incomplete" "$adapter"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/good.bgl" \
    >"$scratch/missing-export.out" 2>"$scratch/missing-export.err"; then
  fail "server host linked without all ten generated ABI exports"
fi
grep -Fq 'store_server_codec_release_response' "$scratch/missing-export.err" ||
  fail "server host link did not name the missing ABI export"
[[ "$(find "$scratch/cache" -mindepth 2 -maxdepth 2 -name READY | wc -l)" == "2" ]] ||
  fail "failed server host link exposed a READY artifact"
[[ -z "$(find "$scratch/cache/.tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
  fail "failed server host link left temporary artifacts"
[[ -z "$(find "$scratch/cache/.programs/.tmp" -mindepth 1 -maxdepth 1 \
  -print -quit)" ]] ||
  fail "failed native program build left temporary artifacts"

cp "$scratch/server_generated.pristine.c" "$adapter"

grep -Fqx 'native-qbe-frontier OK scope=store-native-server ledger=clean' \
  "$host_artifact/native-host.report.txt" ||
  fail "clean QBE run did not leave a frontier receipt in the host report"
[[ -f "$host_artifact/qbe-frontier.txt" &&
  -f "$host_artifact/qbe-probe.report.txt" ]] ||
  fail "artifact omitted its QBE frontier receipt"
grep -Fqx 'native-qbe-frontier OK scope=store-native-server ledger=clean' \
  "$embed_artifact/native-host.report.txt" ||
  fail "embed host report omitted its QBE frontier receipt"

# A recorded refusal that no longer reproduces fails until it is deleted.
printf '%s\n' \
  "$(printf 'store-native-server\tshape-outside-slice\t-')" >>"$ledger"
if "${build_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/good.bgl" >"$scratch/stale.out" 2>"$scratch/stale.err"; then
  fail "stale QBE frontier entry did not fail the build"
fi
grep -Fq 'QBE frontier ledger is STALE for scope store-native-server' \
  "$scratch/stale.err" || fail "stale QBE frontier entry failed for the wrong reason"
printf '%s\n' '# scratch QBE frontier ledger' >"$ledger"

# An unrecorded refusal fails: the frontier may not grow.
qbe_env=("${build_env[@]}"
  FAKE_QBE_REFUSAL='unsupported native value-semantics op: hash')
printf '%s\n' '#lang beagle' '(ns demo.refused)' '(defn start [] Nil nil)' \
  >"$scratch/sources/refused.bgl"
if "${qbe_env[@]}" "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/refused.bgl" \
    >"$scratch/grew.out" 2>"$scratch/grew.err"; then
  fail "unrecorded QBE refusal did not fail the build"
fi
grep -Fq 'QBE frontier GREW for scope store-native-server' "$scratch/grew.err" ||
  fail "unrecorded QBE refusal failed for the wrong reason"
grep -Fq 'unsupported-value-semantics	hash' "$scratch/grew.err" ||
  fail "QBE frontier failure did not name the observed refusal key"

# Recorded, the same refusal builds — and C17's artifacts survive it.
printf '%s\n' \
  "$(printf 'store-native-server\tunsupported-value-semantics\thash')" >>"$ledger"
printf '%s\n' '#lang beagle' '(ns demo.report-v2)' \
  '(defn start [] Nil nil)' >"$scratch/sources/report-v2.bgl"
if "${qbe_env[@]}" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-report-v2" \
  FAKE_NATIVE_REPORT_FORMAT='beagle-native-report/v2' \
  "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/report-v2.bgl" \
    >"$scratch/report-v2.out" 2>"$scratch/report-v2.err"; then
  fail "unsupported failed-report schema did not fail closed"
fi
grep -Fq \
  'unsupported Beagle native report format: beagle-native-report/v2' \
  "$scratch/report-v2.err" ||
  fail "unsupported failed-report schema failed for the wrong reason"
[[ -z "$(find "$scratch/cache-report-v2" -name READY -print -quit)" ]] ||
  fail "unsupported failed-report schema exposed a READY artifact"
calls_before_refusal="$(wc -l <"$calls")"
refused_artifact="$("${qbe_env[@]}" "$builder" --host server \
  --adapter "$adapter" "$scratch/sources/refused.bgl")" ||
  fail "recorded QBE refusal blocked a complete C17 build"
[[ -f "$refused_artifact/module_0.c" && -f "$refused_artifact/module_0.h" &&
  -f "$refused_artifact/native_shim.c" &&
  -x "$refused_artifact/bin/beagle-store-server-native" ]] ||
  fail "QBE refusal discarded C17's artifacts"
[[ ! -f "$refused_artifact/module_0.ssa" ]] ||
  fail "refused QBE run published a module_0.ssa"
grep -Fqx 'native-qbe-frontier REFUSED scope=store-native-server ledger=unsupported-value-semantics/hash' \
  "$refused_artifact/native-host.report.txt" ||
  fail "refused QBE run did not attribute its frontier in the host report"
grep -Fq 'materialize-qbe REFUSED unsupported native value-semantics op: hash' \
  "$refused_artifact/qbe-probe.report.txt" ||
  fail "refused QBE run did not preserve the probe report"
[[ "$(sed -n "$((calls_before_refusal + 1)),\$p" "$calls" | head -2 | tr '\n' ' ')" == \
  "build-c17+qbe build-c17 " ]] ||
  fail "QBE refusal did not recover C17 through a second materialization"

# The logged refusal is attributable only to the exact Native program recovered
# through C17; differing bytes must fail before an artifact becomes READY.
printf '%s\n' '#lang beagle' '(ns demo.digest-mismatch)' \
  '(defn start [] Nil nil)' >"$scratch/sources/digest-mismatch.bgl"
if env \
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-digest-mismatch" \
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}" \
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger" \
  FAKE_NATIVE_CALLS="$calls" \
  FAKE_QBE_REFUSAL='unsupported native value-semantics op: hash' \
  FAKE_C17_PROGRAM_SUFFIX='different recovered program' \
  "$builder" --host server --adapter "$adapter" \
    "$scratch/sources/digest-mismatch.bgl" \
    >"$scratch/digest-mismatch.out" 2>"$scratch/digest-mismatch.err"; then
  fail "QBE refusal accepted a different recovered Native program"
fi
grep -Fq 'QBE and C17 materialized different native programs' \
  "$scratch/digest-mismatch.err" ||
  fail "different recovered Native program failed for the wrong reason"

# --regen-qbe-frontier records the observed frontier for a program scope.
printf '%s\n' '# scratch QBE frontier ledger' >"$ledger"
"${qbe_env[@]}" "$builder" --host program --entry demo.main/start \
  "$scratch/sources/refused.bgl" >"$scratch/regen.out" 2>"$scratch/regen.err" &&
  fail "unrecorded QBE refusal did not fail --host program"
"${qbe_env[@]}" "$builder" --host program --regen-qbe-frontier \
  --entry demo.main/start "$scratch/sources/refused.bgl" \
  >"$scratch/regen.out" 2>"$scratch/regen.err" ||
  fail "--regen-qbe-frontier failed"
grep -Fq "$(printf 'demo.main/start\tunsupported-value-semantics\thash')" \
  "$ledger" || fail "--regen-qbe-frontier did not record the observed refusal"
program_dir="$("${qbe_env[@]}" "$builder" --host program --entry demo.main/start \
  "$scratch/sources/refused.bgl")" ||
  fail "recorded QBE refusal blocked --host program"
[[ -f "$program_dir/module_0.c" && -f "$program_dir/READY" ]] ||
  fail "--host program did not persist the C17 projection"

# The Beagle identity is content, not a commit: a file the compiler sweep reads
# moves the native program cache entry, and a path the sweep prunes does not.
# Its own cache namespace and a clean ledger keep these builds out of the counts
# every assertion above makes.
printf '%s\n' '# scratch QBE frontier ledger' >"$ledger"
keying_env=(
  env
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle"
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-keying"
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}"
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger"
  FAKE_NATIVE_CALLS="$calls"
)
keyed_artifact="$("${keying_env[@]}" "$builder" --host server \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "content-keyed server host build failed"

printf '%s\n' 'pruned bytecode changed' \
  >"$scratch/tool/beagle-lib/compiled/module_01.zo"
printf '%s\n' 'pruned bin fixture changed' >"$scratch/tool/bin/test/fixture.txt"
printf '%s\n' 'pruned corpus changed' \
  >"$scratch/tool/native-core/src/shapes_corpus.bclj"
calls_before_pruned="$(wc -l <"$calls")"
pruned_hit="$("${keying_env[@]}" "$builder" --host server \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "a pruned compiler-tree change failed the build"
[[ "$pruned_hit" == "$keyed_artifact" ]] ||
  fail "a pruned compiler-tree path keyed the native program cache"
[[ "$(wc -l <"$calls")" == "$calls_before_pruned" ]] ||
  fail "a pruned compiler-tree path forced a materialization"

printf '%s\n' 'compiler source changed' \
  >"$scratch/tool/beagle-lib/module_01.txt"
calls_before_swept="$(wc -l <"$calls")"
swept_artifact="$("${keying_env[@]}" "$builder" --host server \
  --adapter "$adapter" "$scratch/sources/good.bgl")" ||
  fail "a swept compiler-tree change failed the build"
[[ "$swept_artifact" != "$keyed_artifact" ]] ||
  fail "a swept compiler input did not key the native program cache"
[[ "$(wc -l <"$calls")" -gt "$calls_before_swept" ]] ||
  fail "a swept compiler input did not force a materialization"
swept_program="$scratch/cache-keying/.programs/$(sed -n 's/^program=//p' \
  "$swept_artifact/input.manifest")"
grep -Fqx "$(sha256sum "$scratch/tool/beagle-lib/module_01.txt" |
  sed 's|  .*|  beagle-lib/module_01.txt|')" \
  "$swept_program/compiler-inputs.txt" ||
  fail "the entry did not record the compiler input listing behind its digest"

# Two checkout roots with identical source and host inputs must address one
# program and one host artifact. The builder copy derives each checkout root
# from itself, so this exercises the production re-anchoring boundary rather
# than substituting paths in a fixture manifest.
snapshot_checkout="$scratch/checkout-host-snapshot"
portable_a="$scratch/checkout-a"
portable_b="$scratch/different/depth/checkout-b"
for portable in "$snapshot_checkout" "$portable_a" "$portable_b"; do
  mkdir -p "$portable/bin" "$portable/native" "$portable/src"
  cp "$builder" "$portable/bin/beagle-store-native-build"
  cp "$repo/beagle-pin.txt" "$portable/beagle-pin.txt"
  cp "$repo/native/server_host.c" "$portable/native/server_host.c"
  cp "$repo/native/server_host.h" "$portable/native/server_host.h"
  cp "$adapter" "$portable/native/server_generated.c"
  printf '%s\n' '#lang beagle' '(ns demo.portable)' \
    '(defn start [] Nil nil)' >"$portable/src/portable.bgl"
done

snapshot_host_source_digest="$(sha256sum \
  "$snapshot_checkout/native/server_host.c" | sed 's/ .*//')"
snapshot_host_header_digest="$(sha256sum \
  "$snapshot_checkout/native/server_host.h" | sed 's/ .*//')"
snapshot_adapter_digest="$(sha256sum \
  "$snapshot_checkout/native/server_generated.c" | sed 's/ .*//')"
snapshot_host_artifact="$(env \
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle" \
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-host-snapshot" \
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}" \
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger" \
  FAKE_NATIVE_CALLS="$calls" \
  FAKE_MUTATE_HOST_ROOT="$snapshot_checkout" \
  "$snapshot_checkout/bin/beagle-store-native-build" --host server \
  "$snapshot_checkout/src/portable.bgl")" ||
  fail "host input snapshot did not survive checkout mutation during materialization"
[[ -f "$snapshot_host_artifact/READY" &&
  -x "$snapshot_host_artifact/bin/beagle-store-server-native" ]] ||
  fail "host input snapshot did not publish a ready server artifact"
for input in server_host.c server_host.h server_generated.c; do
  grep -Fqx 'changed during materialization' \
    "$snapshot_checkout/native/$input" ||
    fail "host input snapshot regression did not mutate $input"
done
grep -Fqx "host-source repo:native/server_host.c $snapshot_host_source_digest" \
  "$snapshot_host_artifact/input.manifest" ||
  fail "host source manifest did not preserve its launch bytes"
grep -Fqx "host-header repo:native/server_host.h $snapshot_host_header_digest" \
  "$snapshot_host_artifact/input.manifest" ||
  fail "host header manifest did not preserve its launch bytes"
grep -Fqx "adapter repo:native/server_generated.c $snapshot_adapter_digest" \
  "$snapshot_host_artifact/input.manifest" ||
  fail "host adapter manifest did not preserve its launch bytes"

portable_env=(
  env
  BEAGLE_STORE_BEAGLE="$scratch/tool/bin/beagle"
  BEAGLE_STORE_NATIVE_CACHE="$scratch/cache-portable"
  BEAGLE_STORE_NATIVE_CC="${CC:-cc}"
  BEAGLE_STORE_QBE_FRONTIER_LEDGER="$ledger"
  FAKE_NATIVE_CALLS="$calls"
)
calls_before_portable="$(wc -l <"$calls")"
portable_artifact_a="$("${portable_env[@]}" \
  "$portable_a/bin/beagle-store-native-build" --host server \
  "$portable_a/src/portable.bgl")" ||
  fail "checkout A portability build failed"
calls_after_portable_a="$(wc -l <"$calls")"
[[ "$calls_after_portable_a" -gt "$calls_before_portable" ]] ||
  fail "checkout A portability build did not run the materializer"
portable_program="$scratch/cache-portable/.programs/$(sed -n 's/^program=//p' \
  "$portable_artifact_a/input.manifest")"
grep -Fqx 'store-native-program-input/v3' "$portable_program/input.manifest" ||
  fail "portable program entry did not use the v3 logical-name vocabulary"
grep -Eq '^000000 portable\.bgl [0-9a-f]{64}$' \
  "$portable_program/input.manifest" ||
  fail "portable program manifest did not name its source logically"
grep -Fqx 'beagle-store-native-build-input/v3' "$portable_artifact_a/input.manifest" ||
  fail "portable host entry did not use the v3 logical-name vocabulary"
grep -Eq '^host-source repo:native/server_host\.c [0-9a-f]{64}$' \
  "$portable_artifact_a/input.manifest" ||
  fail "portable host manifest did not name its checkout input logically"
! grep -Fq "$portable_a" "$portable_program/input.manifest" ||
  fail "portable program manifest leaked checkout A"
! grep -Fq "$portable_a" "$portable_artifact_a/input.manifest" ||
  fail "portable host manifest leaked checkout A"

portable_artifact_b="$("${portable_env[@]}" \
  "$portable_b/bin/beagle-store-native-build" --host server \
  "$portable_b/src/portable.bgl")" ||
  fail "checkout B portability build failed"
[[ "$portable_artifact_b" == "$portable_artifact_a" ]] ||
  fail "byte-identical checkout B did not share checkout A's host artifact"
[[ "$(wc -l <"$calls")" == "$calls_after_portable_a" ]] ||
  fail "byte-identical checkout B rebuilt the shared native program"

printf '%s\n' '#lang beagle' '(ns demo.portable)' \
  '(defn start [] Nil nil)' ';; genuine source change' \
  >"$portable_b/src/portable.bgl"
portable_changed="$("${portable_env[@]}" \
  "$portable_b/bin/beagle-store-native-build" --host server \
  "$portable_b/src/portable.bgl")" ||
  fail "changed checkout B portability build failed"
[[ "$portable_changed" != "$portable_artifact_a" ]] ||
  fail "a genuine source change hit the prior checkout's cache entry"
[[ "$(wc -l <"$calls")" -gt "$calls_after_portable_a" ]] ||
  fail "a genuine source change did not rerun the materializer"

echo "store native build cache smoke: PASS"

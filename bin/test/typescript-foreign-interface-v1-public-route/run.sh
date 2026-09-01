#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture="$root/tools/typescript-foreign-interface-v1/fixture"
adapter="$root/tools/typescript-foreign-interface-v1"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-typescript-public-route.XXXXXX")"
trap 'rm -rf -- "${scratch:?}"' EXIT

fail() {
    printf 'typescript-foreign-interface-v1-public-route: %s\n' "$*" >&2
    exit 1
}

project="$scratch/project"
consumer="$project/rename-consumer.bjs"
mkdir -p "$project" "$scratch/tmp" "$scratch/cache"
cp -- "$fixture/package.json" "$project/package.json"
cp -R -- "$fixture/node_modules" "$project/node_modules"
cp -- "$fixture/rename-consumer.bjs" "$consumer"

export TMPDIR="$scratch/tmp"
export XDG_CACHE_HOME="$scratch/cache"
export BEAGLE_GATE_NO_CACHE=1
export BEAGLE_FACT_REUSE_FORBIDDEN=1

"$root/bin/beagle" check "$consumer"
"$root/bin/beagle" build "$consumer" "$scratch/consumer.js"
"$root/bin/beagle" ast "$consumer" >"$scratch/consumer.ast.json"

expected_import='import { "parse" as choose } from "@fixture/foreign-interface-v1";'
grep -Fqx -- "$expected_import" "$scratch/consumer.js" ||
    fail "build did not emit the exact native ESM rename"
[[ "$(grep -Fc -- 'from "@fixture/foreign-interface-v1";' "$scratch/consumer.js")" -eq 1 ]] ||
    fail "build did not emit exactly one direct package import"
grep -Fq -- 'choose("public-route")' "$scratch/consumer.js" ||
    fail "emitted code did not call the renamed local"
if grep -Eq -- 'foreign-interface:|function[[:space:]]+choose' "$scratch/consumer.js"; then
    fail "build synthesized a foreign wrapper"
fi

AST_PATH="$scratch/consumer.ast.json" bun -e '
const ast = await Bun.file(process.env.AST_PATH).json();
const specifier = "@fixture/foreign-interface-v1";
const imports = ast.requires.filter(({ identity }) => identity?.value === specifier);
if (imports.length !== 1) throw new Error(`expected one ${specifier} require`);
const requirement = imports[0];
if (requirement.identity.kind !== "native-esm") throw new Error("lost native-esm identity");
if (JSON.stringify(requirement.refer) !== JSON.stringify(["parse", "UserId"])) throw new Error("non-canonical :refer");
if (JSON.stringify(requirement.rename) !== JSON.stringify({ parse: "choose" })) throw new Error("non-canonical :rename");
const selected = ast.forms.find(({ node, name }) => node === "def" && name === "selected");
if (selected?.value?.fn?.name !== "choose") throw new Error("AST lost renamed local reference");
if (selected?.ann?.kind !== "foreign" || selected?.effectiveType?.kind !== "foreign") throw new Error("UserId escaped its foreign graph type");
if (JSON.stringify(ast).includes("\"name\":\"Any\"")) throw new Error("checked projection contains Beagle Any");
' || fail "checked AST did not retain canonical foreign import semantics"

set +e
bb -cp "$root/self-host/seed" -m selfhost.main \
    emit-from-ast --target js \
    <"$scratch/consumer.ast.json" \
    >"$scratch/direct-ast.stdout" \
    2>"$scratch/direct-ast.stderr"
direct_ast_status=$?
set -e
[[ "$direct_ast_status" -eq 1 ]] ||
    fail "renamed checked AST exited $direct_ast_status through the direct emitter, expected 1"
grep -Fq -- \
    'a checked program with :rename must enter through source graph admission' \
    "$scratch/direct-ast.stderr" ||
    fail "direct emitter did not require renamed AST to enter through source graph admission"

sed 's/(choose "public-route")/(parse "public-route")/' "$consumer" >"$project/bare-source.bjs"
if "$root/bin/beagle" check "$project/bare-source.bjs" \
    >"$scratch/bare.stdout" 2>"$scratch/bare.stderr"; then
    fail "bare source binding remained visible after :rename"
fi
grep -Eq -- '(`parse`.*no semantic contract|undefined.*parse|parse.*undefined)' \
    "$scratch/bare.stderr" || fail "bare source failure did not identify parse"

sed -e 's/:refer \[parse UserId\]/:refer [parse select UserId]/' \
    -e 's/{parse choose}/{parse select}/' \
    "$consumer" >"$project/local-collision.bjs"
if "$root/bin/beagle" check "$project/local-collision.bjs" \
    >"$scratch/collision.stdout" 2>"$scratch/collision.stderr"; then
    fail "final-local rename collision was accepted"
fi
grep -Eq -- ':rename.*(duplicate-free local names|final local|collision)' \
    "$scratch/collision.stderr" || fail "collision failure did not identify :rename locals"

mapfile -t compiled_adapters < <(
    rg --files "$XDG_CACHE_HOME" -g '*.mjs' |
        grep '/typescript-foreign-interface-v1/compiled/' | sort
)
[[ "${#compiled_adapters[@]}" -eq 1 ]] ||
    fail "expected one isolated compiled adapter, found ${#compiled_adapters[@]}"
bun "$adapter/src/run.mjs" \
    "${compiled_adapters[0]}" "$adapter" "$adapter" \
    "$root/beagle-lib/lib/beagle" \
    "$project" "$consumer" "@fixture/foreign-interface-v1" beagle \
    >"$scratch/foreign-interface.json"

GRAPH_PATH="$scratch/foreign-interface.json" bun -e '
const graph = await Bun.file(process.env.GRAPH_PATH).json();
if (graph.kind !== "ForeignInterfaceV1") throw new Error("wrong projection kind");
if (graph.stats.anyCount !== 0) throw new Error(`projected Any count ${graph.stats.anyCount}`);
if (graph.stats.generatedSourceCount !== 0) throw new Error(`generated source count ${graph.stats.generatedSourceCount}`);
const exported = graph.exports.find(({ name }) => name === "parse");
const node = graph.nodes.find(({ id }) => id === exported?.node);
if (exported?.runtimeName !== "parse" || node?.kind !== "function" || node.overloads.length !== 2) {
  throw new Error("fixture did not resolve the exact overloaded parse export");
}
' || fail "foreign projection violated its typed graph contract"

printf '%s\n' 'typescript-foreign-interface-v1-public-route: PASS'

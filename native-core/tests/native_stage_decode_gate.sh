#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-native-stage-decode.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

command -v bb >/dev/null 2>&1 || {
  echo "native_stage_decode_gate.sh: babashka (bb) is required" >&2
  exit 2
}

timeout 120s nice -n 19 "$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  --out "$scratch/out"

timeout 30s nice -n 19 bb -cp "$scratch/out" -e '
  (require (quote [native.core :as core])
           (quote [native.stages :as stages]))

  (defn nid [value] (core/->NativeId value))

  (let [program-id (nid "program")
        parent-id (nid "parent")
        type-id (nid "type")
        effect-id (nid "effect")
        region-id (nid "region")
        capability-id (nid "capability")
        layout-id (nid "layout")
        function-id (nid "function")
        callee-id (nid "callee")
        abi-id (nid "abi")
        block-id (nid "block")
        target-block-id (nid "target-block")
        parameter-id (nid "parameter")
        literal-id (nid "literal")
        call-id (nid "call")
        token-in-id (nid "token-in")
        token-out-id (nid "token-out")
        variant-id (nid "variant")
        arena-id (nid "arena")
        parameter (core/->Parameter parameter-id type-id)
        literal-result (core/->SsaValueV0 literal-id type-id)
        call-result (core/->SsaValueV0 call-id type-id)
        flow (core/->TokenFlowV0
               [token-in-id]
               [(core/->ResourceTokenV0 token-out-id
                  (core/->CapabilityTokenV0 capability-id))])
        literal (core/->AtomInstruction literal-result (core/->F64Atom -0.0))
        call (core/->CallInstruction call-result callee-id [literal-id]
               arena-id flow)
        switch-case (core/->SwitchCaseV0 variant-id target-block-id [call-id])
        switch (core/->SwitchTerminator call-id [switch-case])
        target-block (core/->BasicBlock target-block-id [] []
                       [(core/->ReturnTerminator call-id)])
        block (core/->BasicBlock block-id [parameter] [literal call] [switch])
        function (core/->FunctionDef function-id "decode-fixture" [parameter]
                   [block target-block] block-id type-id [effect-id]
                   [region-id] [capability-id])
        type-def (core/->TypeDef type-id "Float"
                   (core/->AtomType (core/->F64Kind true)))
        effect (core/->EffectDef effect-id
                 (core/->CapabilityEffect capability-id))
        region (core/->RegionDef region-id (core/->ArenaRegion true) parent-id)
        capability (core/->CapabilityDef capability-id
                     (core/->WriteCapability true) region-id true)
        layout (core/->LayoutDef layout-id type-id 8 8
                 (core/->ScalarShapeV0 (core/->FloatReprV0 64)))
        abi-parameter (core/->AbiValueV0 "input" type-id
                        (core/->BorrowedV0 true) region-id)
        abi-result (core/->AbiValueV0 "result" type-id
                     (core/->OwnedV0 true) nil)
        abi (core/->AbiDeclV0 abi-id function-id "decode_fixture"
              (core/->AbiExportV0 true) (core/->RestrictedCAbiV0 true)
              [abi-parameter] abi-result type-id [effect-id]
              [capability-id] "v0" "sha256:layout")
        observation (core/->Fri2Observation (nid "artifact")
                      "sha256:artifact" 17)
        program (core/->NativeCoreProgram program-id parent-id
                  "native-to-epoch-v0" [type-def] [effect] [region]
                  [capability] [layout] [function] [effect-id] [region-id]
                  [capability-id] [abi] [observation])
        root-id (nid "root")
        graph (stages/->TermGraphV0 root-id
                [(stages/->TermNodeV0 root-id
                   (stages/->TextTermV0 "native-stage-v0"))
                 (stages/->TermNodeV0 (nid "triple")
                   (stages/->TripleTermV0 program-id function-id block-id))])
        stage (stages/->NativeStageV0 graph "sha256:typed" program
                [(nid "obligation")])
        legacy-encoding (stages/encode-native-stage stage)
        frozen (stages/->FrozenNativeStageV0 stage legacy-encoding
                 (stages/content-digest legacy-encoding))
        program-wire (stages/encode-native-core-program-wire-v1 program)
        decoded-program (stages/decode-native-core-program-wire-v1 program-wire)
        frozen-wire (stages/encode-frozen-native-stage-wire-v1 frozen)
        decoded-frozen (stages/decode-frozen-native-stage-wire-v1 frozen-wire)
        attested-frozen
        (stages/decode-attested-frozen-native-stage-wire-v1 frozen-wire)
        decoded-stage (stages/frozennativestagev0-stage decoded-frozen)
        decoded-function (first
                           (core/nativecoreprogram-functions
                             (stages/nativestagev0-program decoded-stage)))
        decoded-block (first (core/functiondef-blocks decoded-function))
        decoded-literal (first (core/basicblock-instructions decoded-block))
        decoded-call (second (core/basicblock-instructions decoded-block))
        decoded-switch (first (core/basicblock-terminators decoded-block))
        nan-bits 9221120237041090561
        nan-literal (core/->AtomInstruction literal-result
                      (core/->F64Atom (Double/longBitsToDouble nan-bits)))
        nan-block (assoc block :instructions [nan-literal call])
        nan-function (assoc function :blocks [nan-block target-block])
        nan-program (assoc program :functions [nan-function])
        nan-wire (stages/encode-native-core-program-wire-v1 nan-program)
        decoded-nan-program
        (stages/decode-native-core-program-wire-v1 nan-wire)
        decoded-nan
        (first
          (core/basicblock-instructions
            (first
              (core/functiondef-blocks
                (first
                  (core/nativecoreprogram-functions decoded-nan-program))))))
        inconsistent (stages/->FrozenNativeStageV0 stage legacy-encoding
                       "sha256:not-the-legacy-digest")
        reader-eval-path (nth *command-line-args* 2)
        malicious (stages/canonical-record "native-core-program-wire-v1"
                    [(str "#=(spit " (pr-str reader-eval-path) " \"bad\")")
                     (stages/canonical-record
                       "native-program-f64-atoms-v1" [])])]
    (assert decoded-program "program decoder rejected its canonical encoder")
    (assert (= program decoded-program)
      "program decode changed a complete NativeCoreProgram")
    (assert decoded-frozen "frozen decoder rejected its canonical encoder")
    (assert (= frozen decoded-frozen)
      "frozen decode changed the stage/program record graph")
    (assert (= decoded-frozen attested-frozen)
      "attested frozen decoder changed the decoded stage")
    (assert (= flow (core/callinstruction-tokens decoded-call))
      "call token flow was not preserved")
    (assert (= [switch-case] (core/switchterminator-cases decoded-switch))
      "switch cases were not preserved")
    (assert (= (Double/doubleToRawLongBits -0.0)
               (Double/doubleToRawLongBits
                 (core/f64atom-value
                   (core/atominstruction-atom decoded-literal))))
      "F64 raw bits were not preserved")
    (assert (= nan-wire
               (stages/encode-native-core-program-wire-v1 decoded-nan-program))
      "noncanonical NaN payload changed program wire bytes")
    (assert (= nan-bits
               (Double/doubleToRawLongBits
                 (core/f64atom-value
                   (core/atominstruction-atom decoded-nan))))
      "noncanonical NaN payload bits were not preserved")
    (assert (nil?
              (stages/decode-frozen-native-stage-wire-v1
                (stages/encode-frozen-native-stage-wire-v1 inconsistent)))
      "frozen decoder accepted a mismatched legacy digest")
    (assert (nil? (stages/decode-native-core-program-wire-v1 malicious))
      "program decoder accepted reader evaluation")
    (assert (not (.exists (java.io.File. reader-eval-path)))
      "program decoder executed a reader form")
    (spit (first *command-line-args*) frozen-wire)
    (spit (second *command-line-args*)
      (stages/encode-frozen-native-stage-wire-v1 decoded-frozen)))' \
  "$scratch/original.wire" "$scratch/reencoded.wire" \
  "$scratch/reader-eval-marker"

cmp -s "$scratch/original.wire" "$scratch/reencoded.wire" || {
  echo "native frozen-stage wire changed across encode-decode-encode" >&2
  exit 1
}

original_sha256="$(sha256sum "$scratch/original.wire" | cut -d ' ' -f 1)"
reencoded_sha256="$(sha256sum "$scratch/reencoded.wire" | cut -d ' ' -f 1)"
[[ "$original_sha256" == "$reencoded_sha256" ]]

echo "native stage decode: semantic equality and byte-exact round trip PASS ($original_sha256)"

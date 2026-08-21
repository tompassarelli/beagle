#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-source-stage-digest.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

exact_input="${1:-}"
if [[ -n "$exact_input" ]]; then
  exact_input="$(realpath "$exact_input")"
  [[ -f "$exact_input" && ! -L "$exact_input" ]] || {
    echo "source_stage_digest_platform_gate.sh: exact input must be a regular file" >&2
    exit 2
  }
  [[ "$(wc -c <"$exact_input")" -eq 89082559 ]] || {
    echo "source_stage_digest_platform_gate.sh: exact input must be 89,082,559 bytes" >&2
    exit 2
  }
fi

cat >"$scratch/digest_platform_gate.bclj" <<'BGL'
#lang beagle/clj
(ns native.digest-platform-gate
  (:require [native.stages :as stages]))

(defn digest-text [value String] String
  (stages/content-digest value))

(defn digest-bytes [value (Vec Int)] String
  (sha256-bytes value))
BGL

cat >"$scratch/digest_platform_native.bgl" <<'BGL'
#lang beagle
(ns native.digest-platform-native)

(defn digest-text [value String] String
  (bgl/sha256-utf8 value))

(defn -main [] Int
  (if (and
        (= (digest-text "")
           "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        (= (digest-text "abc")
           "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        (= (digest-text "λ💥")
           "18e1a20921b5309071b878eae9361c5f90451591068d0919af4edd6c5200b8ac"))
    0
    41))
BGL

cat >"$scratch/digest_platform_emitter.bclj" <<'BGL'
#lang beagle/clj
(ns native.digest-platform-emitter)

(defn digest-text [value String] String
  (bgl/sha256-utf8 value))
BGL

timeout 180s nice -n 19 env BEAGLE_EMIT_SRCLOC=0 \
  "$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$scratch/digest_platform_gate.bclj" \
  "$scratch/digest_platform_emitter.bclj" \
  --out "$scratch/out"

timeout 60s nice -n 19 bb -cp "$repo/self-host/seed" \
  -m selfhost.main emit "$scratch/digest_platform_emitter.bclj" \
  >"$scratch/digest_platform_emitter.selfhost.clj"
cmp "$scratch/out/native/digest_platform_emitter.clj" \
  "$scratch/digest_platform_emitter.selfhost.clj"
grep -F 'beagle$sha256_utf8_v0' \
  "$scratch/digest_platform_emitter.selfhost.clj" >/dev/null

# This crosses the same Core compiler projection that compiles native.stages,
# lowers the target-neutral intrinsic through UTF-8 and native SHA-256, links
# the focused executable, and checks the result without a hosted runtime.
timeout 180s nice -n 19 env \
  BEAGLE_CORE_BUILD_CACHE="$scratch/core-cache" \
  BEAGLE_NATIVE_EXE_CACHE="$scratch/native-exe-cache" \
  "$repo/bin/beagle" native-exe \
  --out "$scratch/native-digest" \
  --artifacts "$scratch/native-out" \
  --entry native.digest-platform-native/-main \
  "$scratch/digest_platform_native.bgl"
grep -Fx 'stage typed-to-native COMPLETE' "$scratch/native-out/report.txt"
grep -F 'native_utf8_encode' "$scratch/native-out/module_0.c" >/dev/null
grep -F 'native_sha256_bytes' "$scratch/native-out/module_0.c" >/dev/null
env -i "$scratch/native-digest"

timeout 30s nice -n 19 bb -cp "$scratch/out" -e '
  (require (quote [native.core :as core])
           (quote [native.digest-platform-gate :as digest])
           (quote [native.lower :as lower])
           (quote [native.stages :as stages]))
  (import (quote [java.nio.charset StandardCharsets])
          (quote [java.security MessageDigest])
          (quote [java.util Arrays]))

  (defn require! [condition detail]
    (when-not condition (throw (ex-info detail {}))))

  (defn hex [values]
    (apply str
      (map (fn [value]
             (format "%02x" (bit-and (int value) 255)))
        values)))

  (defn oracle-bytes [raw]
    (hex (.digest (MessageDigest/getInstance "SHA-256") raw)))

  (defn oracle-text [text]
    (str "sha256:"
      (oracle-bytes (.getBytes ^String text StandardCharsets/UTF_8))))

  (defn failure [operation]
    (try
      (operation)
      nil
      (catch Throwable error
        {:class (str (class error))
         :message (.getMessage error)
         :data (ex-data error)})))

  (defn repeated-text [size]
    (let [characters (char-array size)]
      (Arrays/fill characters \a)
      (String. characters)))

  (defn best-ms [operation]
    (apply min
      (repeatedly 2
        (fn []
          (let [started (System/nanoTime)]
            (operation)
            (/ (double (- (System/nanoTime) started)) 1000000.0))))))

  (let [text-cases ["" "abc" "small canonical record" "λ💥\u0000"]
        byte-cases [[] [0] [0 1 127 128 255]]]
    (doseq [text text-cases]
      (require! (= (oracle-text text) (digest/digest-text text))
        (str "UTF-8 digest differs for " (pr-str text))))
    (doseq [values byte-cases]
      (let [raw (byte-array (map unchecked-byte values))]
        (require! (= (oracle-bytes raw) (digest/digest-bytes values))
          (str "binary digest differs for " (pr-str values)))))
    (require!
      (= {:class "class clojure.lang.ExceptionInfo"
          :message "sha256-bytes requires a Vec Int"
          :data {:value nil}}
         (failure #(digest/digest-bytes nil)))
      "sha256-bytes changed its non-vector failure")
    (require!
      (= {:class "class clojure.lang.ExceptionInfo"
          :message "sha256-bytes requires byte values from 0 through 255"
          :data {:index 1 :value 256}}
         (failure #(digest/digest-bytes [0 256])))
      "sha256-bytes changed its byte-range failure")
    (require!
      (= {:class "class clojure.lang.ExceptionInfo"
          :message "sha256-bytes requires byte values from 0 through 255"
          :data {:index 1 :value "x"}}
         (failure #(digest/digest-bytes [0 "x"])))
      "sha256-bytes changed its non-integer failure"))

  (doseq [text [(String. (char-array [(char 55296)]))
                (String. (char-array [(char 56320)]))
                (String. (char-array [(char 55296) \a]))
                (String. (char-array [(char 55357) (char 56485)]))]]
    (require!
      (= (str "sha256:" (digest/digest-bytes (stages/utf8-bytes text)))
         (digest/digest-text text))
      (str "UTF-16 surrogate digest changed for " (mapv int text))))

  (let [root (core/->NativeId "root")
        node (stages/->TermNodeV0 root (stages/->TextTermV0 "payload"))
        valid-stage (stages/->SourceStageV1
                      (stages/->TermGraphV0 root [node]) [] [] [] [])
        encoding (stages/encode-source-stage valid-stage)
        expected-digest (oracle-text encoding)
        accepted (lower/freeze-source-stage
                   valid-stage "digest-platform-gate" ["mode=test"])
        frozen (lower/sourcefreezeacceptedv0-frozen accepted)
        receipt (lower/sourcefreezeacceptedv0-receipt accepted)]
    (require! (instance? native.lower.SourceFreezeAcceptedV0 accepted)
      "valid source stage was not accepted")
    (require! (= frozen
                 (stages/->FrozenSourceStageV1
                   valid-stage encoding expected-digest))
      "frozen source artifact identity changed")
    (require! (= (core/passreceiptv0-id receipt)
                 (lower/lower-id "receipt"
                   ["source-freeze" expected-digest expected-digest]))
      "accepted receipt identity changed")
    (require! (= expected-digest (core/passreceiptv0-input-digest receipt))
      "accepted receipt input digest changed")
    (require! (= expected-digest (core/passreceiptv0-output-digest receipt))
      "accepted receipt output digest changed"))

  (let [root (core/->NativeId "missing-root")
        invalid-stage (stages/->SourceStageV1
                        (stages/->TermGraphV0 root []) [] [] [] [])
        expected-digest (oracle-text (stages/encode-source-stage invalid-stage))
        rejected (lower/freeze-source-stage
                   invalid-stage "digest-platform-gate" ["mode=test"])
        receipt (lower/sourcefreezerejectedv0-receipt rejected)]
    (require! (instance? native.lower.SourceFreezeRejectedV0 rejected)
      "invalid source stage was not rejected")
    (require! (instance? native.lower.MissingGraphRootV0
                (lower/sourcefreezerejectedv0-failure rejected))
      "invalid source stage changed its first failure")
    (require! (= expected-digest (core/passreceiptv0-input-digest receipt))
      "rejected stage was not encoded and digested before validation")
    (require! (= "" (core/passreceiptv0-output-digest receipt))
      "rejected receipt gained an output digest")
    (require! (= ["LOWER-SOURCE-NOT-CLOSED"]
                 (mapv core/diagnosticv0-code
                   (core/passreceiptv0-diagnostics receipt)))
      "rejected receipt diagnostics changed"))

  (let [small (repeated-text 1048576)
        large (repeated-text 16777216)
        _ (digest/digest-text "warm")
        small-ms (best-ms #(digest/digest-text small))
        large-ms (best-ms #(digest/digest-text large))
        growth (/ large-ms small-ms)]
    (require! (< large-ms 5000.0)
      (str "16 MiB UTF-8 digest exceeded 5 seconds: " large-ms "ms"))
    (require! (< growth 40.0)
      (str "UTF-8 digest scaling is not bounded-linear: " growth))
    (println "source_stage_digest_platform_gate: PASS"
      {:small-ms small-ms :large-ms large-ms :growth growth}))'

if [[ -n "$exact_input" ]]; then
  timeout 15s nice -n 19 bb -cp "$scratch/out" -e '
    (require (quote [native.digest-platform-gate :as digest]))
    (let [path (first *command-line-args*)
          text (slurp path)
          started (System/nanoTime)
          actual (digest/digest-text text)
          elapsed-ms (/ (double (- (System/nanoTime) started)) 1000000.0)
          expected "sha256:226dfabbee5059ce5c19bb788e5a71b7820e74e61248e931803e3bd9ee51eaba"]
      (when-not (= expected actual)
        (throw (ex-info "exact 89 MB source-stage digest differs"
                 {:expected expected :actual actual})))
      (when-not (< elapsed-ms 5000.0)
        (throw (ex-info "exact 89 MB source-stage digest exceeded 5 seconds"
                 {:milliseconds elapsed-ms})))
      (println "source_stage_digest_platform_gate: EXACT PASS"
        {:bytes (count (.getBytes ^String text
                         java.nio.charset.StandardCharsets/UTF_8))
         :digest actual
         :milliseconds elapsed-ms}))' -- "$exact_input"
fi

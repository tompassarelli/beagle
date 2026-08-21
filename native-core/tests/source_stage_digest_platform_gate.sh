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

timeout 180s nice -n 19 "$repo/bin/beagle-build-all" \
  "$repo/native-core/src/native/core.bclj" \
  "$repo/native-core/src/native/stages.bclj" \
  "$repo/native-core/src/native/obligations.bclj" \
  "$repo/native-core/src/native/lower.bclj" \
  "$scratch/digest_platform_gate.bclj" \
  --out "$scratch/out"

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

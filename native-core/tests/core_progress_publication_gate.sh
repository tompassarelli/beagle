#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/core-progress-publication.XXXXXX")"
cleanup() { rm -rf "${work:?}"; }
trap cleanup EXIT

command -v bb >/dev/null 2>&1 || {
    echo "core_progress_publication_gate.sh: babashka (bb) is required" >&2
    exit 2
}

awk '
    /core-lowering-progress-fixture-begin/ { copying = 1; next }
    /core-lowering-progress-fixture-end/ { exit }
    copying { print }
' "$repo/bin/beagle-build-core" >"$work/progress-definitions.clj"
[[ -s "$work/progress-definitions.clj" ]] || {
    echo "core_progress_publication_gate.sh: progress definitions were not found" >&2
    exit 1
}

cat >"$work/progress-gate.clj" <<'CLJ'
(def events (atom []))
(def calls (atom {}))
(def resolutions (atom []))
(def sources (atom []))
(def types (atom [{:id "known" :name "Known" :shape []}]))
(def source-result (atom (Object.)))
(def freeze-result (atom (Object.)))
(def typing-result (atom (Object.)))

(defn require! [condition detail]
  (when-not condition (throw (ex-info detail {}))))

(defn called! [name]
  (swap! calls update name (fnil inc 0)))

(defn publish-stage-work! [stage work status completed total]
  (swap! events conj [stage work status completed total]))

(def stages-ns (create-ns (quote progress.fake.stages)))
(def core-ns (create-ns (quote progress.fake.core)))
(def lower-ns (create-ns (quote progress.fake.lower)))
(def slice-ns (create-ns (quote progress.fake.slice)))
(alias (quote stages) (quote progress.fake.stages))
(alias (quote core) (quote progress.fake.core))
(alias (quote lower) (quote progress.fake.lower))
(alias (quote slice) (quote progress.fake.slice))

(intern stages-ns (quote encode-source-stage)
  (fn [_stage] (called! :encode) :encoded))
(intern core-ns (quote nativeid-value) identity)
(intern core-ns (quote typedef-id) :id)
(intern core-ns (quote typedef-name) :name)
(intern core-ns (quote typedef-shape) :shape)
(intern core-ns (quote type-ids) #(mapv :id %))
(intern core-ns (quote id-in?)
  (fn [ids target] (boolean (some #(= target %) ids))))
(intern core-ns (quote ids-in?)
  (fn [ids allowed]
    (every? #((deref (ns-resolve core-ns (quote id-in?))) allowed %) ids)))
(intern core-ns (quote optional-id-in?)
  (fn [candidate allowed]
    (or (nil? candidate)
        ((deref (ns-resolve core-ns (quote id-in?))) allowed candidate))))
(intern core-ns (quote type-shape-refs-closed?)
  (fn [shape known-types]
    ((deref (ns-resolve core-ns (quote ids-in?))) shape known-types)))
(intern core-ns (quote types-refs-closed?)
  (fn [definitions]
    (called! :types-refs-closed)
    (let [known-types ((deref (ns-resolve core-ns (quote type-ids))) definitions)]
      (every?
       #((deref (ns-resolve core-ns (quote type-shape-refs-closed?)))
         (:shape %) known-types)
       definitions))))
(intern lower-ns (quote source-stage-valid?)
  (fn [_stage] (called! :valid) true))
(intern lower-ns (quote freeze-source-stage)
  (fn [source _compiler-commit _configuration]
    (called! :freeze)
    ((deref (ns-resolve stages-ns (quote encode-source-stage))) source)
    ((deref (ns-resolve lower-ns (quote source-stage-valid?))) source)
    @freeze-result))
(intern slice-ns (quote source-program)
  (fn [_rows _module-name _relative-path]
    (called! :source-program)
    @source-result))
(intern lower-ns (quote prepare-typing-prelude)
  (fn [_source _configuration]
    (called! :prelude)
    :prelude))
(intern lower-ns (quote attach-body)
  (fn [_env resolution _source]
    (called! :attach-body)
    resolution))
(intern lower-ns (quote attach-bodies)
  (fn [env body-resolutions body-sources]
    (called! :attach-bodies)
    (mapv (fn [[resolution source]]
            ((deref (ns-resolve lower-ns (quote attach-body)))
             env resolution source))
          (map vector body-resolutions body-sources))))
(intern lower-ns (quote typed-term-nodes)
  (fn [_types _functions _effects
       _include-environment _include-context _include-stdout
       _include-stderr _include-filesystem _include-process
       _include-socket _include-clock]
    (called! :typed-term-nodes)
    :nodes))
(intern lower-ns (quote type-closure-obligations)
  (fn [_digest _closed _clean]
    (called! :type-closure-obligations)
    :obligations))
(intern lower-ns (quote lower-typed-stage)
  (fn [source _compiler-commit configuration]
    (called! :lower-typed-stage)
    ((deref (ns-resolve lower-ns (quote prepare-typing-prelude)))
     source configuration)
    ((deref (ns-resolve lower-ns (quote attach-bodies)))
     :env @resolutions @sources)
    ((deref (ns-resolve lower-ns (quote typed-term-nodes)))
     @types [] [] false false false false false false false false)
    (let [closed ((deref (ns-resolve core-ns (quote types-refs-closed?))) @types)]
      ((deref (ns-resolve lower-ns (quote type-closure-obligations)))
       "digest" closed true))
    @typing-result))

(load-file (System/getenv "PROGRESS_DEFINITIONS"))

(reset! calls {})
(reset! events [])
(let [result (observed-source-program [] "module" "source")]
  (require! (identical? result @source-result)
            "source observer changed the returned value"))
(require! (= {:source-program 1} @calls)
          (str "source observer call count changed: " @calls))
(require! (= [["source-freeze" "source-reconstruction" "RUNNING" 0 1]
              ["source-freeze" "source-reconstruction" "ACCEPTED" 1 1]]
             @events)
          (str "source observer receipts changed: " @events))

(reset! calls {})
(reset! events [])
(let [result (observed-freeze-source-stage :source "commit" [])]
  (require! (identical? result @freeze-result)
            "freeze observer changed the returned value"))
(require! (= {:freeze 1 :encode 1 :valid 1} @calls)
          (str "freeze observer call count changed: " @calls))
(require! (= [["source-freeze" "source-encoding" "RUNNING" 0 1]
              ["source-freeze" "source-encoding" "ACCEPTED" 1 1]
              ["source-freeze" "source-validation" "ACCEPTED" 1 1]]
             @events)
          (str "freeze observer receipt order changed: " @events))

(let [expected (ex-info "encode failed" {:expected true})
      caught (atom nil)]
  (reset! calls {})
  (reset! events [])
  (try
    (with-redefs [stages/encode-source-stage
                  (fn [_stage] (called! :encode) (throw expected))]
      (observed-freeze-source-stage :source "commit" []))
    (catch Throwable error (reset! caught error)))
  (require! (identical? expected @caught)
            "freeze observer replaced the original exception")
  (require! (= {:freeze 1 :encode 1} @calls)
            (str "freeze failure invoked extra compiler work: " @calls))
  (require! (= [["source-freeze" "source-encoding" "RUNNING" 0 1]] @events)
            (str "freeze failure published a false success: " @events)))

(reset! resolutions (vec (range 70)))
(reset! sources (vec (range 70)))
(reset! calls {})
(reset! events [])
(let [diagnostic (java.io.StringWriter.)
      result (binding [*err* diagnostic]
               (observed-lower-typed-stage :source "commit" []))]
  (require! (identical? result @typing-result)
            "typing observer changed the returned value")
  (require! (= "" (str diagnostic))
            (str "successful typing emitted a closure diagnostic: " diagnostic)))
(require! (= {:lower-typed-stage 1
              :prelude 1
              :attach-bodies 1
              :attach-body 70
              :typed-term-nodes 1
              :types-refs-closed 1
              :type-closure-obligations 1}
             @calls)
          (str "typing observer call count changed: " @calls))
(require! (= [1 32 64 70]
             (mapv #(nth % 3)
               (filter #(and (= "function-bodies" (nth % 1))
                             (> (nth % 3) 0))
                       @events)))
          (str "typing body cadence changed: " @events))
(require! (= ["source-to-typed" "typing-finalization" "ACCEPTED" 1 1]
             (last @events))
          (str "typing final receipt changed: " (last @events)))

(reset! types [{:id "type-b" :name "TypeB" :shape ["missing-z" "missing-a"]}
               {:id "type-a" :name "TypeA" :shape ["missing-a"]}])
(reset! calls {})
(reset! events [])
(let [diagnostic (java.io.StringWriter.)]
  (binding [*err* diagnostic]
    (observed-lower-typed-stage :source "commit" []))
  (require!
   (= (str "beagle build: type-closure TypeDef REJECTED"
           " id=\"type-a\" name=\"TypeA\""
           " missing-type-ids=[\"missing-a\"] shape=[\"missing-a\"]\n"
           "beagle build: type-closure TypeDef REJECTED"
           " id=\"type-b\" name=\"TypeB\""
           " missing-type-ids=[\"missing-a\" \"missing-z\"]"
           " shape=[\"missing-z\" \"missing-a\"]\n")
      (str diagnostic))
   (str "typing closure diagnostic changed: " diagnostic)))
(reset! types [{:id "known" :name "Known" :shape []}])

(let [expected (ex-info "body failed" {:expected true})
      caught (atom nil)]
  (reset! calls {})
  (reset! events [])
  (try
    (with-redefs [lower/attach-body
                  (fn [_env resolution _source]
                    (called! :attach-body)
                    (if (= resolution 1)
                      (throw expected)
                      resolution))]
      (observed-lower-typed-stage :source "commit" []))
    (catch Throwable error (reset! caught error)))
  (require! (identical? expected @caught)
            "typing observer replaced the original exception")
  (require! (= 2 (:attach-body @calls))
            (str "typing failure changed source-order work: " @calls))
  (require! (= [1]
             (mapv #(nth % 3)
               (filter #(and (= "function-bodies" (nth % 1))
                             (> (nth % 3) 0))
                       @events)))
            (str "typing failure published a false completion: " @events))
  (require! (not-any? #(= "typing-finalization" (nth % 1)) @events)
            (str "typing failure published finalization: " @events)))

(println "core progress observers: exact calls, receipts, cadence, and errors PASS")
CLJ

PROGRESS_DEFINITIONS="$work/progress-definitions.clj" \
    bb "$work/progress-gate.clj"

grep -Fq 'source (observed-source-program' "$repo/bin/beagle-build-core"
grep -Fq 'freeze-result (observed-freeze-source-stage' "$repo/bin/beagle-build-core"
grep -Fq '(observed-lower-typed-stage' "$repo/bin/beagle-build-core"
grep -Fq 'BEAGLE_CORE_LOWERING_TIMEOUT_SECONDS:-180' "$repo/bin/beagle-build-core"

cat >"$work/progress" <<'REPORT'
stage-progress source-projection ACCEPTED
stage-elapsed source-projection 69460
stage-progress source-freeze ACCEPTED
stage-elapsed source-freeze 454467
stage-progress source-to-typed RUNNING
stage-elapsed source-to-typed 177606
stage-work source-to-typed function-bodies RUNNING 224 738
result RUNNING
REPORT

awk '
    /^publish_interrupted_progress\(\) \{/ { copying = 1 }
    copying { print }
    /^interrupted\(\) \{/ { exit }
' "$repo/bin/beagle-build-core" >"$work/interrupted-progress.sh"
[[ -s "$work/interrupted-progress.sh" ]] || {
    echo "core_progress_publication_gate.sh: interruption boundary was not found" >&2
    exit 1
}

set +e
# The child shell, not this fixture shell, expands its positional argument.
# shellcheck disable=SC2016
timeout -k 5s 1s env BEAGLE_CORE_REPORT="$work/progress" \
    bash -c '
        set -euo pipefail
        source "$1"
        trap interrupted HUP INT TERM
        sleep 120
    ' core-progress-interrupt "$work/interrupted-progress.sh" \
    >"$work/stdout.log" 2>"$work/stderr.log"
rc=$?
set -e

if [[ $rc -ne 124 ]]; then
    echo "core_progress_publication_gate.sh: expected timeout 124, got $rc" >&2
    sed -n '1,120p' "$work/stderr.log" >&2
    exit 1
fi

python3 - "$work/stderr.log" "$work/progress" <<'PY'
import pathlib
import sys

stderr = pathlib.Path(sys.argv[1]).read_text()
progress = pathlib.Path(sys.argv[2]).read_text()
boundary = "beagle build: interrupted Core progress\n"

if stderr.count(boundary) != 1:
    raise SystemExit("interruption did not publish one Core progress boundary")
if stderr.count(progress) != 1:
    raise SystemExit("interruption did not publish the staged progress unchanged once")
if stderr.index(progress) != stderr.index(boundary) + len(boundary):
    raise SystemExit("staged progress did not immediately follow its interruption boundary")
PY

[[ ! -s "$work/stdout.log" ]] || {
    echo "core_progress_publication_gate.sh: progress escaped on stdout" >&2
    exit 1
}

echo "core progress publication: detailed timeout replay PASS"

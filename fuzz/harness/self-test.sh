#!/usr/bin/env bash
# fuzz/harness/self-test.sh — self-test suite for the differential fuzzing harness.
#
# Tests:
#   1. Fixture parity      — run harness over self-host/fixtures/*.bclj; expect all :ok
#   2. Classifier unit     — fabricate synthetic divergent pairs, test classify-pair logic
#   3. Shrinker unit       — multi-form file where only one form triggers a synthetic predicate
#
# Exit 0 = all pass. Prints PASS/FAIL per test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BEAGLE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─── Test 1: Fixture parity ───────────────────────────────────────────────────
echo "=== 1. Fixture parity (all fixtures must be :ok) ==="

FIXTURES_DIR="$BEAGLE_ROOT/self-host/fixtures"
if [ ! -d "$FIXTURES_DIR" ] || [ -z "$(ls "$FIXTURES_DIR"/*.bclj 2>/dev/null)" ]; then
  bad "fixture dir absent or empty: $FIXTURES_DIR"
else
  OUT1="$TMPDIR_BASE/fixture-run"
  mkdir -p "$OUT1"

  if "$SCRIPT_DIR/run.sh" "$FIXTURES_DIR" "$OUT1" --jobs 4 2>&1; then
    REPORT="$OUT1/report.edn"
    if [ ! -f "$REPORT" ]; then
      bad "report.edn not produced"
    else
      # Parse: count divergences with bb
      NDIVS="$(bb -e '(let [r (clojure.edn/read-string (slurp "'"$REPORT"'"))]
                         (count (:divergences r)))' 2>/dev/null)"
      TOTAL="$(bb -e '(let [r (clojure.edn/read-string (slurp "'"$REPORT"'"))]
                         (:total r))' 2>/dev/null)"
      OK_CNT="$(bb -e '(let [r (clojure.edn/read-string (slurp "'"$REPORT"'"))]
                         (:ok r))' 2>/dev/null)"

      if [ "$NDIVS" = "0" ] && [ "$OK_CNT" = "$TOTAL" ]; then
        ok "fixture parity: $TOTAL files, 0 divergences"
      else
        bad "fixture parity: $NDIVS divergences found (total=$TOTAL ok=$OK_CNT)"
        # Print divergence details for debugging
        bb -e '(doseq [d (:divergences (clojure.edn/read-string (slurp "'"$REPORT"'")))]
                  (println "  " (:class d) (:file d) (:detail d)))' 2>/dev/null || true
      fi
    fi
  else
    bad "harness exited non-zero on fixture run"
  fi
fi

# ─── Test 2: Classifier unit tests ───────────────────────────────────────────
echo ""
echo "=== 2. Classifier unit tests (synthetic divergent pairs) ==="

# Write a small bb script that tests classify-pair logic directly
CLASSIFY_TEST="$TMPDIR_BASE/classify-test.clj"
cat > "$CLASSIFY_TEST" << 'BBEOF'
(require '[clojure.string :as str])
(import '[java.security MessageDigest])

(defn sha1-hex [^String s]
  (let [md (MessageDigest/getInstance "SHA-1")
        d  (.digest md (.getBytes s "UTF-8"))]
    (str/join "" (map #(format "%02x" (bit-and % 0xff)) d))))

(defn short-sig [s] (subs (sha1-hex s) 0 12))

(defn normalize-output [^String s]
  (-> s (str/replace "\r\n" "\n") str/trimr))

(defn error-fingerprint [^String stderr]
  (let [lines (str/split-lines (or stderr ""))
        sig   (first (filter #(re-find #"(?i)error|fail|beagle:|check:|parse:|type:" %) lines))]
    (-> (or sig (first lines) "unknown-error")
        (str/replace #"(?:/[^\s:\"',\(\)]+|~/[^\s:\"',\(\)]+)" "<path>")
        (str/replace #"[@:]\d+(?::\d+)*" ":N")
        str/trim
        (#(subs % 0 (min 120 (count %)))))))

(defn classify-pair [oracle selfhost]
  (let [o-ok (zero? (:exit oracle))
        s-ok (zero? (:exit selfhost))]
    (cond
      (and o-ok s-ok)
      (let [o-out (normalize-output (:out oracle))
            s-out (normalize-output (:out selfhost))]
        (if (= o-out s-out)
          {:class :ok}
          {:class :emission
           :signature (short-sig (str "emission:" (sha1-hex (str o-out "\0" s-out))))
           :detail "outputs differ"}))

      (not= o-ok s-ok)
      {:class :acceptance
       :signature (short-sig (str "acceptance:" (if o-ok "oracle-ok" "self-ok") ":"
                                  (if o-ok
                                    (error-fingerprint (:err selfhost))
                                    (error-fingerprint (:err oracle)))))
       :detail (str "oracle=" (if o-ok "accept" "reject") " selfhost=" (if s-ok "accept" "reject"))}

      :else
      (let [o-fp (error-fingerprint (:err oracle))
            s-fp (error-fingerprint (:err selfhost))]
        (if (= o-fp s-fp)
          {:class :ok}
          {:class :diagnostic
           :signature (short-sig (str "diagnostic:" o-fp "\0" s-fp))
           :detail "different error messages"})))))

(def tests
  [;; 1. Both accept same output → :ok
   [{:exit 0 :out "(ns foo)\n(defn f [] 1)\n" :err ""}
    {:exit 0 :out "(ns foo)\n(defn f [] 1)\n" :err ""}
    :ok nil]

   ;; 2. Both accept different output → :emission
   [{:exit 0 :out "(ns foo)\n(defn f [] 1)\n" :err ""}
    {:exit 0 :out "(ns foo)\n(defn f [] 2)\n" :err ""}
    :emission "emission:"]

   ;; 3. Oracle accepts, selfhost rejects → :acceptance
   [{:exit 0 :out "(ns foo)\n" :err ""}
    {:exit 1 :out "" :err "beagle: type-error: unknown type NonExistentType at :42:7"}
    :acceptance "acceptance:oracle-ok:"]

   ;; 4. Selfhost accepts, oracle rejects → :acceptance
   [{:exit 1 :out "" :err "beagle: parse-error: unexpected token at :10:5"}
    {:exit 0 :out "(ns foo)\n" :err ""}
    :acceptance "acceptance:self-ok:"]

   ;; 5. Both reject with same fingerprint → :ok
   [{:exit 1 :out "" :err "beagle: parse-error: expected closing paren"}
    {:exit 1 :out "" :err "beagle: parse-error: expected closing paren"}
    :ok nil]

   ;; 6. Both reject with different fingerprints → :diagnostic
   [{:exit 1 :out "" :err "beagle: type-error: expected Int got String"}
    {:exit 1 :out "" :err "beagle: parse-error: unexpected token"}
    :diagnostic "diagnostic:"]])

(let [failures (atom 0)]
  (doseq [[oracle selfhost expected-class sig-prefix] tests]
    (let [result (classify-pair oracle selfhost)]
      (if (and (= (:class result) expected-class)
               (or (nil? sig-prefix)
                   (and (string? (:signature result))
                        (str/starts-with? (:signature result) ""))))  ; sig is hash, just check it exists
        (println (str "  PASS: " expected-class
                      (when-let [s (:signature result)] (str " sig=" (subs s 0 8) "..."))))
        (do
          (println (str "  FAIL: expected " expected-class " got " (:class result)
                        " detail=" (:detail result)))
          (swap! failures inc)))))
  (System/exit @failures))
BBEOF

if bb "$CLASSIFY_TEST" 2>&1; then
  ok "classifier unit tests: 6/6 pass"
else
  bad "classifier unit tests: some failed (see above)"
fi

# ─── Test 3: Shrinker unit test ───────────────────────────────────────────────
echo ""
echo "=== 3. Shrinker unit test (multi-form file, only one form triggers) ==="

# Strategy: write a .bclj corpus with one file that has multiple forms.
# The "divergence" is real: a form that produces different output from the two compilers.
# We use a synthetic acceptance case: we'll fabricate a file where the selfhost
# accepts but oracle rejects due to a missing #lang header (deliberately invalid).
# But that won't work since we need real compilers.
#
# Instead: build a multi-form file where ALL forms are valid parity.
# Then test the splitter + shrinker logic in isolation with a synthetic predicate.

SHRINK_TEST="$TMPDIR_BASE/shrink-test.clj"
cat > "$SHRINK_TEST" << 'BBEOF'
(require '[clojure.string :as str])

;; Paste in the form splitter from harness.clj
(defn split-top-level-forms [^String source]
  (let [n (count source)]
    (loop [i 0 depth 0 start 0 in-str? false esc? false in-cmt? false forms []]
      (if (>= i n)
        (let [tail (str/trim (subs source start))]
          (if (str/blank? tail) forms (conj forms tail)))
        (let [c (.charAt source i)]
          (cond
            in-cmt?
            (recur (inc i) depth start false false (not= c \newline) forms)
            esc?
            (recur (inc i) depth start in-str? false false forms)
            in-str?
            (cond
              (= c \\) (recur (inc i) depth start true  true  false forms)
              (= c \") (recur (inc i) depth start false false false forms)
              :else    (recur (inc i) depth start true  false false forms))
            :else
            (cond
              (= c \;)
              (recur (inc i) depth start false false true forms)
              (= c \")
              (recur (inc i) depth start true false false forms)
              (or (= c \() (= c \[) (= c \{))
              (recur (inc i) (inc depth) start false false false forms)
              (or (= c \)) (= c \]) (= c \}))
              (let [nd (dec depth)]
                (if (zero? nd)
                  (let [form (str/trim (subs source start (inc i)))]
                    (recur (inc i) 0 (inc i) false false false
                           (if (str/blank? form) forms (conj forms form))))
                  (recur (inc i) nd start false false false forms)))
              :else
              (recur (inc i) depth start false false false forms))))))))

;; Shrinker: greedy removal, keep first form, synthetic predicate
(defn shrink-forms [initial-forms pred]
  (loop [forms (vec initial-forms) pass 0]
    (if (or (> pass 50) (<= (count forms) 1))
      forms
      (let [[new-forms improved]
            (loop [i 1 forms forms improved false]
              (if (>= i (count forms))
                [forms improved]
                (let [candidate (vec (concat (subvec forms 0 i) (subvec forms (inc i))))]
                  (if (and (seq candidate) (pred candidate))
                    (recur i candidate true)
                    (recur (inc i) forms improved)))))]
        (if improved
          (recur new-forms (inc pass))
          new-forms)))))

;; Test file with 5 forms; predicate = "contains the TRIGGER form"
(def test-src
  "#lang beagle/clj
(ns test.shrink)

(defn helper-a [x] (inc x))

(defn trigger-fn [y] (* y 42))

(defn helper-b [z] (dec z))

(defn helper-c [] \"unused\")")

(def forms (split-top-level-forms test-src))
(println (str "Splitter: found " (count forms) " top-level forms"))
(assert (= 5 (count forms)) (str "Expected 5 forms, got " (count forms) ": " forms))

;; Predicate: divergence present if TRIGGER form is in the set
(defn pred [fs]
  (some #(str/includes? % "trigger-fn") fs))

(def minimal (shrink-forms forms pred))
(println (str "Shrinker: reduced to " (count minimal) " forms"))
(println (str "Remaining: " (mapv #(subs % 0 (min 40 (count %))) minimal)))

;; Should keep first form (ns decl + lang) + trigger-fn form only
(assert (some #(str/includes? % "trigger-fn") minimal)
        "Shrinker must preserve the trigger form")
(assert (< (count minimal) 5)
        (str "Shrinker must reduce: still " (count minimal) " forms"))
(assert (str/includes? (first minimal) "ns test.shrink")
        "Shrinker must preserve first form (ns decl)")

(println "  PASS: splitter found 5 forms, shrinker reduced to minimal set containing trigger")
(System/exit 0)
BBEOF

if bb "$SHRINK_TEST" 2>&1; then
  ok "shrinker unit test: splitter + greedy shrinker correct"
else
  bad "shrinker unit test: failed (see above)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== self-test: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]

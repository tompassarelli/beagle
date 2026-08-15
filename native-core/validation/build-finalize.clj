#!/usr/bin/env bb
;; Canonical receipt finalization and generation verification.  The parser only
;; decodes native.stages' length-prefixed canonical records; it is not a second
;; serialization format.

(require '[native.core :as core]
         '[native.stages :as stages]
         '[clojure.string :as str]
         '[clojure.set :as set])

(import '[java.nio.file Files Path StandardOpenOption]
        '[java.security MessageDigest])

(defn fail! [detail]
  (binding [*out* *err*] (println (str "build finalizer: " detail)))
  (System/exit 2))

(defn path [value] (Path/of value (into-array String [])))

(defn sha256-file [value]
  (let [digest (MessageDigest/getInstance "SHA-256")
        bytes (Files/readAllBytes (path value))]
    (.update digest bytes)
    (str "sha256:"
         (apply str (map #(format "%02x" (bit-and (int %) 0xff))
                         (.digest digest))))))

(defn regular-file! [value]
  (when-not (Files/isRegularFile (path value)
                                 (make-array java.nio.file.LinkOption 0))
    (fail! (str "missing input " value))))

(defn write-text! [value text]
  (Files/writeString (path value) text
    (into-array StandardOpenOption
      [StandardOpenOption/CREATE StandardOpenOption/TRUNCATE_EXISTING
       StandardOpenOption/WRITE])))

(defn read-sized [text offset]
  (let [colon (.indexOf ^String text ":" (int offset))]
    (when (or (< colon offset)
              (not (re-matches #"0|[1-9][0-9]*" (subs text offset colon))))
      (fail! "malformed canonical length"))
    (let [size (Long/parseLong (subs text offset colon))
          start (inc colon)
          end (+ start size)]
      (when (> end (count text)) (fail! "truncated canonical field"))
      [(subs text start end) end])))

(defn parse-record [text]
  (let [[tag after-tag] (read-sized text 0)]
    (when (or (>= after-tag (count text))
              (not= \: (nth text after-tag)))
      (fail! (str "canonical record " tag " omitted its field separator")))
    (loop [offset (inc after-tag) fields []]
      (if (= offset (count text))
        {:tag tag :fields fields}
        (let [[field next-offset] (read-sized text offset)]
          (recur next-offset (conj fields field)))))))

(defn required-record [text tag field-count]
  (let [record (parse-record text)]
    (when-not (and (= tag (:tag record))
                   (= field-count (count (:fields record))))
      (fail! (str "expected canonical " tag " with " field-count " fields")))
    record))

(defn string-value [text]
  (first (:fields (required-record text "string" 1))))

(defn id-value [text]
  (first (:fields (required-record text "id" 1))))

(defn artifact-value [text]
  (let [fields (:fields (required-record text "artifact-hash-v0" 2))]
    [(string-value (nth fields 0)) (string-value (nth fields 1))]))

(defn tagged-artifacts [text tag]
  (let [record (parse-record text)]
    (when-not (= tag (:tag record))
      (fail! (str "expected canonical " tag)))
    (mapv artifact-value (:fields record))))

(defn tagged-strings [text tag]
  (let [record (parse-record text)]
    (when-not (= tag (:tag record))
      (fail! (str "expected canonical " tag)))
    (mapv string-value (:fields record))))

(defn receipt-value [text]
  (let [fields (:fields (required-record text "pass-receipt-v0" 13))]
    (let [configuration (tagged-strings (nth fields 5) "configuration-v0")
          configuration-digest (string-value (nth fields 6))]
      (when-not (= configuration-digest
                   (stages/configuration-digest configuration))
        (fail! "receipt configuration digest is broken"))
      {:id (id-value (nth fields 0))
       :input (string-value (nth fields 1))
       :commit (string-value (nth fields 2))
       :pass (string-value (nth fields 3))
       :version (string-value (nth fields 4))
       :configuration-encoding (nth fields 5)
       :configuration configuration
       :configuration-digest configuration-digest
       :output (string-value (nth fields 9))
       :backend (string-value (nth fields 10))
       :backend-version (string-value (nth fields 11))
       :artifacts (tagged-artifacts (nth fields 12) "artifacts-v0")})))

(defn native-receipt-id [receipt]
  (core/nativeid-value
    (core/canonical-id "native-lower-v0/receipt"
      [(:pass receipt) (:input receipt) (:output receipt)])))

(defn artifact-receipt-id [receipt]
  (stages/content-digest
    (stages/canonical-record "artifact-receipt-id-v0"
      [(:pass receipt) (:input receipt) (:output receipt)])))

(defn exact-native-configuration? [configuration]
  (and (= 3 (count configuration))
       (= 3 (count (distinct configuration)))
       (= 1 (count (filter #{"profile=3"} configuration)))
       (= 1 (count (filter #(some? (re-matches #"abi=(lp64|wasm32)" %))
                           configuration)))
       (= 1 (count (filter #(some? (re-matches
                                    #"source-facts-sha256=[0-9a-f]{64}" %))
                           configuration)))))

(defn receipt-file [value]
  (regular-file! value)
  (receipt-value (slurp value)))

(defn native-receipt-values [value]
  (regular-file! value)
  (let [record (parse-record (slurp value))]
    (when-not (= "pass-receipts-v0" (:tag record))
      (fail! "native receipts have the wrong canonical tag"))
    (mapv receipt-value (:fields record))))

(defn validate-native! [receipt-path native-program-path]
  (let [receipts (native-receipt-values receipt-path)
        passes (mapv :pass receipts)]
    (when-not (= ["source-freeze" "source-to-typed" "typed-to-native"
                  "native-to-epoch"] passes)
      (fail! "native receipts are absent, reordered, or duplicated"))
    (let [[source typed native epoch] receipts
          commits (set (map :commit receipts))
          configurations (set (map :configuration-encoding receipts))
          configuration-digests (set (map :configuration-digest receipts))]
      (when-not (and (= 1 (count commits))
                     (= 1 (count configurations))
                     (= 1 (count configuration-digests))
                     (not (str/blank? (:commit source)))
                     (exact-native-configuration? (:configuration source))
                     (every? #(and (= "v0" (:version %))
                                   (= "none" (:backend %))
                                   (= "none" (:backend-version %))
                                   (empty? (:artifacts %))
                                   (= (:id %) (native-receipt-id %)))
                             receipts)
                     (= (:input source) (:output source))
                     (= (:output source) (:input typed))
                     (= (:output typed) (:input native))
                     (= (:output native) (:input epoch))
                     (= (:output epoch) (sha256-file native-program-path)))
        (fail! "Native Core PassReceiptV0 chain is broken"))
      receipts)))

(defn validate-artifacts! [artifacts directory]
  (doseq [[name expected] artifacts]
    (when (or (str/includes? name "/")
              (str/includes? name "\\")
              (not (re-matches #"[A-Za-z0-9._-]+" name)))
      (fail! (str "unsafe managed artifact name " name)))
    (let [value (str directory "/" name)]
      (regular-file! value)
      (when-not (= expected (sha256-file value))
        (fail! (str "artifact hash mismatch for " name))))))

(defn validate-c17! [receipt-path epoch-output native-commit native-configuration
                     directory]
  (let [receipt (receipt-file receipt-path)
        artifact-names (set (map first (:artifacts receipt)))]
    (when-not (and (= "native-to-c17" (:pass receipt))
                   (= "c17" (:backend receipt))
                   (= "v0" (:version receipt))
                   (= "restricted-c17-v0" (:backend-version receipt))
                   (= (:id receipt) (artifact-receipt-id receipt))
                   (= native-commit (:commit receipt))
                   (= native-configuration (:configuration-encoding receipt))
                   (= epoch-output (:input receipt))
                   (= #{"module_0.h" "module_0.c" "native.entry-map"}
                      artifact-names)
                   (= 3 (count (:artifacts receipt)))
                   (= (:output receipt)
                      (stages/artifact-set-digest
                        (mapv (fn [[name digest]]
                                (core/->ArtifactHashV0 name digest))
                              (:artifacts receipt)))))
      (fail! "C17 receipt does not close over the epoch output"))
    (validate-artifacts! (:artifacts receipt) directory)
    receipt))

(defn wasm-input-artifacts [configuration]
  (let [prefix "input-sha256="]
    (mapv
      (fn [entry]
        (let [pair (subs entry (count prefix))
              equals (.indexOf ^String pair "=")]
          (when (<= equals 0) (fail! "malformed Wasm input hash configuration"))
          (let [name (subs pair 0 equals)
                digest (subs pair (inc equals))]
            (when-not (and (re-matches #"[A-Za-z0-9._-]+" name)
                           (re-matches #"sha256:[0-9a-f]{64}" digest))
              (fail! "unsafe Wasm input hash configuration"))
            [name digest])))
      (filter #(str/starts-with? % prefix) configuration))))

(defn validate-wasm! [receipt-path c17-receipt directory]
  (let [receipt (receipt-file receipt-path)
        input-pairs (wasm-input-artifacts (:configuration receipt))
        input-names (mapv first input-pairs)
        input-map (into {} input-pairs)
        input-hashes (mapv (fn [[name digest]]
                             (core/->ArtifactHashV0 name digest))
                           input-pairs)
        expected-input-names
        #{"c17.receipt" "module_0.h" "module_0.c" "native.entry-map"
          "native_shim.h" "native_shim.c" "native_unicode15_data.h"
          "wasm.retention.c" "wasm.adapter.c" "wasm.entry-contract.clj"
          "wasm.seams.clj" "wasm.ast-verifier.rkt"
          "wasm.receipt-finalizer.clj" "wasm.materializer.sh"
          "wasm.supervisor.rkt"
          "wasm.cc-identity.txt" "wasm.ld-identity.txt"
          "wasm.runtime-identity.txt"}
        artifact-names (set (map first (:artifacts receipt)))
        non-input-configuration
        (vec (remove #(str/starts-with? % "input-sha256=")
                     (:configuration receipt)))
        required-prefixes
        ["abi=wasm32" "entry-count=" "export-policy=" "c17-output="
         "cc-identity-sha256=" "ld-identity-sha256="
         "runtime-identity-sha256="]
        entry-count-configuration
        (first (filter #(str/starts-with? % "entry-count=")
                       non-input-configuration))
        entry-count
        (when (and (some? entry-count-configuration)
                   (re-matches #"entry-count=(0|[1-9][0-9]*)"
                               entry-count-configuration))
          (parse-long (subs entry-count-configuration
                            (count "entry-count="))))
        entry-configurations
        (filterv #(re-matches #"entry-[0-9]+=.*" %) non-input-configuration)
        exact-entry-configurations?
        (and (some? entry-count)
             (= entry-count (count entry-configurations))
             (every?
               (fn [position]
                 (let [prefix (str "entry-" position "=")
                       rows (filterv #(str/starts-with? % prefix)
                                     entry-configurations)]
                   (and (= 1 (count rows))
                        (some?
                          (re-matches
                            #"[^\s/]+/[^\s/]+=(pure|arena|capability|arena\+capability)"
                            (subs (first rows) (count prefix)))))))
               (range entry-count)))
        export-configuration
        (first (filter #(str/starts-with? % "export-policy=")
                       non-input-configuration))
        identity-configurations
        #{(str "cc-identity-sha256="
               (get input-map "wasm.cc-identity.txt"))
          (str "ld-identity-sha256="
               (get input-map "wasm.ld-identity.txt"))
          (str "runtime-identity-sha256="
               (get input-map "wasm.runtime-identity.txt"))}
        expected-input
        (stages/content-digest
          (stages/canonical-record "wasm-bootstrap-input-v0"
            [(stages/artifact-set-digest input-hashes)
             (stages/canonical-set "wasm-bootstrap-configuration-v0"
               (mapv stages/encode-string (:configuration receipt)))]))]
    (when-not (and (= (count input-names) (count (distinct input-names)))
                   (= expected-input-names (set input-names))
                   (= "c17-to-wasm" (:pass receipt))
                   (= "v0" (:version receipt))
                   (= "wasm-bootstrap-c17-wasi-clang-v0" (:backend receipt))
                   (= "v0" (:backend-version receipt))
                   (= (:id receipt) (artifact-receipt-id receipt))
                   (= (:commit c17-receipt) (:commit receipt))
                   (some? entry-count)
                   exact-entry-configurations?
                   (= (+ 7 entry-count) (count non-input-configuration))
                   (every?
                     (fn [prefix]
                       (= 1 (count (filter #(str/starts-with? % prefix)
                                           non-input-configuration))))
                     required-prefixes)
                   (every?
                     #(some? (re-matches
                               #"(cc|ld|runtime)-identity-sha256=sha256:[0-9a-f]{64}"
                               %))
                     (filter #(str/includes? % "identity-sha256=")
                             non-input-configuration))
                   (every? (set non-input-configuration)
                           identity-configurations)
                   (or (and (= 0 entry-count)
                            (= "export-policy=reactor-v0"
                               export-configuration))
                       (and (pos? entry-count)
                            (= "export-policy=entries-v1"
                               export-configuration)))
                   (= expected-input (:input receipt))
                   (= (:output receipt)
                      (stages/artifact-set-digest
                        (mapv (fn [[name digest]]
                                (core/->ArtifactHashV0 name digest))
                              (:artifacts receipt))))
                   (= #{"module_0.wasm" "module_0.wasm.seams"}
                      artifact-names)
                   (= 2 (count (:artifacts receipt)))
                   (some #{(str "c17-output=" (:output c17-receipt))}
                         (:configuration receipt)))
      (fail! "Wasm receipt does not close over its exact inputs and artifacts"))
    (validate-artifacts! input-pairs directory)
    (validate-artifacts! (:artifacts receipt) directory)
    receipt))

(defn parse-options [arguments]
  (loop [remaining arguments parsed {:receipt [] :input [] :artifact []
                                     :configuration []}]
    (if (empty? remaining)
      parsed
      (case (first remaining)
        "--receipt"
        (if (< (count remaining) 3) (fail! "--receipt needs NAME PATH")
          (recur (drop 3 remaining)
                 (update parsed :receipt conj [(second remaining)
                                               (nth remaining 2)])))
        "--input"
        (if (< (count remaining) 3) (fail! "--input needs NAME PATH")
          (recur (drop 3 remaining)
                 (update parsed :input conj [(second remaining) (nth remaining 2)])))
        "--artifact"
        (if (< (count remaining) 3) (fail! "--artifact needs NAME PATH")
          (recur (drop 3 remaining)
                 (update parsed :artifact conj [(second remaining) (nth remaining 2)])))
        "--configuration"
        (if (< (count remaining) 2) (fail! "--configuration needs VALUE")
          (recur (drop 2 remaining)
                 (update parsed :configuration conj (second remaining))))
        (fail! (str "unknown option " (first remaining)))))))

(defn artifact-hashes [pairs]
  (mapv (fn [[name value]]
          (regular-file! value)
          (core/->ArtifactHashV0 name (sha256-file value)))
        pairs))

(defn manifest-value [text]
  (let [fields (:fields (required-record text "build-manifest-v0" 2))]
    {:receipts (tagged-artifacts (nth fields 0) "receipts-v0")
     :artifacts (tagged-artifacts (nth fields 1) "managed-artifacts-v0")}))

(def base-artifact-names
  #{"source.facts" "module.native-program" "module.native-program.sha256"
    "native.entry-map" "report.txt"})

(def c17-artifact-names
  #{"module_0.h" "module_0.c" "native_shim.h" "native_shim.c"
    "native_unicode15_data.h" "UNICODE-LICENSE.txt"})

(def parallel-artifact-names #{"native_parallel.h" "native_parallel.c"})

(def simd-artifact-names
  #{"module.simd-plan-v0" "module.simd-plan-v0.sha256"})

(def wasm-artifact-names
  #{"module_0.wasm" "module_0.wasm.sha256" "module_0.wasm.seams"
    "wasm-report.txt" "wasm-audit.txt" "wasm.retention.c" "wasm.adapter.c"
    "wasm.entry-contract.clj" "wasm.seams.clj" "wasm.ast-verifier.rkt"
    "wasm.receipt-finalizer.clj" "wasm.materializer.sh" "wasm.supervisor.rkt"
    "wasm.cc-identity.txt" "wasm.ld-identity.txt" "wasm.runtime-identity.txt"})

(def qbe-artifact-names #{"module_0.ssa"})

(defn exact-generation-sets? [receipt-names artifact-names]
  (let [wasm? (or (contains? receipt-names "wasm.receipt")
                  (not (empty? (set/intersection artifact-names
                                                 wasm-artifact-names))))
        c17? (or wasm?
                 (contains? receipt-names "c17.receipt")
                 (not (empty? (set/intersection artifact-names
                                                c17-artifact-names))))
        qbe? (not (empty? (set/intersection artifact-names qbe-artifact-names)))
        parallel? (not (empty?
                         (set/intersection artifact-names
                           parallel-artifact-names)))
        simd? (not (empty? (set/intersection artifact-names simd-artifact-names)))
        expected-receipts (cond-> #{"native.receipts"}
                            c17? (conj "c17.receipt")
                            wasm? (conj "wasm.receipt"))
        expected-artifacts (cond-> base-artifact-names
                             c17? (set/union c17-artifact-names)
                             parallel? (set/union parallel-artifact-names)
                             simd? (set/union simd-artifact-names)
                             wasm? (set/union wasm-artifact-names)
                             qbe? (set/union qbe-artifact-names))]
    (and (or c17? wasm? qbe?)
         (or (not parallel?) c17?)
         (= expected-receipts receipt-names)
         (= expected-artifacts artifact-names))))

(defn require-one-line! [text line]
  (when-not (= 1 (count (filter #(= line %) (str/split-lines text))))
    (fail! (str "report omits or duplicates " line))))

(defn validate-staged! [directory]
  (let [manifest-path (str directory "/build.manifest")
        manifest (manifest-value (slurp manifest-path))
        receipt-name-list (mapv first (:receipts manifest))
        artifact-name-list (mapv first (:artifacts manifest))
        receipt-names (set receipt-name-list)
        artifact-names (set artifact-name-list)
        required-artifacts #{"source.facts" "module.native-program"
                             "module.native-program.sha256" "native.entry-map"
                             "report.txt"}]
    (when-not (and (= (count receipt-name-list) (count receipt-names))
                   (= (count artifact-name-list) (count artifact-names))
                   (empty? (set/intersection receipt-names artifact-names))
                   (every? artifact-names required-artifacts)
                   (exact-generation-sets? receipt-names artifact-names))
      (fail! "manifest names are duplicate, overlapping, or incomplete"))
    (when (and (contains? artifact-names "module_0.wasm")
               (not (and (contains? receipt-names "wasm.receipt")
                         (contains? receipt-names "c17.receipt"))))
      (fail! "manifest carries Wasm without both Wasm and C17 receipts"))
    (when (and (or (contains? artifact-names "module_0.h")
                   (contains? artifact-names "module_0.c"))
               (not (contains? receipt-names "c17.receipt")))
      (fail! "manifest carries C17 artifacts without their receipt"))
    (validate-artifacts! (:receipts manifest) directory)
    (validate-artifacts! (:artifacts manifest) directory)
    (when-not (contains? receipt-names "native.receipts")
      (fail! "manifest omitted native.receipts"))
    (let [native (validate-native! (str directory "/native.receipts")
                                   (str directory "/module.native-program"))
          epoch-output (:output (last native))
          source-facts-digest (sha256-file (str directory "/source.facts"))
          expected-facts (str "source-facts-sha256=" (subs source-facts-digest 7))]
      (when-not (some #{expected-facts} (:configuration (first native)))
        (fail! "native receipts do not bind source.facts"))
      (when (contains? receipt-names "c17.receipt")
        (let [native-context (last native)
              c17 (validate-c17! (str directory "/c17.receipt") epoch-output
                                  (:commit native-context)
                                  (:configuration-encoding native-context)
                                  directory)]
          (when (contains? receipt-names "wasm.receipt")
            (validate-wasm! (str directory "/wasm.receipt") c17
                            directory))))
      (when (and (contains? receipt-names "wasm.receipt")
                 (not (contains? receipt-names "c17.receipt")))
      (fail! "Wasm receipt exists without its C17 receipt")))
    (let [native-digest-file (str/trim
                               (slurp (str directory
                                           "/module.native-program.sha256")))
          native-digest (subs (sha256-file
                                (str directory "/module.native-program")) 7)]
      (when-not (= native-digest-file native-digest)
        (fail! "module.native-program.sha256 does not bind Native bytes")))
    (when (contains? artifact-names "module.simd-plan-v0")
      (let [simd-digest-file (str/trim
                              (slurp (str directory
                                          "/module.simd-plan-v0.sha256")))
            simd-digest (subs (sha256-file
                                (str directory "/module.simd-plan-v0")) 7)]
        (when-not (= simd-digest-file simd-digest)
          (fail! "module.simd-plan-v0.sha256 does not bind SIMD plan bytes"))))
    (when (contains? artifact-names "module_0.wasm")
      (let [wasm-digest-file (str/trim
                               (slurp (str directory "/module_0.wasm.sha256")))
            wasm-digest (subs (sha256-file
                                (str directory "/module_0.wasm")) 7)]
        (when-not (= wasm-digest-file wasm-digest)
          (fail! "module_0.wasm.sha256 does not bind Wasm bytes"))))
    (let [report-path (str directory "/report.txt")
          report-text (slurp report-path)
          expected-facts (subs (sha256-file (str directory "/source.facts")) 7)
          expected-native (subs (sha256-file
                                  (str directory "/module.native-program")) 7)
          expected-receipts (subs (sha256-file
                                    (str directory "/native.receipts")) 7)]
      (doseq [line [(str "source-facts-sha256 " expected-facts)
                    (str "native-program-file-sha256 " expected-native)
                    (str "native-receipts-file-sha256 " expected-receipts)]]
        (require-one-line! report-text line))
      (when (contains? artifact-names "module_0.wasm")
        (doseq [line [(str "wasm-artifact-sha256 "
                           (subs (sha256-file
                                   (str directory "/module_0.wasm")) 7))
                      (str "wasm-receipt-sha256 "
                           (subs (sha256-file
                                   (str directory "/wasm.receipt")) 7))
                      "wasm-result PASS"]]
          (require-one-line! report-text line)))
      (require-one-line! report-text "result PASS")
      (when-not (str/ends-with? report-text "result PASS\n")
        (fail! "staged report does not end in result PASS")))
    (sha256-file manifest-path)))

(defn validate-generation! [directory]
  (let [marker (str directory "/build.manifest.sha256")]
    (regular-file! marker)
    (let [marker-before (str/trim (slurp marker))]
      (when-not (re-matches #"sha256:[0-9a-f]{64}" marker-before)
        (fail! "commit marker is not one canonical SHA-256"))
      (when-not (= marker-before (validate-staged! directory))
        (fail! "commit marker does not bind build.manifest"))
      (when-not (= marker-before (str/trim (slurp marker)))
        (fail! "commit marker changed during generation verification"))
      (println marker-before))))

(let [[mode output & tail] *command-line-args*]
  (when-not mode (fail! "expected a mode"))
  (case mode
    "generation-set-contract"
    (let [receipt-csv output
          artifact-csv (first tail)
          parse-names (fn [value]
                        (if (or (nil? value) (str/blank? value))
                          #{}
                          (set (str/split value #","))))
          receipt-names (parse-names receipt-csv)
          artifact-names (parse-names artifact-csv)]
      (if (exact-generation-sets? receipt-names artifact-names)
        (println "generation-set-contract PASS")
        (fail! "generation-set-contract REFUSED")))

    "native-index"
    (let [[receipts-path native-program-path] tail
          receipts (validate-native! receipts-path native-program-path)]
      (write-text! output
        (str
          (apply str
            (map (fn [receipt]
                   (str (:pass receipt) "\t" (:input receipt) "\t"
                        (:output receipt) "\t" (:commit receipt) "\t"
                        (:configuration-digest receipt) "\n"))
                 receipts))
          (apply str
            (map (fn [entry] (str "configuration\t" entry "\n"))
                 (:configuration (first receipts)))))))

    "c17-index"
    (let [[receipt-path native-receipts-path native-program-path directory] tail
          native (validate-native! native-receipts-path native-program-path)
          native-context (last native)
          receipt (validate-c17! receipt-path (:output native-context)
                                  (:commit native-context)
                                  (:configuration-encoding native-context)
                                  directory)]
      (write-text! output
        (str "input\t" (:input receipt) "\n"
             "output\t" (:output receipt) "\n"
             (apply str
               (map (fn [[name digest]]
                      (str "artifact\t" name "\t" digest "\n"))
                    (:artifacts receipt))))))

    "wasm-receipt"
    (let [compiler-commit (first tail)
          options (parse-options (rest tail))
          inputs (artifact-hashes (:input options))
          artifacts (artifact-hashes (:artifact options))
          configuration
          (vec (concat (:configuration options)
                 (map (fn [artifact]
                        (str "input-sha256="
                             (core/artifacthashv0-name artifact) "="
                             (core/artifacthashv0-digest artifact)))
                   inputs)))
          input-digest
          (stages/content-digest
            (stages/canonical-record "wasm-bootstrap-input-v0"
              [(stages/artifact-set-digest inputs)
               (stages/canonical-set "wasm-bootstrap-configuration-v0"
                 (mapv stages/encode-string configuration))]))
          receipt (stages/make-artifact-receipt
                    input-digest compiler-commit "c17-to-wasm" configuration
                    "wasm-bootstrap-c17-wasi-clang-v0" "v0" artifacts)]
      (write-text! output (stages/encode-pass-receipt receipt)))

    "manifest"
    (let [options (parse-options tail)
          receipts (artifact-hashes (:receipt options))
          artifacts (artifact-hashes (:artifact options))
          manifest (stages/->BuildManifestV0 receipts artifacts)]
      (write-text! output (stages/encode-build-manifest manifest)))

    "verify-generation"
    (validate-generation! output)

    "verify-staged"
    (println (validate-staged! output))

    (fail! (str "unknown mode " mode))))

;; One exact STORELOG byte corpus is opened through production hosted branch
;; routing and embedded into a Native Core executable that calls
;; store.log-codec/boot-store-log-chain!.
;; Run from the repository root:
;;   tests/run_hosted_test.sh 240s bb -cp out tests/branch_chain_parity_test.clj
(require '[clojure.java.io :as io]
         '[clojure.java.shell :as shell]
         '[clojure.string :as str]
         '[store.branch :as branch]
         '[store.types :as t])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(defn error-code [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo error
      (or (:store/code (ex-data error)) (:type (ex-data error))))))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "store-branch-chain-parity-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(defn cleanup! []
  (doseq [file (reverse (file-seq scratch))]
    (io/delete-file file true)))
(def cleanup-hook (Thread. ^Runnable #(cleanup!)
                           "branch-chain-parity-cleanup"))
(.addShutdownHook (Runtime/getRuntime) cleanup-hook)
(def space "branch-chain-parity-space")

(defn write-bytes! [path ^bytes content]
  (let [file (java.io.File. (str path))]
    (when-let [parent (.getParentFile file)] (.mkdirs parent))
    (java.nio.file.Files/write
     (.toPath file) content
     (into-array java.nio.file.OpenOption
                 [java.nio.file.StandardOpenOption/CREATE
                  java.nio.file.StandardOpenOption/WRITE
                  java.nio.file.StandardOpenOption/TRUNCATE_EXISTING]))))

(defn source-bytes! [name source-space options proposition]
  (let [path (.getPath (io/file scratch (str name ".storelog")))]
    (database/create-triple-log! path source-space options)
    (when proposition
      (database/assert! (database/open-database! path source-space)
                        proposition {}))
    {:path path
     :bytes (java.nio.file.Files/readAllBytes
             (.toPath (java.io.File. path)))}))

(defn sha256 [^bytes content]
  (apply str
         (map #(format "%02x" (bit-and % 255))
              (.digest (java.security.MessageDigest/getInstance "SHA-256")
                       content))))

(defn record [^bytes content start end]
  (branch/->SegmentRecord (sha256 content) start end (alength content)))

(def plain-base
  (source-bytes! "plain-base" space {}
                 (t/triple "plain" :value 1)))
(def deflated-base
  (source-bytes! "deflated-base" space {:deflate? true}
                 (t/triple (apply str (repeat 256 "compressible")) :value 1)))
(def other-space-base
  (source-bytes! "other-space-base" "other-branch-space" {}
                 (t/triple "other" :value 1)))
(def plain-tail
  (source-bytes! "plain-tail" space {:continuation? true} nil))
(def deflated-tail
  (source-bytes! "deflated-tail" space
                 {:deflate? true :continuation? true} nil))
(def base-tail
  (source-bytes! "base-tail" space {} nil))

(def plain-record (record (:bytes plain-base) 1 1))
(def deflated-record (record (:bytes deflated-base) 1 1))
(def other-space-record (record (:bytes other-space-base) 1 1))
(def continuation-record (record (:bytes plain-tail) 0 0))

(def cases
  [{:name "plain-base" :segments [] :tail plain-base :expected "accept"}
   {:name "deflated-base" :segments [] :tail deflated-base
    :expected "reject" :deflated? true}
   {:name "plain-segment-and-tail"
    :segments [{:bytes (:bytes plain-base) :record plain-record}]
    :tail plain-tail :expected "accept"}
   {:name "deflated-segment"
    :segments [{:bytes (:bytes deflated-base) :record deflated-record}]
    :tail plain-tail :expected "reject" :deflated? true}
   {:name "deflated-tail"
    :segments [{:bytes (:bytes plain-base) :record plain-record}]
    :tail deflated-tail :expected "reject" :deflated? true}
   {:name "base-segment-carries-continuation"
    :segments [{:bytes (:bytes plain-tail) :record continuation-record}]
    :tail plain-tail :expected "reject"}
   {:name "branch-tail-lacks-continuation"
    :segments [{:bytes (:bytes plain-base) :record plain-record}]
    :tail base-tail :expected "reject"}
   {:name "segment-sequence-record-mismatch"
    :segments [{:bytes (:bytes plain-base)
                :record (record (:bytes plain-base) 2 2)}]
    :tail plain-tail :expected "reject"}
   {:name "segment-space-mismatch"
    :segments [{:bytes (:bytes other-space-base)
                :record other-space-record}]
    :tail plain-tail :expected "reject"}])

(defn hosted-verdict [index fixture]
  (let [path (.getPath (io/file scratch (str "hosted-" index ".storelog")))
        segments (:segments fixture)]
    (write-bytes! path (:bytes (:tail fixture)))
    (when (seq segments)
      (doseq [{:keys [bytes record]} segments]
        (write-bytes!
         (branch/segment-path path (branch/segmentrecord-sha256 record))
         bytes))
      (write-bytes!
       (branch/ref-path! path branch/default-branch)
       (.getBytes
        (branch/print-ref
         (branch/->RefDocument space (mapv :record segments)))
        java.nio.charset.StandardCharsets/UTF_8)))
    (try
      (database/open-branch! path branch/default-branch space)
      {:verdict "accept" :code nil}
      (catch clojure.lang.ExceptionInfo error
        {:verdict "reject"
         :code (or (:store/code (ex-data error)) (:type (ex-data error)))}))))

(def executable (.getPath (io/file scratch "chain-parity")))
(def artifacts (.getPath (io/file scratch "artifacts")))
(def beagle (.getCanonicalPath (io/file "../bin/beagle")))
(def compiler (or (System/getenv "CC") "cc"))
(def probe "tests/fixtures/branch_chain_parity_probe.bgl")
(def native-sources
  ["src/store/slots.bgl"
   "src/store/rpc_limits.bgl"
   "src/store/types.bgl"
   "src/store/store.bgl"
   "src/store/native_wire_codec.bgl"
   "src/store/chain_rules.bgl"
   "src/store/log_codec.bgl"
   probe])

(def precision-check
  (shell/sh beagle "check" "--agent"
            "tests/fixtures/branch_native_type_precision.bgl"))

(def core-build
  (if-not (zero? (:exit precision-check))
    precision-check
    (apply shell/sh beagle "build"
           "--materializer" "c17"
           "--out" artifacts
           "--entry"
           "store.branch-chain-parity-probe/branch-chain-verdict!"
           "--"
           native-sources)))

(defn lowered-symbol []
  (when (zero? (:exit core-build))
    (some (fn [line]
            (when-let [[_ index]
                       (re-matches
                        #"lowered fn_([0-9]+) branch-chain-verdict!(?: .*)?"
                        line)]
              (str "native_m0_fn_" index)))
          (str/split-lines (slurp (io/file artifacts "report.txt"))))))

(defn exported-prototype [symbol]
  (when symbol
    (some #(when (str/includes? % (str " " symbol "(")) %)
          (str/split-lines (slurp (io/file artifacts "module_0.h"))))))

(defn supported-resource-abi? [symbol prototype]
  (and symbol prototype
       (some?
        (re-matches
         (re-pattern
          (str "native_m0_type_[0-9]+ "
               (java.util.regex.Pattern/quote symbol)
               "\\(native_arena \\*arena, "
               "const native_capability \\*capability, .+\\);"))
         prototype))))

(defn c-bytes [^bytes content]
  (str/join ", " (map #(format "0x%02x" (bit-and % 255)) content)))

(defn c-array [name ^bytes content]
  (str "static const uint8_t " name "[] = {"
       (if (zero? (alength content)) "0x00" (c-bytes content)) "};\n"))

(defn c-case [symbol index fixture]
  (let [segment (first (:segments fixture))
        segment-bytes ^bytes (or (:bytes segment) (byte-array 0))
        record (:record segment)
        tail-bytes ^bytes (:bytes (:tail fixture))]
    (str
     (c-array (str "segment_" index) segment-bytes)
     (c-array (str "tail_" index) tail-bytes)
     "static int run_case_" index "(void) {\n"
     "  native_arena arena;\n"
     "  uint8_t *space_bytes = NULL;\n"
     "  uint64_t configured_space;\n"
     "  const native_capability capability = {UINT64_C(1)};\n"
     "  native_byte_source *segment;\n"
     "  native_byte_source *tail;\n"
     "  int64_t actual;\n"
     "  if (!native_arena_init_growable(&arena, (size_t)(64U * 1024U * 1024U))) return 2;\n"
     "  configured_space = native_text_alloc(&arena, UINT64_C("
     (count space) "), &space_bytes);\n"
     "  memcpy(space_bytes, \"" space "\", " (count space) ");\n"
     "  segment = native_byte_source_borrow(&arena, segment_" index
     ", INT64_C(" (alength segment-bytes) "));\n"
     "  tail = native_byte_source_borrow(&arena, tail_" index
     ", INT64_C(" (alength tail-bytes) "));\n"
     "  actual = " symbol "(&arena, &capability, configured_space, "
     (if segment "true" "false") ", segment, INT64_C("
     (if record (branch/segmentrecord-start-sequence record) 0)
     "), INT64_C("
     (if record (branch/segmentrecord-end-sequence record) 0)
     "), INT64_C("
     (if record (branch/segmentrecord-byte-count record) 0)
     "), tail);\n"
     "  native_arena_destroy(&arena);\n"
     "  return (int)actual;\n"
     "}\n")))

(defn harness-source [symbol]
  (str
   "#include \"module_0.h\"\n"
   "#include <stdint.h>\n"
   "#include <stdio.h>\n"
   "#include <string.h>\n\n"
   (apply str (map-indexed #(c-case symbol %1 %2) cases))
   "int main(int argc, char **argv) {\n"
   "  if (argc != 2) return 2;\n"
   (apply str
          (map-indexed
           (fn [index _]
             (str "  if (strcmp(argv[1], \"" index
                  "\") == 0) return run_case_" index "();\n"))
           cases))
   "  return 2;\n"
   "}\n"))

(def harness (.getPath (io/file scratch "parity_harness.c")))
(def symbol (lowered-symbol))
(def prototype (exported-prototype symbol))
(def resource-abi? (supported-resource-abi? symbol prototype))
(when resource-abi? (spit harness (harness-source symbol)))

(def build
  (if-not resource-abi?
    {:exit 1 :out (:out core-build)
     :err (str (:err core-build)
               (when prototype
                 (str "\nunsupported generated resource ABI: " prototype)))}
    (apply shell/sh compiler
           "-std=c17" "-pedantic" "-Wall" "-Wextra" "-Werror"
           "-I" artifacts
           (.getPath (io/file artifacts "module_0.c"))
           (.getPath (io/file artifacts "native_shim.c"))
           harness "-o" executable [])))

(def results
  (when (zero? (:exit build))
    (mapv
     (fn [index fixture]
       (let [hosted (hosted-verdict index fixture)
             native (shell/sh executable (str index))]
         {:name (:name fixture)
          :expected (:expected fixture)
          :deflated? (:deflated? fixture)
          :hosted (:verdict hosted)
          :hosted-code (:code hosted)
          :native (case (:exit native) 0 "accept" 1 "reject" "invalid")}))
     (range) cases)))

(println "branch chain parity:")
(check! "the compiler accepts borrowed ByteSource nth and typed Atom deref"
        (zero? (:exit precision-check)))
(check! "the Native Core production probe compiles and links without a JVM"
        (zero? (:exit build)))
(check! "flat hosted STORELOG still accepts valid Deflate records"
        (= #{(t/triple (apply str (repeat 256 "compressible")) :value 1)}
           (set (database/live-propositions!
                 (database/open-database! (:path deflated-base) space)))))
(let [path (.getPath (io/file scratch "deflated-torn-repair.storelog"))
      source ^bytes (:bytes deflated-base)
      torn (java.util.Arrays/copyOf source (inc (alength source)))]
  (write-bytes! path torn)
  (check! "branch Deflate refusal precedes repair-torn mutation"
          (and (= :unsupported-branch-chain-encoding
                  (error-code
                   #(database/open-branch!
                     path branch/default-branch space {:repair-torn? true})))
               (java.util.Arrays/equals
                torn
                (java.nio.file.Files/readAllBytes
                 (.toPath (java.io.File. path)))))))
(let [before (:bytes deflated-base)
      fork-code (error-code #(database/fork-store! (:path deflated-base)
                                                   "fork-child"))]
  (check! "branch fork rejects Deflate before changing the source or routing"
          (and (= :unsupported-branch-chain-encoding fork-code)
               (java.util.Arrays/equals
                ^bytes before
                ^bytes (java.nio.file.Files/readAllBytes
                         (.toPath (java.io.File. (:path deflated-base)))))
               (not (.exists
                     (java.io.File.
                      (branch/refs-directory (:path deflated-base)))))
               (not (.exists
                     (java.io.File.
                      (str (:path deflated-base) ".fork")))))))
(check! "the exact corpus covers plain acceptance, all Deflate positions, and structural faults"
        (and (= 9 (count cases))
             (= 3 (count (filter :deflated? cases)))
             (= #{"accept" "reject"} (set (map :expected cases)))))
(check! "hosted open-branch! matches every expected byte-corpus verdict"
        (every? #(= (:expected %) (:hosted %)) results))
(check! "hosted branch routing rejects every Deflate position explicitly"
        (every? #(= :unsupported-branch-chain-encoding (:hosted-code %))
                (filter :deflated? results)))
(check! "Native Core boot-store-log-chain! matches hosted production routing"
        (every? #(= (:hosted %) (:native %)) results))

(when-not (zero? (:exit build))
  (binding [*out* *err*]
    (println (:out build))
    (println (:err build))))

(let [failures (remove second @checks)]
  (.removeShutdownHook (Runtime/getRuntime) cleanup-hook)
  (cleanup!)
  (shutdown-agents)
  (if (empty? failures)
    (println "\nbranch chain parity:" (count @checks) "/" (count @checks)
             "PASS")
    (do
      (println "\nbranch chain parity:" (count failures) "FAILED")
      (doseq [result results]
        (when-not (= (:expected result) (:hosted result) (:native result))
          (println "  " result)))
      (System/exit 1))))

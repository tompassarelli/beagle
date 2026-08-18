(ns store.dev-compile-facts
  (:gen-class)
  (:import [java.io File]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]))

^{:line 27 :file "store/src/store/dev_compile_facts.bclj"} (clojure.core/require 'store.rt)

^{:line 28 :file "store/src/store/dev_compile_facts.bclj"} (let [raw-emitted-file ^{:line 28 :file "store/src/store/dev_compile_facts.bclj"} (File. ^{:line 28 :file "store/src/store/dev_compile_facts.bclj"} (str *file*))
   emitted-file ^{:line 29 :file "store/src/store/dev_compile_facts.bclj"} (.getCanonicalFile raw-emitted-file)
   emitted-namespace-directory ^{:line 30 :file "store/src/store/dev_compile_facts.bclj"} (.getParentFile emitted-file)
   out-directory ^{:line 31 :file "store/src/store/dev_compile_facts.bclj"} (.getParentFile emitted-namespace-directory)
   store-directory ^{:line 32 :file "store/src/store/dev_compile_facts.bclj"} (.getParentFile out-directory)]
  ^{:line 33 :file "store/src/store/dev_compile_facts.bclj"} (clojure.core/load-file ^{:line 34 :file "store/src/store/dev_compile_facts.bclj"} (str ^{:line 34 :file "store/src/store/dev_compile_facts.bclj"} (.getPath store-directory) "/database.clj")))

^{:line 36 :file "store/src/store/dev_compile_facts.bclj"} (def ^String space-id "beagle-dev-compile-facts-v1")

^{:line 37 :file "store/src/store/dev_compile_facts.bclj"} (def ^String subject-tag "store.dev-compile-facts/result-v1")

^{:line 38 :file "store/src/store/dev_compile_facts.bclj"} (def ^String fact-kind "DevCompileUnitResultV1")

^{:line 40 :file "store/src/store/dev_compile_facts.bclj"} (defrecord CompileFact [stage result-key id encoding])

(defn compilefact-stage [r] (:stage r))

(defn compilefact-result-key [r] (:result-key r))

(defn compilefact-id [r] (:id r))

(defn compilefact-encoding [r] (:encoding r))

^{:line 43 :file "store/src/store/dev_compile_facts.bclj"} (defrecord AppendCounts [appended retained])

(defn appendcounts-appended [r] (:appended r))

(defn appendcounts-retained [r] (:retained r))

^{:line 45 :file "store/src/store/dev_compile_facts.bclj"} (defn- fail [^String message code]
  ^{:line 46 :file "store/src/store/dev_compile_facts.bclj"} (throw ^{:line 46 :file "store/src/store/dev_compile_facts.bclj"} (ex-info message ^{:line 46 :file "store/src/store/dev_compile_facts.bclj"} {:type code :fram/code code})))

^{:line 48 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^Boolean nonempty-string? [value]
  ^{:line 49 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 49 :file "store/src/store/dev_compile_facts.bclj"} (string? value) ^{:line 49 :file "store/src/store/dev_compile_facts.bclj"} (pos? ^{:line 49 :file "store/src/store/dev_compile_facts.bclj"} (count value))))

^{:line 51 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^Boolean exact-sha256? [value]
  ^{:line 52 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 52 :file "store/src/store/dev_compile_facts.bclj"} (string? value) ^{:line 53 :file "store/src/store/dev_compile_facts.bclj"} (some? ^{:line 53 :file "store/src/store/dev_compile_facts.bclj"} (re-matches #"sha256:[0-9a-f]{64}" value))))

^{:line 55 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^Boolean allowed-stage? [value]
  ^{:line 56 :file "store/src/store/dev_compile_facts.bclj"} (or ^{:line 56 :file "store/src/store/dev_compile_facts.bclj"} (= "typed" value) ^{:line 56 :file "store/src/store/dev_compile_facts.bclj"} (= "native" value)))

^{:line 58 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^String sha256-id [^String text]
  ^{:line 59 :file "store/src/store/dev_compile_facts.bclj"} (str "sha256:" ^{:line 61 :file "store/src/store/dev_compile_facts.bclj"} (apply str ^{:line 63 :file "store/src/store/dev_compile_facts.bclj"} (mapv ^{:line 64 :file "store/src/store/dev_compile_facts.bclj"} (fn [value] ^{:line 65 :file "store/src/store/dev_compile_facts.bclj"} (format "%02x" ^{:line 65 :file "store/src/store/dev_compile_facts.bclj"} (bit-and ^{:line 65 :file "store/src/store/dev_compile_facts.bclj"} (int value) 255))) ^{:line 66 :file "store/src/store/dev_compile_facts.bclj"} (vec ^{:line 67 :file "store/src/store/dev_compile_facts.bclj"} (.digest ^{:line 67 :file "store/src/store/dev_compile_facts.bclj"} (MessageDigest/getInstance "SHA-256") ^{:line 68 :file "store/src/store/dev_compile_facts.bclj"} (.getBytes text StandardCharsets/UTF_8)))))))

^{:line 70 :file "store/src/store/dev_compile_facts.bclj"} (defn- payload-byte-count [^String payload]
  ^{:line 71 :file "store/src/store/dev_compile_facts.bclj"} (count ^{:line 71 :file "store/src/store/dev_compile_facts.bclj"} (vec ^{:line 71 :file "store/src/store/dev_compile_facts.bclj"} (.getBytes payload StandardCharsets/UTF_8))))

^{:line 73 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^String absolute-store-path [value]
  ^{:line 74 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 74 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 74 :file "store/src/store/dev_compile_facts.bclj"} (string? value) ^{:line 74 :file "store/src/store/dev_compile_facts.bclj"} (some? ^{:line 74 :file "store/src/store/dev_compile_facts.bclj"} (re-matches #"/.*" value))) value ^{:line 76 :file "store/src/store/dev_compile_facts.bclj"} (fail "development fact Store path must be absolute" :dev-compile-facts/relative-route)))

^{:line 79 :file "store/src/store/dev_compile_facts.bclj"} (defn ^CompileFact compile-fact [^String id ^String encoding]
  ^{:line 80 :file "store/src/store/dev_compile_facts.bclj"} (let [envelope ^{:line 80 :file "store/src/store/dev_compile_facts.bclj"} (store.rt/parse-edn encoding)]
  ^{:line 81 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 81 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 81 :file "store/src/store/dev_compile_facts.bclj"} (vector? envelope) ^{:line 81 :file "store/src/store/dev_compile_facts.bclj"} (= 9 ^{:line 81 :file "store/src/store/dev_compile_facts.bclj"} (count envelope))) ^{:line 84 :file "store/src/store/dev_compile_facts.bclj"} (let [kind ^{:line 84 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 0)
   stage ^{:line 85 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 1)
   result-key ^{:line 86 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 2)
   compiler-context ^{:line 87 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 3)
   profile ^{:line 88 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 4)
   unit-id ^{:line 89 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 5)
   byte-count ^{:line 90 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 6)
   digest ^{:line 91 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 7)
   payload ^{:line 92 :file "store/src/store/dev_compile_facts.bclj"} (nth envelope 8)]
  ^{:line 93 :file "store/src/store/dev_compile_facts.bclj"} (cond
  ^{:line 94 :file "store/src/store/dev_compile_facts.bclj"} (not= fact-kind kind) ^{:line 95 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact envelope has an unknown kind" :dev-compile-facts/unknown-kind)
  ^{:line 97 :file "store/src/store/dev_compile_facts.bclj"} (not= encoding ^{:line 97 :file "store/src/store/dev_compile_facts.bclj"} (pr-str envelope)) ^{:line 98 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact envelope must be canonical EDN" :dev-compile-facts/noncanonical-envelope)
  ^{:line 100 :file "store/src/store/dev_compile_facts.bclj"} (not ^{:line 100 :file "store/src/store/dev_compile_facts.bclj"} (allowed-stage? stage)) ^{:line 101 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact stage must be typed or native" :dev-compile-facts/invalid-stage)
  ^{:line 103 :file "store/src/store/dev_compile_facts.bclj"} (not ^{:line 103 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 103 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? id) ^{:line 104 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? result-key) ^{:line 105 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? compiler-context) ^{:line 106 :file "store/src/store/dev_compile_facts.bclj"} (nonempty-string? profile) ^{:line 107 :file "store/src/store/dev_compile_facts.bclj"} (nonempty-string? unit-id) ^{:line 108 :file "store/src/store/dev_compile_facts.bclj"} (integer? byte-count) ^{:line 109 :file "store/src/store/dev_compile_facts.bclj"} (<= 0 byte-count) ^{:line 110 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? digest) ^{:line 111 :file "store/src/store/dev_compile_facts.bclj"} (string? payload))) ^{:line 112 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact envelope metadata is malformed" :dev-compile-facts/invalid-envelope)
  ^{:line 114 :file "store/src/store/dev_compile_facts.bclj"} (not= id ^{:line 114 :file "store/src/store/dev_compile_facts.bclj"} (sha256-id encoding)) ^{:line 115 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact id does not match its canonical envelope" :dev-compile-facts/fact-id-mismatch)
  ^{:line 117 :file "store/src/store/dev_compile_facts.bclj"} (or ^{:line 117 :file "store/src/store/dev_compile_facts.bclj"} (not= byte-count ^{:line 117 :file "store/src/store/dev_compile_facts.bclj"} (payload-byte-count payload)) ^{:line 118 :file "store/src/store/dev_compile_facts.bclj"} (not= digest ^{:line 118 :file "store/src/store/dev_compile_facts.bclj"} (sha256-id payload))) ^{:line 119 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact payload bytes do not match its digest" :dev-compile-facts/payload-mismatch)
  :else ^{:line 121 :file "store/src/store/dev_compile_facts.bclj"} (->CompileFact stage result-key id encoding))) ^{:line 82 :file "store/src/store/dev_compile_facts.bclj"} (fail "compile fact envelope must have nine vector fields" :dev-compile-facts/invalid-envelope))))

^{:line 123 :file "store/src/store/dev_compile_facts.bclj"} (defn- fact-subject [^String stage ^String result-key]
  ^{:line 124 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple subject-tag stage result-key))

^{:line 126 :file "store/src/store/dev_compile_facts.bclj"} (defn- fact-proposition [^CompileFact entry]
  ^{:line 127 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple ^{:line 128 :file "store/src/store/dev_compile_facts.bclj"} (fact-subject ^{:line 128 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-stage entry) ^{:line 129 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-result-key entry)) fact-kind ^{:line 131 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-encoding entry)))

^{:line 136 :file "store/src/store/dev_compile_facts.bclj"} (defn- proposition-entry [proposition]
  ^{:line 137 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 137 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple? proposition) ^{:line 139 :file "store/src/store/dev_compile_facts.bclj"} (let [subject ^{:line 139 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t1 proposition)
   kind ^{:line 140 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t2 proposition)
   encoding ^{:line 141 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t3 proposition)]
  ^{:line 142 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 142 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 142 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple? subject) ^{:line 143 :file "store/src/store/dev_compile_facts.bclj"} (= subject-tag ^{:line 143 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t1 subject)) ^{:line 144 :file "store/src/store/dev_compile_facts.bclj"} (allowed-stage? ^{:line 144 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t2 subject)) ^{:line 145 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? ^{:line 145 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t3 subject)) ^{:line 146 :file "store/src/store/dev_compile_facts.bclj"} (= fact-kind kind) ^{:line 147 :file "store/src/store/dev_compile_facts.bclj"} (string? encoding)) ^{:line 148 :file "store/src/store/dev_compile_facts.bclj"} (->CompileFact ^{:line 149 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t2 subject) ^{:line 150 :file "store/src/store/dev_compile_facts.bclj"} (store.types/triple-t3 subject) ^{:line 151 :file "store/src/store/dev_compile_facts.bclj"} (sha256-id encoding) encoding) nil)) nil))

^{:line 155 :file "store/src/store/dev_compile_facts.bclj"} (defn- all-facts [database]
  ^{:line 156 :file "store/src/store/dev_compile_facts.bclj"} (reduce ^{:line 157 :file "store/src/store/dev_compile_facts.bclj"} (fn [entries proposition] ^{:line 158 :file "store/src/store/dev_compile_facts.bclj"} (let [entry ^{:line 158 :file "store/src/store/dev_compile_facts.bclj"} (proposition-entry proposition)]
  ^{:line 159 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 159 :file "store/src/store/dev_compile_facts.bclj"} (some? entry) ^{:line 159 :file "store/src/store/dev_compile_facts.bclj"} (conj entries entry) entries))) ^{:line 160 :file "store/src/store/dev_compile_facts.bclj"} [] ^{:line 161 :file "store/src/store/dev_compile_facts.bclj"} (database/live-propositions database)))

^{:line 163 :file "store/src/store/dev_compile_facts.bclj"} (defn- facts-for-key [entries ^String stage ^String result-key]
  ^{:line 168 :file "store/src/store/dev_compile_facts.bclj"} (filterv ^{:line 169 :file "store/src/store/dev_compile_facts.bclj"} (fn [^CompileFact entry] ^{:line 170 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 170 :file "store/src/store/dev_compile_facts.bclj"} (= stage ^{:line 170 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-stage entry)) ^{:line 171 :file "store/src/store/dev_compile_facts.bclj"} (= result-key ^{:line 171 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-result-key entry)))) entries))

^{:line 174 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^Boolean same-entry? [^CompileFact left ^CompileFact right]
  ^{:line 175 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 175 :file "store/src/store/dev_compile_facts.bclj"} (= ^{:line 175 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-stage left) ^{:line 175 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-stage right)) ^{:line 176 :file "store/src/store/dev_compile_facts.bclj"} (= ^{:line 176 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-result-key left) ^{:line 176 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-result-key right)) ^{:line 177 :file "store/src/store/dev_compile_facts.bclj"} (= ^{:line 177 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-id left) ^{:line 177 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-id right)) ^{:line 178 :file "store/src/store/dev_compile_facts.bclj"} (= ^{:line 178 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-encoding left) ^{:line 178 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-encoding right))))

^{:line 180 :file "store/src/store/dev_compile_facts.bclj"} (defn- create-or-open! [^String path]
  ^{:line 181 :file "store/src/store/dev_compile_facts.bclj"} (let [file ^{:line 181 :file "store/src/store/dev_compile_facts.bclj"} (File. path)
   parent ^{:line 182 :file "store/src/store/dev_compile_facts.bclj"} (.getParentFile file)]
  ^{:line 183 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 183 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 183 :file "store/src/store/dev_compile_facts.bclj"} (some? parent) ^{:line 183 :file "store/src/store/dev_compile_facts.bclj"} (not ^{:line 183 :file "store/src/store/dev_compile_facts.bclj"} (.isDirectory parent))) ^{:line 184 :file "store/src/store/dev_compile_facts.bclj"} (.mkdirs parent) nil)
  ^{:line 186 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 186 :file "store/src/store/dev_compile_facts.bclj"} (.exists file) nil ^{:line 188 :file "store/src/store/dev_compile_facts.bclj"} (database/create-triple-log! path space-id))
  ^{:line 189 :file "store/src/store/dev_compile_facts.bclj"} (database/open-database! path space-id)))

^{:line 191 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^String revision-identity [^String path]
  ^{:line 192 :file "store/src/store/dev_compile_facts.bclj"} (let [revision ^{:line 192 :file "store/src/store/dev_compile_facts.bclj"} (database/branch-revision! path)
   identity ^{:line 193 :file "store/src/store/dev_compile_facts.bclj"} (:identity revision)]
  ^{:line 194 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 194 :file "store/src/store/dev_compile_facts.bclj"} (string? identity) identity ^{:line 196 :file "store/src/store/dev_compile_facts.bclj"} (fail "Store returned no branch revision identity" :dev-compile-facts/revision-unresolved))))

^{:line 199 :file "store/src/store/dev_compile_facts.bclj"} (defn- append-propositions! [database propositions]
  ^{:line 200 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 200 :file "store/src/store/dev_compile_facts.bclj"} (empty? propositions) nil ^{:line 202 :file "store/src/store/dev_compile_facts.bclj"} (do
  ^{:line 203 :file "store/src/store/dev_compile_facts.bclj"} (database/commit! database ^{:line 205 :file "store/src/store/dev_compile_facts.bclj"} {:actor "store.dev-compile-facts/v1" :operations ^{:line 207 :file "store/src/store/dev_compile_facts.bclj"} (mapv ^{:line 208 :file "store/src/store/dev_compile_facts.bclj"} (fn [proposition] ^{:line 209 :file "store/src/store/dev_compile_facts.bclj"} {:action :assert :proposition proposition}) propositions)})
  nil)))

^{:line 213 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^AppendCounts append-entries! [database entries]
  ^{:line 214 :file "store/src/store/dev_compile_facts.bclj"} (let [known ^{:line 214 :file "store/src/store/dev_compile_facts.bclj"} (all-facts database)
   pending ^{:line 216 :file "store/src/store/dev_compile_facts.bclj"} (reduce ^{:line 217 :file "store/src/store/dev_compile_facts.bclj"} (fn [accepted ^CompileFact entry] ^{:line 219 :file "store/src/store/dev_compile_facts.bclj"} (let [candidates ^{:line 220 :file "store/src/store/dev_compile_facts.bclj"} (facts-for-key ^{:line 221 :file "store/src/store/dev_compile_facts.bclj"} (vec ^{:line 221 :file "store/src/store/dev_compile_facts.bclj"} (concat known accepted)) ^{:line 222 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-stage entry) ^{:line 223 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-result-key entry))]
  ^{:line 224 :file "store/src/store/dev_compile_facts.bclj"} (cond
  ^{:line 225 :file "store/src/store/dev_compile_facts.bclj"} (empty? candidates) ^{:line 225 :file "store/src/store/dev_compile_facts.bclj"} (conj accepted entry)
  ^{:line 226 :file "store/src/store/dev_compile_facts.bclj"} (every? ^{:line 227 :file "store/src/store/dev_compile_facts.bclj"} (fn [^CompileFact candidate] ^{:line 228 :file "store/src/store/dev_compile_facts.bclj"} (same-entry? candidate entry)) candidates) accepted
  :else ^{:line 232 :file "store/src/store/dev_compile_facts.bclj"} (fail ^{:line 233 :file "store/src/store/dev_compile_facts.bclj"} (str "compile fact result key has conflicting content: " ^{:line 234 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-result-key entry)) :dev-compile-facts/conflicting-fact)))) ^{:line 236 :file "store/src/store/dev_compile_facts.bclj"} [] entries)]
  ^{:line 238 :file "store/src/store/dev_compile_facts.bclj"} (append-propositions! database ^{:line 238 :file "store/src/store/dev_compile_facts.bclj"} (mapv fact-proposition pending))
  ^{:line 239 :file "store/src/store/dev_compile_facts.bclj"} (->AppendCounts ^{:line 239 :file "store/src/store/dev_compile_facts.bclj"} (count pending) ^{:line 239 :file "store/src/store/dev_compile_facts.bclj"} (- ^{:line 239 :file "store/src/store/dev_compile_facts.bclj"} (count entries) ^{:line 239 :file "store/src/store/dev_compile_facts.bclj"} (count pending)))))

^{:line 241 :file "store/src/store/dev_compile_facts.bclj"} (defn append! [^String path entries]
  ^{:line 242 :file "store/src/store/dev_compile_facts.bclj"} (let [authority ^{:line 242 :file "store/src/store/dev_compile_facts.bclj"} (writer-authority/acquire! path)]
  ^{:line 243 :file "store/src/store/dev_compile_facts.bclj"} (try
  ^{:line 244 :file "store/src/store/dev_compile_facts.bclj"} (let [database ^{:line 244 :file "store/src/store/dev_compile_facts.bclj"} (create-or-open! path)
   counts ^{:line 245 :file "store/src/store/dev_compile_facts.bclj"} (append-entries! database entries)]
  ^{:line 246 :file "store/src/store/dev_compile_facts.bclj"} ["store.dev-compile-facts/append-response-v1" "ok" ^{:line 248 :file "store/src/store/dev_compile_facts.bclj"} (revision-identity path) ^{:line 249 :file "store/src/store/dev_compile_facts.bclj"} (appendcounts-appended counts) ^{:line 250 :file "store/src/store/dev_compile_facts.bclj"} (appendcounts-retained counts)])
  (finally
    ^{:line 251 :file "store/src/store/dev_compile_facts.bclj"} (writer-authority/release! authority)))))

^{:line 253 :file "store/src/store/dev_compile_facts.bclj"} (defn- request-row [value]
  ^{:line 254 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 254 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 254 :file "store/src/store/dev_compile_facts.bclj"} (vector? value) ^{:line 255 :file "store/src/store/dev_compile_facts.bclj"} (= 5 ^{:line 255 :file "store/src/store/dev_compile_facts.bclj"} (count value)) ^{:line 256 :file "store/src/store/dev_compile_facts.bclj"} (allowed-stage? ^{:line 256 :file "store/src/store/dev_compile_facts.bclj"} (nth value 0)) ^{:line 257 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? ^{:line 257 :file "store/src/store/dev_compile_facts.bclj"} (nth value 1)) ^{:line 258 :file "store/src/store/dev_compile_facts.bclj"} (exact-sha256? ^{:line 258 :file "store/src/store/dev_compile_facts.bclj"} (nth value 2)) ^{:line 259 :file "store/src/store/dev_compile_facts.bclj"} (nonempty-string? ^{:line 259 :file "store/src/store/dev_compile_facts.bclj"} (nth value 3)) ^{:line 260 :file "store/src/store/dev_compile_facts.bclj"} (nonempty-string? ^{:line 260 :file "store/src/store/dev_compile_facts.bclj"} (nth value 4))) ^{:line 261 :file "store/src/store/dev_compile_facts.bclj"} [^{:line 261 :file "store/src/store/dev_compile_facts.bclj"} (nth value 0) ^{:line 261 :file "store/src/store/dev_compile_facts.bclj"} (nth value 1) ^{:line 261 :file "store/src/store/dev_compile_facts.bclj"} (nth value 2) ^{:line 262 :file "store/src/store/dev_compile_facts.bclj"} (nth value 3) ^{:line 262 :file "store/src/store/dev_compile_facts.bclj"} (nth value 4)] ^{:line 263 :file "store/src/store/dev_compile_facts.bclj"} (fail "query row must be [stage key context profile unit-id]" :dev-compile-facts/invalid-query)))

^{:line 266 :file "store/src/store/dev_compile_facts.bclj"} (defn- query-rows [facts requests]
  ^{:line 268 :file "store/src/store/dev_compile_facts.bclj"} (reduce ^{:line 269 :file "store/src/store/dev_compile_facts.bclj"} (fn [rows request] ^{:line 270 :file "store/src/store/dev_compile_facts.bclj"} (let [stage ^{:line 270 :file "store/src/store/dev_compile_facts.bclj"} (nth request 0)
   result-key ^{:line 271 :file "store/src/store/dev_compile_facts.bclj"} (nth request 1)
   matches ^{:line 273 :file "store/src/store/dev_compile_facts.bclj"} (facts-for-key facts stage result-key)]
  ^{:line 274 :file "store/src/store/dev_compile_facts.bclj"} (vec ^{:line 275 :file "store/src/store/dev_compile_facts.bclj"} (concat rows ^{:line 277 :file "store/src/store/dev_compile_facts.bclj"} (mapv ^{:line 278 :file "store/src/store/dev_compile_facts.bclj"} (fn [^CompileFact entry] ^{:line 279 :file "store/src/store/dev_compile_facts.bclj"} [stage result-key ^{:line 280 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-id entry) ^{:line 281 :file "store/src/store/dev_compile_facts.bclj"} (compilefact-encoding entry)]) matches))))) ^{:line 283 :file "store/src/store/dev_compile_facts.bclj"} [] requests))

^{:line 286 :file "store/src/store/dev_compile_facts.bclj"} (defn query! [^String path requests]
  ^{:line 287 :file "store/src/store/dev_compile_facts.bclj"} (let [file ^{:line 287 :file "store/src/store/dev_compile_facts.bclj"} (File. path)]
  ^{:line 288 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 288 :file "store/src/store/dev_compile_facts.bclj"} (.isFile file) ^{:line 291 :file "store/src/store/dev_compile_facts.bclj"} (let [database ^{:line 291 :file "store/src/store/dev_compile_facts.bclj"} (database/open-database! path space-id)
   facts ^{:line 292 :file "store/src/store/dev_compile_facts.bclj"} (all-facts database)]
  ^{:line 293 :file "store/src/store/dev_compile_facts.bclj"} ["store.dev-compile-facts/query-response-v1" "ONLINE" ^{:line 295 :file "store/src/store/dev_compile_facts.bclj"} (revision-identity path) requests ^{:line 297 :file "store/src/store/dev_compile_facts.bclj"} (query-rows facts requests)]) ^{:line 289 :file "store/src/store/dev_compile_facts.bclj"} ["store.dev-compile-facts/query-response-v1" "COLD" "" requests ^{:line 290 :file "store/src/store/dev_compile_facts.bclj"} []])))

^{:line 299 :file "store/src/store/dev_compile_facts.bclj"} (defn- request-vector [^String expected-tag]
  ^{:line 300 :file "store/src/store/dev_compile_facts.bclj"} (let [line ^{:line 300 :file "store/src/store/dev_compile_facts.bclj"} (read-line)
   value ^{:line 302 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 302 :file "store/src/store/dev_compile_facts.bclj"} (string? line) ^{:line 302 :file "store/src/store/dev_compile_facts.bclj"} (store.rt/parse-edn line) nil)]
  ^{:line 303 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 303 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 303 :file "store/src/store/dev_compile_facts.bclj"} (vector? value) ^{:line 304 :file "store/src/store/dev_compile_facts.bclj"} (= 3 ^{:line 304 :file "store/src/store/dev_compile_facts.bclj"} (count value)) ^{:line 305 :file "store/src/store/dev_compile_facts.bclj"} (= expected-tag ^{:line 305 :file "store/src/store/dev_compile_facts.bclj"} (nth value 0))) value ^{:line 307 :file "store/src/store/dev_compile_facts.bclj"} (fail ^{:line 307 :file "store/src/store/dev_compile_facts.bclj"} (str "request must be " expected-tag " with three fields") :dev-compile-facts/invalid-request))))

^{:line 310 :file "store/src/store/dev_compile_facts.bclj"} (defn- query-requests-from [value]
  ^{:line 311 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 311 :file "store/src/store/dev_compile_facts.bclj"} (vector? value) ^{:line 312 :file "store/src/store/dev_compile_facts.bclj"} (mapv request-row value) ^{:line 313 :file "store/src/store/dev_compile_facts.bclj"} (fail "query requests must be a vector" :dev-compile-facts/invalid-query)))

^{:line 316 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^CompileFact entry-from-value [value]
  ^{:line 317 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 317 :file "store/src/store/dev_compile_facts.bclj"} (and ^{:line 317 :file "store/src/store/dev_compile_facts.bclj"} (vector? value) ^{:line 318 :file "store/src/store/dev_compile_facts.bclj"} (= 2 ^{:line 318 :file "store/src/store/dev_compile_facts.bclj"} (count value)) ^{:line 319 :file "store/src/store/dev_compile_facts.bclj"} (string? ^{:line 319 :file "store/src/store/dev_compile_facts.bclj"} (nth value 0)) ^{:line 320 :file "store/src/store/dev_compile_facts.bclj"} (string? ^{:line 320 :file "store/src/store/dev_compile_facts.bclj"} (nth value 1))) ^{:line 321 :file "store/src/store/dev_compile_facts.bclj"} (compile-fact ^{:line 321 :file "store/src/store/dev_compile_facts.bclj"} (nth value 0) ^{:line 321 :file "store/src/store/dev_compile_facts.bclj"} (nth value 1)) ^{:line 322 :file "store/src/store/dev_compile_facts.bclj"} (fail "append entry must be [id canonical-envelope-edn]" :dev-compile-facts/invalid-entry)))

^{:line 325 :file "store/src/store/dev_compile_facts.bclj"} (defn- entries-from-value [value]
  ^{:line 326 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 326 :file "store/src/store/dev_compile_facts.bclj"} (vector? value) ^{:line 327 :file "store/src/store/dev_compile_facts.bclj"} (mapv entry-from-value value) ^{:line 328 :file "store/src/store/dev_compile_facts.bclj"} (fail "append entries must be a vector" :dev-compile-facts/invalid-entry)))

^{:line 331 :file "store/src/store/dev_compile_facts.bclj"} (defn dispatch! [^String command]
  ^{:line 332 :file "store/src/store/dev_compile_facts.bclj"} (cond
  ^{:line 333 :file "store/src/store/dev_compile_facts.bclj"} (= command "query") ^{:line 334 :file "store/src/store/dev_compile_facts.bclj"} (let [request ^{:line 335 :file "store/src/store/dev_compile_facts.bclj"} (request-vector "store.dev-compile-facts/query-v1")]
  ^{:line 336 :file "store/src/store/dev_compile_facts.bclj"} (query! ^{:line 336 :file "store/src/store/dev_compile_facts.bclj"} (absolute-store-path ^{:line 336 :file "store/src/store/dev_compile_facts.bclj"} (nth request 1)) ^{:line 337 :file "store/src/store/dev_compile_facts.bclj"} (query-requests-from ^{:line 337 :file "store/src/store/dev_compile_facts.bclj"} (nth request 2))))
  ^{:line 338 :file "store/src/store/dev_compile_facts.bclj"} (= command "append") ^{:line 339 :file "store/src/store/dev_compile_facts.bclj"} (let [request ^{:line 340 :file "store/src/store/dev_compile_facts.bclj"} (request-vector "store.dev-compile-facts/append-v1")]
  ^{:line 341 :file "store/src/store/dev_compile_facts.bclj"} (append! ^{:line 341 :file "store/src/store/dev_compile_facts.bclj"} (absolute-store-path ^{:line 341 :file "store/src/store/dev_compile_facts.bclj"} (nth request 1)) ^{:line 342 :file "store/src/store/dev_compile_facts.bclj"} (entries-from-value ^{:line 342 :file "store/src/store/dev_compile_facts.bclj"} (nth request 2))))
  :else ^{:line 344 :file "store/src/store/dev_compile_facts.bclj"} (fail ^{:line 344 :file "store/src/store/dev_compile_facts.bclj"} (str "unknown development compile fact command: " command) :dev-compile-facts/unknown-command)))

^{:line 347 :file "store/src/store/dev_compile_facts.bclj"} (defn- ^String error-code [error]
  ^{:line 348 :file "store/src/store/dev_compile_facts.bclj"} (let [data ^{:line 348 :file "store/src/store/dev_compile_facts.bclj"} (ex-data error)
   code ^{:line 349 :file "store/src/store/dev_compile_facts.bclj"} (or ^{:line 349 :file "store/src/store/dev_compile_facts.bclj"} (:fram/code data) ^{:line 349 :file "store/src/store/dev_compile_facts.bclj"} (:type data))]
  ^{:line 350 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 350 :file "store/src/store/dev_compile_facts.bclj"} (keyword? code) ^{:line 350 :file "store/src/store/dev_compile_facts.bclj"} (subs ^{:line 350 :file "store/src/store/dev_compile_facts.bclj"} (str code) 1) "unclassified")))

^{:line 352 :file "store/src/store/dev_compile_facts.bclj"} (defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  ^{:line 353 :file "store/src/store/dev_compile_facts.bclj"} (try
  ^{:line 354 :file "store/src/store/dev_compile_facts.bclj"} (if ^{:line 354 :file "store/src/store/dev_compile_facts.bclj"} (= 1 ^{:line 354 :file "store/src/store/dev_compile_facts.bclj"} (count args)) ^{:line 355 :file "store/src/store/dev_compile_facts.bclj"} (println ^{:line 355 :file "store/src/store/dev_compile_facts.bclj"} (pr-str ^{:line 355 :file "store/src/store/dev_compile_facts.bclj"} (dispatch! ^{:line 355 :file "store/src/store/dev_compile_facts.bclj"} (first args)))) ^{:line 356 :file "store/src/store/dev_compile_facts.bclj"} (fail "development compile facts expects one command argument" :dev-compile-facts/invalid-command-line))
  (catch Exception error
    ^{:line 359 :file "store/src/store/dev_compile_facts.bclj"} (println ^{:line 360 :file "store/src/store/dev_compile_facts.bclj"} (pr-str ^{:line 361 :file "store/src/store/dev_compile_facts.bclj"} ["store.dev-compile-facts/error-v1" ^{:line 362 :file "store/src/store/dev_compile_facts.bclj"} (error-code error) ^{:line 363 :file "store/src/store/dev_compile_facts.bclj"} (.getMessage error)]))
    ^{:line 364 :file "store/src/store/dev_compile_facts.bclj"} (System/exit 2)))))

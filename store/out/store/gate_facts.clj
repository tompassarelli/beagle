(ns store.gate-facts
  (:gen-class)
  (:import [java.io File]
           [java.nio.charset StandardCharsets]
           [java.security MessageDigest]))

^{:line 30 :file "store/src/store/gate_facts.bclj"} (clojure.core/require 'store.rt)

^{:line 31 :file "store/src/store/gate_facts.bclj"} (let [raw-emitted-file ^{:line 31 :file "store/src/store/gate_facts.bclj"} (File. ^{:line 31 :file "store/src/store/gate_facts.bclj"} (str *file*))
   emitted-file ^{:line 32 :file "store/src/store/gate_facts.bclj"} (.getCanonicalFile raw-emitted-file)
   emitted-namespace-directory ^{:line 33 :file "store/src/store/gate_facts.bclj"} (.getParentFile emitted-file)
   out-directory ^{:line 34 :file "store/src/store/gate_facts.bclj"} (.getParentFile emitted-namespace-directory)
   store-directory ^{:line 35 :file "store/src/store/gate_facts.bclj"} (.getParentFile out-directory)]
  ^{:line 36 :file "store/src/store/gate_facts.bclj"} (clojure.core/load-file ^{:line 37 :file "store/src/store/gate_facts.bclj"} (str ^{:line 37 :file "store/src/store/gate_facts.bclj"} (.getPath store-directory) "/database.clj")))

^{:line 39 :file "store/src/store/gate_facts.bclj"} (def ^String protocol-prefix "store.gate-facts")

^{:line 40 :file "store/src/store/gate_facts.bclj"} (def ^String space-prefix "beagle-gate-facts-experimental-v1:")

^{:line 41 :file "store/src/store/gate_facts.bclj"} (def ^String subject-tag "store.gate-facts/subject-v1")

^{:line 42 :file "store/src/store/gate_facts.bclj"} (def ^String fallback-link-kind "store.gate-facts/fallback-link-v1")

^{:line 44 :file "store/src/store/gate_facts.bclj"} (def allowed-kinds ^{:line 45 :file "store/src/store/gate_facts.bclj"} #{"GateCandidateV1" "GatePhaseClaimV1" "GatePhaseObservationV1" "GateCandidateVerdictV1" "FactMissEventV1" "GateMaintenanceReceiptV1"})

^{:line 52 :file "store/src/store/gate_facts.bclj"} (defrecord FactRoute [path base-commit candidate-root space-id])

(defn factroute-path [r] (:path r))

(defn factroute-base-commit [r] (:base-commit r))

(defn factroute-candidate-root [r] (:candidate-root r))

(defn factroute-space-id [r] (:space-id r))

^{:line 55 :file "store/src/store/gate_facts.bclj"} (defrecord FactEntry [id kind envelope])

(defn factentry-id [r] (:id r))

(defn factentry-kind [r] (:kind r))

(defn factentry-envelope [r] (:envelope r))

^{:line 57 :file "store/src/store/gate_facts.bclj"} (defrecord FallbackLink [miss-id observation-id])

(defn fallbacklink-miss-id [r] (:miss-id r))

(defn fallbacklink-observation-id [r] (:observation-id r))

^{:line 59 :file "store/src/store/gate_facts.bclj"} (defrecord AppendCounts [appended retained])

(defn appendcounts-appended [r] (:appended r))

(defn appendcounts-retained [r] (:retained r))

^{:line 61 :file "store/src/store/gate_facts.bclj"} (defn- fail [^String message code]
  ^{:line 62 :file "store/src/store/gate_facts.bclj"} (throw ^{:line 62 :file "store/src/store/gate_facts.bclj"} (ex-info message ^{:line 62 :file "store/src/store/gate_facts.bclj"} {:type code :fram/code code})))

^{:line 64 :file "store/src/store/gate_facts.bclj"} (defn- ^Boolean nonempty-string? [value]
  ^{:line 65 :file "store/src/store/gate_facts.bclj"} (and ^{:line 65 :file "store/src/store/gate_facts.bclj"} (string? value) ^{:line 65 :file "store/src/store/gate_facts.bclj"} (pos? ^{:line 65 :file "store/src/store/gate_facts.bclj"} (count value))))

^{:line 67 :file "store/src/store/gate_facts.bclj"} (defn- ^Boolean exact-base-commit? [value]
  ^{:line 68 :file "store/src/store/gate_facts.bclj"} (and ^{:line 68 :file "store/src/store/gate_facts.bclj"} (string? value) ^{:line 69 :file "store/src/store/gate_facts.bclj"} (some? ^{:line 69 :file "store/src/store/gate_facts.bclj"} (re-matches #"[0-9a-f]{40}" value))))

^{:line 71 :file "store/src/store/gate_facts.bclj"} (defn- ^String sha256-id [^String text]
  ^{:line 72 :file "store/src/store/gate_facts.bclj"} (str "sha256:" ^{:line 74 :file "store/src/store/gate_facts.bclj"} (apply str ^{:line 76 :file "store/src/store/gate_facts.bclj"} (mapv ^{:line 77 :file "store/src/store/gate_facts.bclj"} (fn [value] ^{:line 78 :file "store/src/store/gate_facts.bclj"} (format "%02x" ^{:line 78 :file "store/src/store/gate_facts.bclj"} (bit-and ^{:line 78 :file "store/src/store/gate_facts.bclj"} (int value) 255))) ^{:line 79 :file "store/src/store/gate_facts.bclj"} (vec ^{:line 80 :file "store/src/store/gate_facts.bclj"} (.digest ^{:line 80 :file "store/src/store/gate_facts.bclj"} (MessageDigest/getInstance "SHA-256") ^{:line 81 :file "store/src/store/gate_facts.bclj"} (.getBytes text StandardCharsets/UTF_8)))))))

^{:line 83 :file "store/src/store/gate_facts.bclj"} (defn ^FactRoute route [^String path ^String base-commit ^String candidate-root]
  ^{:line 85 :file "store/src/store/gate_facts.bclj"} (cond
  ^{:line 86 :file "store/src/store/gate_facts.bclj"} (nil? ^{:line 86 :file "store/src/store/gate_facts.bclj"} (re-matches #"/.*" path)) ^{:line 87 :file "store/src/store/gate_facts.bclj"} (fail "gate fact Store path must be absolute" :gate-facts/relative-route)
  ^{:line 88 :file "store/src/store/gate_facts.bclj"} (not ^{:line 88 :file "store/src/store/gate_facts.bclj"} (exact-base-commit? base-commit)) ^{:line 89 :file "store/src/store/gate_facts.bclj"} (fail "gate fact base commit must be one full lowercase Git object id" :gate-facts/invalid-base-commit)
  ^{:line 91 :file "store/src/store/gate_facts.bclj"} (not ^{:line 91 :file "store/src/store/gate_facts.bclj"} (nonempty-string? candidate-root)) ^{:line 92 :file "store/src/store/gate_facts.bclj"} (fail "gate fact candidate root must be nonempty" :gate-facts/invalid-candidate-root)
  ^{:line 94 :file "store/src/store/gate_facts.bclj"} (or ^{:line 94 :file "store/src/store/gate_facts.bclj"} (= candidate-root "main") ^{:line 94 :file "store/src/store/gate_facts.bclj"} (= candidate-root "refs/heads/main")) ^{:line 95 :file "store/src/store/gate_facts.bclj"} (fail "gate fact candidate root must be immutable, not a published route" :gate-facts/published-route-refused)
  :else ^{:line 98 :file "store/src/store/gate_facts.bclj"} (->FactRoute path base-commit candidate-root ^{:line 100 :file "store/src/store/gate_facts.bclj"} (str space-prefix base-commit))))

^{:line 102 :file "store/src/store/gate_facts.bclj"} (defn ^FactEntry fact-entry [^String id ^String kind ^String envelope]
  ^{:line 103 :file "store/src/store/gate_facts.bclj"} (let [payload ^{:line 103 :file "store/src/store/gate_facts.bclj"} (store.rt/parse-edn envelope)]
  ^{:line 104 :file "store/src/store/gate_facts.bclj"} (cond
  ^{:line 105 :file "store/src/store/gate_facts.bclj"} (not ^{:line 105 :file "store/src/store/gate_facts.bclj"} (nonempty-string? id)) ^{:line 106 :file "store/src/store/gate_facts.bclj"} (fail "gate fact id must be nonempty" :gate-facts/invalid-fact-id)
  ^{:line 107 :file "store/src/store/gate_facts.bclj"} (not ^{:line 107 :file "store/src/store/gate_facts.bclj"} (contains? allowed-kinds kind)) ^{:line 108 :file "store/src/store/gate_facts.bclj"} (fail ^{:line 108 :file "store/src/store/gate_facts.bclj"} (str "gate fact kind is unknown: " kind) :gate-facts/unknown-kind)
  ^{:line 110 :file "store/src/store/gate_facts.bclj"} (not ^{:line 110 :file "store/src/store/gate_facts.bclj"} (and ^{:line 110 :file "store/src/store/gate_facts.bclj"} (vector? payload) ^{:line 111 :file "store/src/store/gate_facts.bclj"} (pos? ^{:line 111 :file "store/src/store/gate_facts.bclj"} (count payload)) ^{:line 112 :file "store/src/store/gate_facts.bclj"} (= kind ^{:line 112 :file "store/src/store/gate_facts.bclj"} (first payload)) ^{:line 113 :file "store/src/store/gate_facts.bclj"} (= envelope ^{:line 113 :file "store/src/store/gate_facts.bclj"} (pr-str payload)))) ^{:line 114 :file "store/src/store/gate_facts.bclj"} (fail "gate fact envelope must be an EDN vector headed by its V1 kind" :gate-facts/invalid-envelope)
  ^{:line 116 :file "store/src/store/gate_facts.bclj"} (not= id ^{:line 116 :file "store/src/store/gate_facts.bclj"} (sha256-id envelope)) ^{:line 117 :file "store/src/store/gate_facts.bclj"} (fail "gate fact id does not match the canonical envelope bytes" :gate-facts/fact-id-mismatch)
  :else ^{:line 119 :file "store/src/store/gate_facts.bclj"} (->FactEntry id kind envelope))))

^{:line 121 :file "store/src/store/gate_facts.bclj"} (defn- fact-subject [^String candidate-root ^String fact-id]
  ^{:line 122 :file "store/src/store/gate_facts.bclj"} (store.types/triple subject-tag candidate-root fact-id))

^{:line 124 :file "store/src/store/gate_facts.bclj"} (defn- fact-proposition [^String candidate-root ^FactEntry entry]
  ^{:line 125 :file "store/src/store/gate_facts.bclj"} (store.types/triple ^{:line 125 :file "store/src/store/gate_facts.bclj"} (fact-subject candidate-root ^{:line 125 :file "store/src/store/gate_facts.bclj"} (factentry-id entry)) ^{:line 126 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry) ^{:line 127 :file "store/src/store/gate_facts.bclj"} (factentry-envelope entry)))

^{:line 129 :file "store/src/store/gate_facts.bclj"} (defn- fallback-proposition [^String candidate-root ^FallbackLink link]
  ^{:line 130 :file "store/src/store/gate_facts.bclj"} (store.types/triple ^{:line 131 :file "store/src/store/gate_facts.bclj"} (fact-subject candidate-root ^{:line 131 :file "store/src/store/gate_facts.bclj"} (fallbacklink-miss-id link)) fallback-link-kind ^{:line 133 :file "store/src/store/gate_facts.bclj"} (fallbacklink-observation-id link)))

^{:line 135 :file "store/src/store/gate_facts.bclj"} (defn- ^Boolean candidate-subject? [value ^String candidate-root]
  ^{:line 136 :file "store/src/store/gate_facts.bclj"} (and ^{:line 136 :file "store/src/store/gate_facts.bclj"} (store.types/triple? value) ^{:line 137 :file "store/src/store/gate_facts.bclj"} (= subject-tag ^{:line 137 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t1 value)) ^{:line 138 :file "store/src/store/gate_facts.bclj"} (= candidate-root ^{:line 138 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t2 value)) ^{:line 139 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 139 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t3 value))))

^{:line 141 :file "store/src/store/gate_facts.bclj"} (defn- proposition-entry [proposition ^String candidate-root]
  ^{:line 142 :file "store/src/store/gate_facts.bclj"} (let [subject ^{:line 142 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t1 proposition)
   kind ^{:line 143 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t2 proposition)
   envelope ^{:line 144 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t3 proposition)]
  ^{:line 145 :file "store/src/store/gate_facts.bclj"} (if ^{:line 145 :file "store/src/store/gate_facts.bclj"} (and ^{:line 145 :file "store/src/store/gate_facts.bclj"} (candidate-subject? subject candidate-root) ^{:line 146 :file "store/src/store/gate_facts.bclj"} (string? kind) ^{:line 147 :file "store/src/store/gate_facts.bclj"} (contains? allowed-kinds kind) ^{:line 148 :file "store/src/store/gate_facts.bclj"} (string? envelope)) ^{:line 149 :file "store/src/store/gate_facts.bclj"} (->FactEntry ^{:line 149 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t3 subject) kind envelope) nil)))

^{:line 152 :file "store/src/store/gate_facts.bclj"} (defn- proposition-link [proposition ^String candidate-root]
  ^{:line 154 :file "store/src/store/gate_facts.bclj"} (let [subject ^{:line 154 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t1 proposition)
   kind ^{:line 155 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t2 proposition)
   observation-id ^{:line 156 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t3 proposition)]
  ^{:line 157 :file "store/src/store/gate_facts.bclj"} (if ^{:line 157 :file "store/src/store/gate_facts.bclj"} (and ^{:line 157 :file "store/src/store/gate_facts.bclj"} (candidate-subject? subject candidate-root) ^{:line 158 :file "store/src/store/gate_facts.bclj"} (= fallback-link-kind kind) ^{:line 159 :file "store/src/store/gate_facts.bclj"} (string? observation-id)) ^{:line 160 :file "store/src/store/gate_facts.bclj"} (->FallbackLink ^{:line 160 :file "store/src/store/gate_facts.bclj"} (store.types/triple-t3 subject) observation-id) nil)))

^{:line 163 :file "store/src/store/gate_facts.bclj"} (defn- facts-for [database ^FactRoute selected]
  ^{:line 164 :file "store/src/store/gate_facts.bclj"} (reduce ^{:line 165 :file "store/src/store/gate_facts.bclj"} (fn [entries proposition] ^{:line 166 :file "store/src/store/gate_facts.bclj"} (let [entry ^{:line 167 :file "store/src/store/gate_facts.bclj"} (proposition-entry proposition ^{:line 168 :file "store/src/store/gate_facts.bclj"} (factroute-candidate-root selected))]
  ^{:line 169 :file "store/src/store/gate_facts.bclj"} (if ^{:line 169 :file "store/src/store/gate_facts.bclj"} (some? entry) ^{:line 169 :file "store/src/store/gate_facts.bclj"} (conj entries entry) entries))) ^{:line 170 :file "store/src/store/gate_facts.bclj"} [] ^{:line 171 :file "store/src/store/gate_facts.bclj"} (database/live-propositions database)))

^{:line 173 :file "store/src/store/gate_facts.bclj"} (defn- links-for [database ^FactRoute selected]
  ^{:line 174 :file "store/src/store/gate_facts.bclj"} (reduce ^{:line 175 :file "store/src/store/gate_facts.bclj"} (fn [links proposition] ^{:line 176 :file "store/src/store/gate_facts.bclj"} (let [link ^{:line 177 :file "store/src/store/gate_facts.bclj"} (proposition-link proposition ^{:line 178 :file "store/src/store/gate_facts.bclj"} (factroute-candidate-root selected))]
  ^{:line 179 :file "store/src/store/gate_facts.bclj"} (if ^{:line 179 :file "store/src/store/gate_facts.bclj"} (some? link) ^{:line 179 :file "store/src/store/gate_facts.bclj"} (conj links link) links))) ^{:line 180 :file "store/src/store/gate_facts.bclj"} [] ^{:line 181 :file "store/src/store/gate_facts.bclj"} (database/live-propositions database)))

^{:line 183 :file "store/src/store/gate_facts.bclj"} (defn- entry-with-id [entries ^String fact-id]
  ^{:line 184 :file "store/src/store/gate_facts.bclj"} (reduce ^{:line 185 :file "store/src/store/gate_facts.bclj"} (fn [found ^FactEntry entry] ^{:line 186 :file "store/src/store/gate_facts.bclj"} (if ^{:line 186 :file "store/src/store/gate_facts.bclj"} (= fact-id ^{:line 186 :file "store/src/store/gate_facts.bclj"} (factentry-id entry)) entry found)) nil entries))

^{:line 190 :file "store/src/store/gate_facts.bclj"} (defn- ^Boolean same-entry? [^FactEntry left ^FactEntry right]
  ^{:line 191 :file "store/src/store/gate_facts.bclj"} (and ^{:line 191 :file "store/src/store/gate_facts.bclj"} (= ^{:line 191 :file "store/src/store/gate_facts.bclj"} (factentry-id left) ^{:line 191 :file "store/src/store/gate_facts.bclj"} (factentry-id right)) ^{:line 192 :file "store/src/store/gate_facts.bclj"} (= ^{:line 192 :file "store/src/store/gate_facts.bclj"} (factentry-kind left) ^{:line 192 :file "store/src/store/gate_facts.bclj"} (factentry-kind right)) ^{:line 193 :file "store/src/store/gate_facts.bclj"} (= ^{:line 193 :file "store/src/store/gate_facts.bclj"} (factentry-envelope left) ^{:line 193 :file "store/src/store/gate_facts.bclj"} (factentry-envelope right))))

^{:line 195 :file "store/src/store/gate_facts.bclj"} (defn- link-with-miss-id [links ^String miss-id]
  ^{:line 197 :file "store/src/store/gate_facts.bclj"} (reduce ^{:line 198 :file "store/src/store/gate_facts.bclj"} (fn [found ^FallbackLink link] ^{:line 199 :file "store/src/store/gate_facts.bclj"} (if ^{:line 199 :file "store/src/store/gate_facts.bclj"} (= miss-id ^{:line 199 :file "store/src/store/gate_facts.bclj"} (fallbacklink-miss-id link)) link found)) nil links))

^{:line 203 :file "store/src/store/gate_facts.bclj"} (defn- ^FallbackLink required-link [link]
  ^{:line 204 :file "store/src/store/gate_facts.bclj"} (if ^{:line 204 :file "store/src/store/gate_facts.bclj"} (some? link) link ^{:line 206 :file "store/src/store/gate_facts.bclj"} (fail "fallback link is absent" :gate-facts/fallback-link-absent)))

^{:line 208 :file "store/src/store/gate_facts.bclj"} (defn- create-or-open! [^FactRoute selected]
  ^{:line 209 :file "store/src/store/gate_facts.bclj"} (let [path ^{:line 209 :file "store/src/store/gate_facts.bclj"} (factroute-path selected)
   file ^{:line 210 :file "store/src/store/gate_facts.bclj"} (File. path)]
  ^{:line 211 :file "store/src/store/gate_facts.bclj"} (if ^{:line 211 :file "store/src/store/gate_facts.bclj"} (.exists file) nil ^{:line 213 :file "store/src/store/gate_facts.bclj"} (database/create-triple-log! path ^{:line 213 :file "store/src/store/gate_facts.bclj"} (factroute-space-id selected)))
  ^{:line 214 :file "store/src/store/gate_facts.bclj"} (database/open-database! path ^{:line 214 :file "store/src/store/gate_facts.bclj"} (factroute-space-id selected))))

^{:line 216 :file "store/src/store/gate_facts.bclj"} (defn- with-writer! [^FactRoute selected operation]
  ^{:line 218 :file "store/src/store/gate_facts.bclj"} (let [authority ^{:line 219 :file "store/src/store/gate_facts.bclj"} (writer-authority/acquire! ^{:line 219 :file "store/src/store/gate_facts.bclj"} (factroute-path selected))]
  ^{:line 220 :file "store/src/store/gate_facts.bclj"} (try
  ^{:line 221 :file "store/src/store/gate_facts.bclj"} (operation ^{:line 221 :file "store/src/store/gate_facts.bclj"} (create-or-open! selected))
  (finally
    ^{:line 222 :file "store/src/store/gate_facts.bclj"} (writer-authority/release! authority)))))

^{:line 224 :file "store/src/store/gate_facts.bclj"} (defn- cold-open! [^FactRoute selected]
  ^{:line 225 :file "store/src/store/gate_facts.bclj"} (let [path ^{:line 225 :file "store/src/store/gate_facts.bclj"} (factroute-path selected)
   file ^{:line 226 :file "store/src/store/gate_facts.bclj"} (File. path)]
  ^{:line 227 :file "store/src/store/gate_facts.bclj"} (if ^{:line 227 :file "store/src/store/gate_facts.bclj"} (.isFile file) ^{:line 228 :file "store/src/store/gate_facts.bclj"} (database/open-database! path ^{:line 228 :file "store/src/store/gate_facts.bclj"} (factroute-space-id selected)) ^{:line 229 :file "store/src/store/gate_facts.bclj"} (fail "gate fact Store route is unopened" :gate-facts/route-unresolved))))

^{:line 232 :file "store/src/store/gate_facts.bclj"} (defn- append-propositions! [database propositions]
  ^{:line 233 :file "store/src/store/gate_facts.bclj"} (if ^{:line 233 :file "store/src/store/gate_facts.bclj"} (empty? propositions) nil ^{:line 235 :file "store/src/store/gate_facts.bclj"} (do
  ^{:line 236 :file "store/src/store/gate_facts.bclj"} (database/commit! database ^{:line 238 :file "store/src/store/gate_facts.bclj"} {:actor "store.gate-facts/v1" :operations ^{:line 240 :file "store/src/store/gate_facts.bclj"} (mapv ^{:line 241 :file "store/src/store/gate_facts.bclj"} (fn [proposition] ^{:line 242 :file "store/src/store/gate_facts.bclj"} {:action :assert :proposition proposition}) propositions)})
  nil)))

^{:line 246 :file "store/src/store/gate_facts.bclj"} (defn- ^AppendCounts append-entries! [database ^FactRoute selected entries]
  ^{:line 248 :file "store/src/store/gate_facts.bclj"} (let [known ^{:line 248 :file "store/src/store/gate_facts.bclj"} (facts-for database selected)
   new-entries ^{:line 250 :file "store/src/store/gate_facts.bclj"} (reduce ^{:line 251 :file "store/src/store/gate_facts.bclj"} (fn [pending ^FactEntry entry] ^{:line 252 :file "store/src/store/gate_facts.bclj"} (let [prior ^{:line 253 :file "store/src/store/gate_facts.bclj"} (entry-with-id ^{:line 253 :file "store/src/store/gate_facts.bclj"} (vec ^{:line 253 :file "store/src/store/gate_facts.bclj"} (concat known pending)) ^{:line 254 :file "store/src/store/gate_facts.bclj"} (factentry-id entry))]
  ^{:line 255 :file "store/src/store/gate_facts.bclj"} (cond
  ^{:line 256 :file "store/src/store/gate_facts.bclj"} (nil? prior) ^{:line 256 :file "store/src/store/gate_facts.bclj"} (conj pending entry)
  ^{:line 257 :file "store/src/store/gate_facts.bclj"} (same-entry? prior entry) pending
  :else ^{:line 259 :file "store/src/store/gate_facts.bclj"} (fail ^{:line 259 :file "store/src/store/gate_facts.bclj"} (str "gate fact id has conflicting immutable content: " ^{:line 260 :file "store/src/store/gate_facts.bclj"} (factentry-id entry)) :gate-facts/conflicting-fact)))) ^{:line 262 :file "store/src/store/gate_facts.bclj"} [] entries)]
  ^{:line 264 :file "store/src/store/gate_facts.bclj"} (append-propositions! database ^{:line 266 :file "store/src/store/gate_facts.bclj"} (mapv ^{:line 267 :file "store/src/store/gate_facts.bclj"} (fn [^FactEntry entry] ^{:line 268 :file "store/src/store/gate_facts.bclj"} (fact-proposition ^{:line 268 :file "store/src/store/gate_facts.bclj"} (factroute-candidate-root selected) entry)) new-entries))
  ^{:line 270 :file "store/src/store/gate_facts.bclj"} (->AppendCounts ^{:line 270 :file "store/src/store/gate_facts.bclj"} (count new-entries) ^{:line 271 :file "store/src/store/gate_facts.bclj"} (- ^{:line 271 :file "store/src/store/gate_facts.bclj"} (count entries) ^{:line 271 :file "store/src/store/gate_facts.bclj"} (count new-entries)))))

^{:line 273 :file "store/src/store/gate_facts.bclj"} (defn- ^String revision-identity [^FactRoute selected]
  ^{:line 274 :file "store/src/store/gate_facts.bclj"} (let [revision ^{:line 275 :file "store/src/store/gate_facts.bclj"} (database/branch-revision! ^{:line 275 :file "store/src/store/gate_facts.bclj"} (factroute-path selected))
   identity ^{:line 276 :file "store/src/store/gate_facts.bclj"} (:identity revision)]
  ^{:line 277 :file "store/src/store/gate_facts.bclj"} (if ^{:line 277 :file "store/src/store/gate_facts.bclj"} (string? identity) identity ^{:line 279 :file "store/src/store/gate_facts.bclj"} (fail "Store returned no durable branch revision identity" :gate-facts/revision-unresolved))))

^{:line 282 :file "store/src/store/gate_facts.bclj"} (defn- response-for [database ^FactRoute selected]
  ^{:line 283 :file "store/src/store/gate_facts.bclj"} (let [entries ^{:line 283 :file "store/src/store/gate_facts.bclj"} (facts-for database selected)
   links ^{:line 284 :file "store/src/store/gate_facts.bclj"} (links-for database selected)
   receipts ^{:line 286 :file "store/src/store/gate_facts.bclj"} (filterv ^{:line 287 :file "store/src/store/gate_facts.bclj"} (fn [^FactEntry entry] ^{:line 288 :file "store/src/store/gate_facts.bclj"} (= "GateMaintenanceReceiptV1" ^{:line 288 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry))) entries)]
  ^{:line 290 :file "store/src/store/gate_facts.bclj"} ["store.gate-facts/response-v1" "ok" ^{:line 292 :file "store/src/store/gate_facts.bclj"} (factroute-candidate-root selected) ^{:line 293 :file "store/src/store/gate_facts.bclj"} (revision-identity selected) ^{:line 294 :file "store/src/store/gate_facts.bclj"} (mapv ^{:line 295 :file "store/src/store/gate_facts.bclj"} (fn [^FactEntry entry] ^{:line 296 :file "store/src/store/gate_facts.bclj"} [^{:line 296 :file "store/src/store/gate_facts.bclj"} (factentry-id entry) ^{:line 297 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry) ^{:line 298 :file "store/src/store/gate_facts.bclj"} (factentry-envelope entry)]) entries) ^{:line 300 :file "store/src/store/gate_facts.bclj"} (mapv ^{:line 301 :file "store/src/store/gate_facts.bclj"} (fn [^FallbackLink link] ^{:line 302 :file "store/src/store/gate_facts.bclj"} [^{:line 302 :file "store/src/store/gate_facts.bclj"} (fallbacklink-miss-id link) ^{:line 303 :file "store/src/store/gate_facts.bclj"} (fallbacklink-observation-id link)]) links) ^{:line 305 :file "store/src/store/gate_facts.bclj"} (mapv factentry-id receipts)]))

^{:line 307 :file "store/src/store/gate_facts.bclj"} (defn import-facts! [^FactRoute selected entries]
  ^{:line 308 :file "store/src/store/gate_facts.bclj"} (with-writer! selected ^{:line 310 :file "store/src/store/gate_facts.bclj"} (fn [database] ^{:line 311 :file "store/src/store/gate_facts.bclj"} (let [counts ^{:line 312 :file "store/src/store/gate_facts.bclj"} (append-entries! database selected entries)]
  ^{:line 313 :file "store/src/store/gate_facts.bclj"} (response-for database selected)))))

^{:line 315 :file "store/src/store/gate_facts.bclj"} (defn record-miss! [^FactRoute selected ^FactEntry entry]
  ^{:line 316 :file "store/src/store/gate_facts.bclj"} (if ^{:line 316 :file "store/src/store/gate_facts.bclj"} (not= "FactMissEventV1" ^{:line 316 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry)) ^{:line 317 :file "store/src/store/gate_facts.bclj"} (fail "record-miss accepts only FactMissEventV1" :gate-facts/not-a-miss) ^{:line 319 :file "store/src/store/gate_facts.bclj"} (with-writer! selected ^{:line 321 :file "store/src/store/gate_facts.bclj"} (fn [database] ^{:line 322 :file "store/src/store/gate_facts.bclj"} (let [counts ^{:line 323 :file "store/src/store/gate_facts.bclj"} (append-entries! database selected ^{:line 323 :file "store/src/store/gate_facts.bclj"} [entry])]
  ^{:line 324 :file "store/src/store/gate_facts.bclj"} (response-for database selected))))))

^{:line 326 :file "store/src/store/gate_facts.bclj"} (defn record-observation! [^FactRoute selected ^FactEntry entry miss-id]
  ^{:line 328 :file "store/src/store/gate_facts.bclj"} (if ^{:line 328 :file "store/src/store/gate_facts.bclj"} (not= "GatePhaseObservationV1" ^{:line 328 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry)) ^{:line 329 :file "store/src/store/gate_facts.bclj"} (fail "record-observation accepts only GatePhaseObservationV1" :gate-facts/not-an-observation) ^{:line 331 :file "store/src/store/gate_facts.bclj"} (with-writer! selected ^{:line 333 :file "store/src/store/gate_facts.bclj"} (fn [database] ^{:line 334 :file "store/src/store/gate_facts.bclj"} (let [known ^{:line 334 :file "store/src/store/gate_facts.bclj"} (facts-for database selected)
   known-links ^{:line 335 :file "store/src/store/gate_facts.bclj"} (links-for database selected)
   prior-entry ^{:line 337 :file "store/src/store/gate_facts.bclj"} (entry-with-id known ^{:line 337 :file "store/src/store/gate_facts.bclj"} (factentry-id entry))
   prior-miss ^{:line 339 :file "store/src/store/gate_facts.bclj"} (if ^{:line 339 :file "store/src/store/gate_facts.bclj"} (some? miss-id) ^{:line 339 :file "store/src/store/gate_facts.bclj"} (entry-with-id known miss-id) nil)
   prior-link ^{:line 341 :file "store/src/store/gate_facts.bclj"} (if ^{:line 341 :file "store/src/store/gate_facts.bclj"} (some? miss-id) ^{:line 342 :file "store/src/store/gate_facts.bclj"} (link-with-miss-id known-links miss-id) nil)
   link ^{:line 345 :file "store/src/store/gate_facts.bclj"} (if ^{:line 345 :file "store/src/store/gate_facts.bclj"} (some? miss-id) ^{:line 346 :file "store/src/store/gate_facts.bclj"} (->FallbackLink miss-id ^{:line 346 :file "store/src/store/gate_facts.bclj"} (factentry-id entry)) nil)]
  ^{:line 348 :file "store/src/store/gate_facts.bclj"} (if ^{:line 348 :file "store/src/store/gate_facts.bclj"} (and ^{:line 348 :file "store/src/store/gate_facts.bclj"} (some? prior-entry) ^{:line 348 :file "store/src/store/gate_facts.bclj"} (not ^{:line 348 :file "store/src/store/gate_facts.bclj"} (same-entry? prior-entry entry))) ^{:line 349 :file "store/src/store/gate_facts.bclj"} (fail "observation id has conflicting immutable content" :gate-facts/conflicting-fact) nil)
  ^{:line 352 :file "store/src/store/gate_facts.bclj"} (if ^{:line 352 :file "store/src/store/gate_facts.bclj"} (and ^{:line 352 :file "store/src/store/gate_facts.bclj"} (some? miss-id) ^{:line 353 :file "store/src/store/gate_facts.bclj"} (or ^{:line 353 :file "store/src/store/gate_facts.bclj"} (nil? prior-miss) ^{:line 354 :file "store/src/store/gate_facts.bclj"} (not= "FactMissEventV1" ^{:line 354 :file "store/src/store/gate_facts.bclj"} (factentry-kind prior-miss)))) ^{:line 355 :file "store/src/store/gate_facts.bclj"} (fail "fallback observation has no prior durable FactMissEventV1" :gate-facts/miss-not-durable) nil)
  ^{:line 358 :file "store/src/store/gate_facts.bclj"} (if ^{:line 358 :file "store/src/store/gate_facts.bclj"} (and ^{:line 358 :file "store/src/store/gate_facts.bclj"} (some? prior-link) ^{:line 359 :file "store/src/store/gate_facts.bclj"} (not= ^{:line 359 :file "store/src/store/gate_facts.bclj"} (factentry-id entry) ^{:line 360 :file "store/src/store/gate_facts.bclj"} (fallbacklink-observation-id prior-link))) ^{:line 361 :file "store/src/store/gate_facts.bclj"} (fail "FactMissEventV1 already links to another fallback observation" :gate-facts/conflicting-fallback-link) nil)
  ^{:line 365 :file "store/src/store/gate_facts.bclj"} (cond
  ^{:line 366 :file "store/src/store/gate_facts.bclj"} (nil? miss-id) ^{:line 367 :file "store/src/store/gate_facts.bclj"} (let [counts ^{:line 368 :file "store/src/store/gate_facts.bclj"} (append-entries! database selected ^{:line 368 :file "store/src/store/gate_facts.bclj"} [entry])]
  nil)
  ^{:line 370 :file "store/src/store/gate_facts.bclj"} (and ^{:line 370 :file "store/src/store/gate_facts.bclj"} (nil? prior-entry) ^{:line 370 :file "store/src/store/gate_facts.bclj"} (nil? prior-link)) ^{:line 371 :file "store/src/store/gate_facts.bclj"} (append-propositions! database ^{:line 373 :file "store/src/store/gate_facts.bclj"} [^{:line 373 :file "store/src/store/gate_facts.bclj"} (fact-proposition ^{:line 373 :file "store/src/store/gate_facts.bclj"} (factroute-candidate-root selected) entry) ^{:line 374 :file "store/src/store/gate_facts.bclj"} (fallback-proposition ^{:line 374 :file "store/src/store/gate_facts.bclj"} (factroute-candidate-root selected) ^{:line 375 :file "store/src/store/gate_facts.bclj"} (required-link link))])
  ^{:line 376 :file "store/src/store/gate_facts.bclj"} (and ^{:line 376 :file "store/src/store/gate_facts.bclj"} (some? prior-entry) ^{:line 376 :file "store/src/store/gate_facts.bclj"} (some? prior-link)) nil
  :else ^{:line 378 :file "store/src/store/gate_facts.bclj"} (fail "observation and fallback link are not one durable result" :gate-facts/partial-fallback-result))
  ^{:line 380 :file "store/src/store/gate_facts.bclj"} (response-for database selected))))))

^{:line 382 :file "store/src/store/gate_facts.bclj"} (defn- ^FallbackLink requested-link [value]
  ^{:line 383 :file "store/src/store/gate_facts.bclj"} (if ^{:line 383 :file "store/src/store/gate_facts.bclj"} (and ^{:line 383 :file "store/src/store/gate_facts.bclj"} (vector? value) ^{:line 384 :file "store/src/store/gate_facts.bclj"} (= 2 ^{:line 384 :file "store/src/store/gate_facts.bclj"} (count value)) ^{:line 385 :file "store/src/store/gate_facts.bclj"} (nonempty-string? ^{:line 385 :file "store/src/store/gate_facts.bclj"} (nth value 0)) ^{:line 386 :file "store/src/store/gate_facts.bclj"} (nonempty-string? ^{:line 386 :file "store/src/store/gate_facts.bclj"} (nth value 1))) ^{:line 387 :file "store/src/store/gate_facts.bclj"} (->FallbackLink ^{:line 387 :file "store/src/store/gate_facts.bclj"} (nth value 0) ^{:line 387 :file "store/src/store/gate_facts.bclj"} (nth value 1)) ^{:line 388 :file "store/src/store/gate_facts.bclj"} (fail "finalize miss link must be [miss-id observation-id]" :gate-facts/invalid-fallback-link)))

^{:line 391 :file "store/src/store/gate_facts.bclj"} (defn- ^Boolean exact-link-present? [links ^FallbackLink wanted]
  ^{:line 393 :file "store/src/store/gate_facts.bclj"} (some? ^{:line 394 :file "store/src/store/gate_facts.bclj"} (some ^{:line 395 :file "store/src/store/gate_facts.bclj"} (fn [^FallbackLink link] ^{:line 396 :file "store/src/store/gate_facts.bclj"} (and ^{:line 396 :file "store/src/store/gate_facts.bclj"} (= ^{:line 396 :file "store/src/store/gate_facts.bclj"} (fallbacklink-miss-id wanted) ^{:line 397 :file "store/src/store/gate_facts.bclj"} (fallbacklink-miss-id link)) ^{:line 398 :file "store/src/store/gate_facts.bclj"} (= ^{:line 398 :file "store/src/store/gate_facts.bclj"} (fallbacklink-observation-id wanted) ^{:line 399 :file "store/src/store/gate_facts.bclj"} (fallbacklink-observation-id link)))) links)))

^{:line 402 :file "store/src/store/gate_facts.bclj"} (defn finalize! [^FactRoute selected ^FactEntry verdict ^FactEntry receipt requested-links]
  ^{:line 408 :file "store/src/store/gate_facts.bclj"} (if ^{:line 408 :file "store/src/store/gate_facts.bclj"} (not= "GateCandidateVerdictV1" ^{:line 408 :file "store/src/store/gate_facts.bclj"} (factentry-kind verdict)) ^{:line 409 :file "store/src/store/gate_facts.bclj"} (fail "finalize verdict must be GateCandidateVerdictV1" :gate-facts/not-a-verdict) nil)
  ^{:line 412 :file "store/src/store/gate_facts.bclj"} (if ^{:line 412 :file "store/src/store/gate_facts.bclj"} (not= "GateMaintenanceReceiptV1" ^{:line 412 :file "store/src/store/gate_facts.bclj"} (factentry-kind receipt)) ^{:line 413 :file "store/src/store/gate_facts.bclj"} (fail "finalize receipt must be GateMaintenanceReceiptV1" :gate-facts/not-a-receipt) nil)
  ^{:line 416 :file "store/src/store/gate_facts.bclj"} (with-writer! selected ^{:line 418 :file "store/src/store/gate_facts.bclj"} (fn [database] ^{:line 419 :file "store/src/store/gate_facts.bclj"} (let [known ^{:line 419 :file "store/src/store/gate_facts.bclj"} (facts-for database selected)
   durable-links ^{:line 420 :file "store/src/store/gate_facts.bclj"} (links-for database selected)
   candidate-present ^{:line 422 :file "store/src/store/gate_facts.bclj"} (some? ^{:line 423 :file "store/src/store/gate_facts.bclj"} (some ^{:line 424 :file "store/src/store/gate_facts.bclj"} (fn [^FactEntry entry] ^{:line 425 :file "store/src/store/gate_facts.bclj"} (= "GateCandidateV1" ^{:line 425 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry))) known))
   misses ^{:line 428 :file "store/src/store/gate_facts.bclj"} (filterv ^{:line 429 :file "store/src/store/gate_facts.bclj"} (fn [^FactEntry entry] ^{:line 430 :file "store/src/store/gate_facts.bclj"} (= "FactMissEventV1" ^{:line 430 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry))) known)]
  ^{:line 432 :file "store/src/store/gate_facts.bclj"} (if candidate-present nil ^{:line 434 :file "store/src/store/gate_facts.bclj"} (fail "finalize requires a durable exact candidate" :gate-facts/candidate-root-unresolved))
  ^{:line 436 :file "store/src/store/gate_facts.bclj"} (if ^{:line 436 :file "store/src/store/gate_facts.bclj"} (not= ^{:line 436 :file "store/src/store/gate_facts.bclj"} (count misses) ^{:line 436 :file "store/src/store/gate_facts.bclj"} (count requested-links)) ^{:line 437 :file "store/src/store/gate_facts.bclj"} (fail "maintenance receipt does not account for every durable miss" :gate-facts/unaccounted-miss) nil)
  ^{:line 440 :file "store/src/store/gate_facts.bclj"} (doseq [miss misses]
  ^{:line 441 :file "store/src/store/gate_facts.bclj"} (if ^{:line 441 :file "store/src/store/gate_facts.bclj"} (nil? ^{:line 441 :file "store/src/store/gate_facts.bclj"} (link-with-miss-id requested-links ^{:line 441 :file "store/src/store/gate_facts.bclj"} (factentry-id miss))) ^{:line 442 :file "store/src/store/gate_facts.bclj"} (fail "maintenance receipt omits a durable FactMissEventV1" :gate-facts/unaccounted-miss) nil))
  ^{:line 445 :file "store/src/store/gate_facts.bclj"} (doseq [link requested-links]
  ^{:line 446 :file "store/src/store/gate_facts.bclj"} (let [miss ^{:line 447 :file "store/src/store/gate_facts.bclj"} (entry-with-id known ^{:line 447 :file "store/src/store/gate_facts.bclj"} (fallbacklink-miss-id link))
   observation ^{:line 449 :file "store/src/store/gate_facts.bclj"} (entry-with-id known ^{:line 449 :file "store/src/store/gate_facts.bclj"} (fallbacklink-observation-id link))]
  ^{:line 450 :file "store/src/store/gate_facts.bclj"} (if ^{:line 450 :file "store/src/store/gate_facts.bclj"} (or ^{:line 450 :file "store/src/store/gate_facts.bclj"} (nil? miss) ^{:line 451 :file "store/src/store/gate_facts.bclj"} (not= "FactMissEventV1" ^{:line 451 :file "store/src/store/gate_facts.bclj"} (factentry-kind miss)) ^{:line 452 :file "store/src/store/gate_facts.bclj"} (nil? observation) ^{:line 453 :file "store/src/store/gate_facts.bclj"} (not= "GatePhaseObservationV1" ^{:line 454 :file "store/src/store/gate_facts.bclj"} (factentry-kind observation)) ^{:line 455 :file "store/src/store/gate_facts.bclj"} (not ^{:line 455 :file "store/src/store/gate_facts.bclj"} (exact-link-present? durable-links link))) ^{:line 456 :file "store/src/store/gate_facts.bclj"} (fail "maintenance receipt names an unproved miss fallback link" :gate-facts/unproved-fallback-link) nil)))
  ^{:line 459 :file "store/src/store/gate_facts.bclj"} (let [counts ^{:line 460 :file "store/src/store/gate_facts.bclj"} (append-entries! database selected ^{:line 460 :file "store/src/store/gate_facts.bclj"} [verdict receipt])]
  ^{:line 461 :file "store/src/store/gate_facts.bclj"} (response-for database selected))))))

^{:line 463 :file "store/src/store/gate_facts.bclj"} (defn cold-query! [^FactRoute selected expected-ids]
  ^{:line 464 :file "store/src/store/gate_facts.bclj"} (let [database ^{:line 464 :file "store/src/store/gate_facts.bclj"} (cold-open! selected)
   entries ^{:line 465 :file "store/src/store/gate_facts.bclj"} (facts-for database selected)
   candidate-present ^{:line 467 :file "store/src/store/gate_facts.bclj"} (some? ^{:line 468 :file "store/src/store/gate_facts.bclj"} (some ^{:line 469 :file "store/src/store/gate_facts.bclj"} (fn [^FactEntry entry] ^{:line 470 :file "store/src/store/gate_facts.bclj"} (= "GateCandidateV1" ^{:line 470 :file "store/src/store/gate_facts.bclj"} (factentry-kind entry))) entries))]
  ^{:line 472 :file "store/src/store/gate_facts.bclj"} (if candidate-present ^{:line 473 :file "store/src/store/gate_facts.bclj"} (response-for database selected) ^{:line 474 :file "store/src/store/gate_facts.bclj"} (fail "exact candidate root was not admitted in the opened Store" :gate-facts/candidate-root-unresolved))))

^{:line 477 :file "store/src/store/gate_facts.bclj"} (defn- request-vector [^String expected-tag expected-count]
  ^{:line 478 :file "store/src/store/gate_facts.bclj"} (let [line ^{:line 478 :file "store/src/store/gate_facts.bclj"} (read-line)
   value ^{:line 480 :file "store/src/store/gate_facts.bclj"} (if ^{:line 480 :file "store/src/store/gate_facts.bclj"} (string? line) ^{:line 480 :file "store/src/store/gate_facts.bclj"} (store.rt/parse-edn line) nil)]
  ^{:line 481 :file "store/src/store/gate_facts.bclj"} (if ^{:line 481 :file "store/src/store/gate_facts.bclj"} (and ^{:line 481 :file "store/src/store/gate_facts.bclj"} (vector? value) ^{:line 482 :file "store/src/store/gate_facts.bclj"} (= expected-count ^{:line 482 :file "store/src/store/gate_facts.bclj"} (count value)) ^{:line 483 :file "store/src/store/gate_facts.bclj"} (= expected-tag ^{:line 483 :file "store/src/store/gate_facts.bclj"} (nth value 0))) value ^{:line 485 :file "store/src/store/gate_facts.bclj"} (fail ^{:line 485 :file "store/src/store/gate_facts.bclj"} (str "request must be " expected-tag " with " expected-count " vector fields") :gate-facts/invalid-request))))

^{:line 489 :file "store/src/store/gate_facts.bclj"} (defn- ^FactRoute route-from-request [request]
  ^{:line 490 :file "store/src/store/gate_facts.bclj"} (if ^{:line 490 :file "store/src/store/gate_facts.bclj"} (and ^{:line 490 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 490 :file "store/src/store/gate_facts.bclj"} (nth request 1)) ^{:line 491 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 491 :file "store/src/store/gate_facts.bclj"} (nth request 2)) ^{:line 492 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 492 :file "store/src/store/gate_facts.bclj"} (nth request 3))) ^{:line 493 :file "store/src/store/gate_facts.bclj"} (route ^{:line 493 :file "store/src/store/gate_facts.bclj"} (nth request 1) ^{:line 493 :file "store/src/store/gate_facts.bclj"} (nth request 2) ^{:line 493 :file "store/src/store/gate_facts.bclj"} (nth request 3)) ^{:line 494 :file "store/src/store/gate_facts.bclj"} (fail "request route fields must be strings" :gate-facts/invalid-request)))

^{:line 497 :file "store/src/store/gate_facts.bclj"} (defn- ^FactEntry entry-from-value [value]
  ^{:line 498 :file "store/src/store/gate_facts.bclj"} (if ^{:line 498 :file "store/src/store/gate_facts.bclj"} (and ^{:line 498 :file "store/src/store/gate_facts.bclj"} (vector? value) ^{:line 499 :file "store/src/store/gate_facts.bclj"} (= 3 ^{:line 499 :file "store/src/store/gate_facts.bclj"} (count value)) ^{:line 500 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 500 :file "store/src/store/gate_facts.bclj"} (nth value 0)) ^{:line 501 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 501 :file "store/src/store/gate_facts.bclj"} (nth value 1)) ^{:line 502 :file "store/src/store/gate_facts.bclj"} (string? ^{:line 502 :file "store/src/store/gate_facts.bclj"} (nth value 2))) ^{:line 503 :file "store/src/store/gate_facts.bclj"} (fact-entry ^{:line 503 :file "store/src/store/gate_facts.bclj"} (nth value 0) ^{:line 503 :file "store/src/store/gate_facts.bclj"} (nth value 1) ^{:line 503 :file "store/src/store/gate_facts.bclj"} (nth value 2)) ^{:line 504 :file "store/src/store/gate_facts.bclj"} (fail "fact entry must be [id kind canonical-envelope-edn]" :gate-facts/invalid-entry)))

^{:line 507 :file "store/src/store/gate_facts.bclj"} (defn- entries-from-value [value]
  ^{:line 508 :file "store/src/store/gate_facts.bclj"} (if ^{:line 508 :file "store/src/store/gate_facts.bclj"} (vector? value) ^{:line 509 :file "store/src/store/gate_facts.bclj"} (mapv entry-from-value value) ^{:line 510 :file "store/src/store/gate_facts.bclj"} (fail "fact entries must be a vector" :gate-facts/invalid-entry)))

^{:line 512 :file "store/src/store/gate_facts.bclj"} (defn- strings-from-value [value]
  ^{:line 513 :file "store/src/store/gate_facts.bclj"} (if ^{:line 513 :file "store/src/store/gate_facts.bclj"} (and ^{:line 513 :file "store/src/store/gate_facts.bclj"} (vector? value) ^{:line 514 :file "store/src/store/gate_facts.bclj"} (every? string? value)) value ^{:line 516 :file "store/src/store/gate_facts.bclj"} (fail "expected fact ids must be a vector of strings" :gate-facts/invalid-request)))

^{:line 519 :file "store/src/store/gate_facts.bclj"} (defn dispatch! [^String command]
  ^{:line 520 :file "store/src/store/gate_facts.bclj"} (cond
  ^{:line 521 :file "store/src/store/gate_facts.bclj"} (= command "import") ^{:line 522 :file "store/src/store/gate_facts.bclj"} (let [request ^{:line 523 :file "store/src/store/gate_facts.bclj"} (request-vector "store.gate-facts/import-v1" 5)]
  ^{:line 524 :file "store/src/store/gate_facts.bclj"} (import-facts! ^{:line 524 :file "store/src/store/gate_facts.bclj"} (route-from-request request) ^{:line 525 :file "store/src/store/gate_facts.bclj"} (entries-from-value ^{:line 525 :file "store/src/store/gate_facts.bclj"} (nth request 4))))
  ^{:line 526 :file "store/src/store/gate_facts.bclj"} (= command "record-miss") ^{:line 527 :file "store/src/store/gate_facts.bclj"} (let [request ^{:line 528 :file "store/src/store/gate_facts.bclj"} (request-vector "store.gate-facts/record-miss-v1" 5)]
  ^{:line 529 :file "store/src/store/gate_facts.bclj"} (record-miss! ^{:line 529 :file "store/src/store/gate_facts.bclj"} (route-from-request request) ^{:line 530 :file "store/src/store/gate_facts.bclj"} (entry-from-value ^{:line 530 :file "store/src/store/gate_facts.bclj"} (nth request 4))))
  ^{:line 531 :file "store/src/store/gate_facts.bclj"} (= command "record-observation") ^{:line 532 :file "store/src/store/gate_facts.bclj"} (let [request ^{:line 533 :file "store/src/store/gate_facts.bclj"} (request-vector "store.gate-facts/record-observation-v1" 6)
   miss-id ^{:line 534 :file "store/src/store/gate_facts.bclj"} (nth request 5)]
  ^{:line 535 :file "store/src/store/gate_facts.bclj"} (if ^{:line 535 :file "store/src/store/gate_facts.bclj"} (or ^{:line 535 :file "store/src/store/gate_facts.bclj"} (nil? miss-id) ^{:line 535 :file "store/src/store/gate_facts.bclj"} (string? miss-id)) ^{:line 536 :file "store/src/store/gate_facts.bclj"} (record-observation! ^{:line 536 :file "store/src/store/gate_facts.bclj"} (route-from-request request) ^{:line 537 :file "store/src/store/gate_facts.bclj"} (entry-from-value ^{:line 537 :file "store/src/store/gate_facts.bclj"} (nth request 4)) miss-id) ^{:line 539 :file "store/src/store/gate_facts.bclj"} (fail "record-observation miss id must be a string or nil" :gate-facts/invalid-request)))
  ^{:line 541 :file "store/src/store/gate_facts.bclj"} (= command "finalize") ^{:line 542 :file "store/src/store/gate_facts.bclj"} (let [request ^{:line 543 :file "store/src/store/gate_facts.bclj"} (request-vector "store.gate-facts/finalize-v1" 7)
   links ^{:line 544 :file "store/src/store/gate_facts.bclj"} (nth request 6)]
  ^{:line 545 :file "store/src/store/gate_facts.bclj"} (if ^{:line 545 :file "store/src/store/gate_facts.bclj"} (vector? links) ^{:line 546 :file "store/src/store/gate_facts.bclj"} (finalize! ^{:line 546 :file "store/src/store/gate_facts.bclj"} (route-from-request request) ^{:line 547 :file "store/src/store/gate_facts.bclj"} (entry-from-value ^{:line 547 :file "store/src/store/gate_facts.bclj"} (nth request 4)) ^{:line 548 :file "store/src/store/gate_facts.bclj"} (entry-from-value ^{:line 548 :file "store/src/store/gate_facts.bclj"} (nth request 5)) ^{:line 549 :file "store/src/store/gate_facts.bclj"} (mapv requested-link links)) ^{:line 550 :file "store/src/store/gate_facts.bclj"} (fail "finalize links must be a vector" :gate-facts/invalid-request)))
  ^{:line 552 :file "store/src/store/gate_facts.bclj"} (= command "cold-query") ^{:line 553 :file "store/src/store/gate_facts.bclj"} (let [request ^{:line 554 :file "store/src/store/gate_facts.bclj"} (request-vector "store.gate-facts/cold-query-v1" 5)]
  ^{:line 555 :file "store/src/store/gate_facts.bclj"} (cold-query! ^{:line 555 :file "store/src/store/gate_facts.bclj"} (route-from-request request) ^{:line 556 :file "store/src/store/gate_facts.bclj"} (strings-from-value ^{:line 556 :file "store/src/store/gate_facts.bclj"} (nth request 4))))
  :else ^{:line 558 :file "store/src/store/gate_facts.bclj"} (fail ^{:line 558 :file "store/src/store/gate_facts.bclj"} (str "unknown gate fact command: " command) :gate-facts/unknown-command)))

^{:line 561 :file "store/src/store/gate_facts.bclj"} (defn- ^String error-code [error]
  ^{:line 562 :file "store/src/store/gate_facts.bclj"} (let [data ^{:line 562 :file "store/src/store/gate_facts.bclj"} (ex-data error)
   code ^{:line 563 :file "store/src/store/gate_facts.bclj"} (or ^{:line 563 :file "store/src/store/gate_facts.bclj"} (:fram/code data) ^{:line 563 :file "store/src/store/gate_facts.bclj"} (:type data))]
  ^{:line 564 :file "store/src/store/gate_facts.bclj"} (if ^{:line 564 :file "store/src/store/gate_facts.bclj"} (keyword? code) ^{:line 564 :file "store/src/store/gate_facts.bclj"} (subs ^{:line 564 :file "store/src/store/gate_facts.bclj"} (str code) 1) "unclassified")))

^{:line 566 :file "store/src/store/gate_facts.bclj"} (defn -main [& $beagle$rest$host]
  (let [args (vec $beagle$rest$host)]
  ^{:line 567 :file "store/src/store/gate_facts.bclj"} (try
  ^{:line 568 :file "store/src/store/gate_facts.bclj"} (if ^{:line 568 :file "store/src/store/gate_facts.bclj"} (= 1 ^{:line 568 :file "store/src/store/gate_facts.bclj"} (count args)) ^{:line 569 :file "store/src/store/gate_facts.bclj"} (println ^{:line 569 :file "store/src/store/gate_facts.bclj"} (pr-str ^{:line 569 :file "store/src/store/gate_facts.bclj"} (dispatch! ^{:line 569 :file "store/src/store/gate_facts.bclj"} (first args)))) ^{:line 570 :file "store/src/store/gate_facts.bclj"} (fail "gate facts expects exactly one command argument" :gate-facts/invalid-command-line))
  (catch Exception error
    ^{:line 573 :file "store/src/store/gate_facts.bclj"} (println ^{:line 574 :file "store/src/store/gate_facts.bclj"} (pr-str ^{:line 575 :file "store/src/store/gate_facts.bclj"} ["store.gate-facts/error-v1" ^{:line 576 :file "store/src/store/gate_facts.bclj"} (error-code error) ^{:line 577 :file "store/src/store/gate_facts.bclj"} (.getMessage error)]))
    ^{:line 578 :file "store/src/store/gate_facts.bclj"} (System/exit 2)))))

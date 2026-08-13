(ns selfhost.rt
  "Host-interop runtime for the self-hosted compiler's Beagle modules — the
  irreducible Clojure layer (file IO, JSON, process) the .bclj `declare-extern`s
  bind to. Runs on babashka. Beagle owns the compiler logic; this owns the host
  calls."
  (:require [cheshire.core :as cheshire]))

;; --- file / stream IO ---------------------------------------------------------

(defn slurp-file [path] (slurp path))

(defn- sha256-bytes [bytes]
  (let [digest (java.security.MessageDigest/getInstance "SHA-256")
        hashed (.digest digest bytes)]
    (str "sha256:"
         (apply str (map #(format "%02x" (bit-and 0xff %)) hashed)))))

;; Parse and hash one immutable byte snapshot. This avoids a second filesystem
;; read between parsing and sourceSha256 and rejects platform-default decoding.
(defn read-source-snapshot [path]
  (let [bytes (java.nio.file.Files/readAllBytes
                (.toPath (java.io.File. ^String path)))]
    {"text" (String. bytes java.nio.charset.StandardCharsets/UTF_8)
     "sourceSha256" (sha256-bytes bytes)}))

(defn read-stdin [] (slurp *in*))

;; Module resolution needs to probe the filesystem for sibling beagle sources
;; and canonicalize the entry path (resolve-module-path walks from the source
;; dir up the parent chain). The driver owns this IO; the parse stage stays pure.
(defn file-exists? [path] (.isFile (java.io.File. ^String path)))

(defn abs-path [path] (.getAbsolutePath (java.io.File. ^String path)))

(defn source-id [path]
  (let [source (.getCanonicalFile (java.io.File. ^String path))]
    (loop [dir (.getParentFile source)]
      (cond
        (nil? dir) (.getPath source)
        (.exists (java.io.File. dir ".git"))
        (.toString (.relativize (.toPath dir) (.toPath source)))
        :else (recur (.getParentFile dir))))))

(defn getenv [name] (System/getenv name))


;; --- JSON (string keys preserved — AST/datum values are string-keyed) ----------

(defn to-json [x] (cheshire/generate-string x))

(defn parse-json [s] (cheshire/parse-string s false))

;; Canonical checked-program JSON sorts every object by its string key before
;; encoding. The projection digest excludes only projectionSha256, exactly like
;; beagle-lib/private/ast-json.rkt.
(defn- canonical-json-value [value]
  (cond
    (map? value)
    (into (sorted-map)
          (map (fn [[key child]] [(str key) (canonical-json-value child)]))
          value)

    (vector? value) (mapv canonical-json-value value)
    (sequential? value) (mapv canonical-json-value value)
    :else value))

(defn canonical-json [value]
  (cheshire/generate-string (canonical-json-value value)))

(defn- sha256-utf8 [text]
  (sha256-bytes (.getBytes ^String text java.nio.charset.StandardCharsets/UTF_8)))

(defn source-sha256 [source-text] (sha256-utf8 source-text))

(defn projection-sha256 [projection-without-digest]
  (sha256-utf8 (canonical-json projection-without-digest)))

(defn valid-sha256? [value]
  (and (string? value)
       (boolean (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn valid-projection-sha256? [projection]
  (and (map? projection)
       (valid-sha256? (get projection "projectionSha256"))
       (= (get projection "projectionSha256")
          (projection-sha256 (dissoc projection "projectionSha256")))))

;; --- process ------------------------------------------------------------------

(defn exit [code] (System/exit code))

(defn eprint [s] (binding [*out* *err*] (print s) (flush)) nil)

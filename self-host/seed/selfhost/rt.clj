(ns selfhost.rt
  "Host-interop runtime for the self-hosted compiler's Beagle modules — the
  irreducible Clojure layer (file IO, JSON, process) the .bclj `declare-extern`s
  bind to. Runs on babashka. Beagle owns the compiler logic; this owns the host
  calls."
  (:require [cheshire.core :as cheshire]))

;; --- file / stream IO ---------------------------------------------------------

(defn slurp-file [path] (slurp path))

(defn read-stdin [] (slurp *in*))

;; Module resolution needs to probe the filesystem for sibling beagle sources
;; and canonicalize the entry path (resolve-module-path walks from the source
;; dir up the parent chain). The driver owns this IO; the parse stage stays pure.
(defn file-exists? [path] (.isFile (java.io.File. ^String path)))

(defn abs-path [path] (.getAbsolutePath (java.io.File. ^String path)))

;; --- JSON (string keys preserved — AST/datum values are string-keyed) ----------

(defn to-json [x] (cheshire/generate-string x))

(defn parse-json [s] (cheshire/parse-string s false))

;; --- process ------------------------------------------------------------------

(defn exit [code] (System/exit code))

(defn eprint [s] (binding [*out* *err*] (print s) (flush)) nil)

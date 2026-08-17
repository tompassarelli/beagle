;; writer_authority.clj — cross-generation database writer authority.
;;
;; A systemd unit name or a generation-local launcher lock cannot fence two
;; overlapping deployments: blue and green necessarily have different process
;; identities and runtime directories.  This lock is instead named by the
;; canonical log itself and held for the active database's entire lifetime.
;; Standbys do not acquire it and therefore cannot mutate canonical state.
(ns writer-authority
  (:require [clojure.java.io :as io]
            [clojure.string :as str])
  (:import [java.nio.channels FileChannel]
           [java.nio.file Files StandardOpenOption]))

(def authority-format "fram-writer-authority/v1")

(defn server-role-from
  "Parse a server role. nil/empty preserves the existing active default."
  [raw]
  (case (str/lower-case (str/trim (or raw "")))
    ("" "active") :active
    "standby" :standby
    (throw
     (ex-info
      "FRAM_SERVER_ROLE must be active or standby"
      {:code :invalid-server-role :value raw}))))

(defn server-role-from-env []
  (server-role-from (System/getenv "FRAM_SERVER_ROLE")))

(defn authority-path
  "Stable, cross-generation lock path for one canonical log."
  [log]
  (str (.getCanonicalPath (io/file (str log))) ".writer-authority.lock"))

(defn- open-channel [path]
  (let [p (.toPath (io/file path))]
    (when (Files/isSymbolicLink p)
      (throw
       (ex-info
        "writer authority path must not be a symlink"
        {:code :unsafe-writer-authority-path :path path})))
    (FileChannel/open
     p
     (into-array
      java.nio.file.OpenOption
      [StandardOpenOption/CREATE StandardOpenOption/WRITE]))))

(defn try-acquire!
  "Try to acquire the lifetime writer lock for LOG. Returns a handle or nil.
   Closing/releasing the handle is the only way to relinquish authority."
  [log]
  (let [path (authority-path log)
        parent (.getParentFile (io/file path))]
    (when parent (.mkdirs parent))
    (let [^FileChannel channel (open-channel path)]
      (try
        (if-let [lock (.tryLock channel)]
          {:format authority-format
           :log (.getCanonicalPath (io/file (str log)))
           :path path
           :channel channel
           :lock lock}
          (do (.close channel) nil))
        (catch Throwable t
          (.close channel)
          ;; Babashka deliberately does not expose the JVM exception class as a
          ;; resolvable symbol, but both runtimes preserve its exact class name.
          (if (= "OverlappingFileLockException"
                 (.getSimpleName (class t)))
            nil
            (throw t)))))))

(defn acquire!
  "Acquire writer authority or fail closed without waiting."
  [log]
  (or (try-acquire! log)
      (throw
       (ex-info
        (str "another database generation holds writer authority for "
             (.getCanonicalPath (io/file (str log))))
        {:code :writer-authority-held
         :log (.getCanonicalPath (io/file (str log)))
         :path (authority-path log)}))))

(defn held? [handle]
  (boolean
   (and handle
        (:lock handle)
        (:channel handle)
        (.isOpen ^FileChannel (:channel handle)))))

(defn release!
  "Release HANDLE idempotently. Closing the channel is the kernel backstop."
  [handle]
  (when handle
    ;; Closing the channel is the portable release primitive (and is the only
    ;; FileLock lifecycle operation Babashka intentionally exposes).
    (when (and (:channel handle)
               (.isOpen ^FileChannel (:channel handle)))
      (.close ^FileChannel (:channel handle))))
  nil)

(defn status [role handle log]
  {:format authority-format
   :role role
   :write-authorized (and (= role :active) (held? handle))
   :log (.getCanonicalPath (io/file (str log)))
   :lock (authority-path log)})

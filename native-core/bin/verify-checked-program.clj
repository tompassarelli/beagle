(require '[cheshire.core :as json])

(load-file
  (.getCanonicalPath
    (clojure.java.io/file (.getParentFile (clojure.java.io/file *file*))
      "checked-program.clj")))
(require '[native.checked-program :as checked-program])

(doseq [path *command-line-args*]
  (checked-program/require-checked-program!
    (json/parse-string (slurp path)) path "Native checked-program ingress"))

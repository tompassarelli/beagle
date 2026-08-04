;; Existing slice drivers keep this path; the production projector owns the code.
(require (quote [clojure.java.io :as io]))

(def repo-root
  (-> (io/file *file*)
      .getParentFile
      .getParentFile
      .getParentFile
      .getParentFile))

(load-file
 (.getCanonicalPath
  (io/file repo-root "native-core/bin/source-facts.clj")))

;; Checkout-first server promotion: clean commit capture, checkout resolution,
;; dirty-tree rejection, and project-only restart scope.
;;
;; Run from the Fram root:
;;   bb -cp out tests/fram_promotion_test.clj
(require '[babashka.process :as p]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(def root (.getCanonicalPath (io/file (System/getProperty "user.dir"))))
(def tmp (.getCanonicalPath
          (.toFile (java.nio.file.Files/createTempDirectory
                    "fram-promotion-test"
                    (make-array java.nio.file.attribute.FileAttribute 0)))))
(def repo (str tmp "/checkout"))
(def foreign-cwd (str tmp "/foreign-cwd"))
(def trace (str tmp "/restart.trace"))
(def forbidden-trace (str tmp "/forbidden.trace"))
(def generation-marker (str tmp "/nixos-generation"))
(def checks (atom []))

(defn check! [label value]
  (let [ok (boolean value)]
    (swap! checks conj [label ok])
    (println (str "  [" (if ok "PASS" "FAIL") "] " label))
    ok))

(defn run
  [opts & argv]
  (apply p/shell (merge {:out :string :err :string :continue true} opts) argv))

(defn git [& argv]
  (apply run {} "git" "-C" repo argv))

(defn write-executable! [path content]
  (spit path content)
  (.setExecutable (io/file path) true false))

(try
  (.mkdirs (io/file repo "bin"))
  (.mkdirs (io/file foreign-cwd))
  (.mkdirs (io/file tmp "forbidden-bin"))
  (io/copy (io/file root "bin/fram-promote")
           (io/file repo "bin/fram-promote"))
  (.setExecutable (io/file repo "bin/fram-promote") true false)

  (write-executable!
   (str repo "/bin/fram-up")
   (str "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "{\n"
        "  printf 'checkout=%s\\n' \"${FRAM_PROMOTED_CHECKOUT:?}\"\n"
        "  printf 'revision=%s\\n' \"${FRAM_PROMOTED_REV:?}\"\n"
        "  printf 'cwd=%s\\n' \"$PWD\"\n"
        "  printf 'argv=%s\\n' \"$*\"\n"
        "} >> \"${FRAM_PROMOTE_TEST_TRACE:?}\"\n"))

  (doseq [command ["firn" "nixos-rebuild" "nh" "nix" "systemctl"]]
    (write-executable!
     (str tmp "/forbidden-bin/" command)
     (str "#!/usr/bin/env bash\n"
          "printf '%s\\n' " command " >> \"${FRAM_PROMOTE_FORBIDDEN_TRACE:?}\"\n"
          "exit 99\n")))

  (spit generation-marker "generation-unchanged\n")
  (run {} "git" "init" "-q" repo)
  (git "config" "user.name" "Fram Promotion Test")
  (git "config" "user.email" "fram-promotion-test@example.invalid")
  (git "add" "bin/fram-promote" "bin/fram-up")
  (git "commit" "-q" "-m" "promotion fixture")

  (let [revision (str/trim (:out (git "rev-parse" "HEAD")))
        base-env {"FRAM_PROMOTE_TEST_TRACE" trace
                  "FRAM_PROMOTE_FORBIDDEN_TRACE" forbidden-trace
                  "PATH" (str tmp "/forbidden-bin:" (System/getenv "PATH"))}
        promoted (run {:dir foreign-cwd :extra-env base-env}
                      (str repo "/bin/fram-promote"))
        lines (set (str/split-lines (slurp trace)))]
    (check! "clean promotion exits 0" (zero? (:exit promoted)))
    (check! "promotion reports exact commit and unchanged NixOS generation"
            (str/includes? (:out promoted)
                           (str "promoted " revision " from " repo
                                "; NixOS generation unchanged")))
    (check! "restart receives the exact clean HEAD"
            (contains? lines (str "revision=" revision)))
    (check! "restart resolves the checkout that owns fram-promote"
            (and (contains? lines (str "checkout=" repo))
                 (contains? lines (str "cwd=" repo))))
    (check! "promotion invokes only checkout fram-up --restart"
            (and (= 4 (count lines))
                 (contains? lines "argv=--restart")
                 (not (.exists (io/file forbidden-trace)))))
    (check! "NixOS generation marker is untouched"
            (= "generation-unchanged\n" (slurp generation-marker)))

    (spit trace "")
    (spit (str repo "/bin/fram-up") "\n# dirty tracked change\n" :append true)
    (let [dirty (run {:dir foreign-cwd :extra-env base-env}
                     (str repo "/bin/fram-promote"))]
      (check! "dirty tracked checkout is rejected before restart"
              (and (= 1 (:exit dirty))
                   (str/includes? (:err dirty) "refusing dirty checkout")
                   (str/blank? (slurp trace)))))

    (git "checkout" "-q" "--" "bin/fram-up")
    (spit (str repo "/untracked") "dirty\n")
    (let [dirty (run {:dir foreign-cwd :extra-env base-env}
                     (str repo "/bin/fram-promote"))]
      (check! "dirty untracked checkout is rejected before restart"
              (and (= 1 (:exit dirty))
                   (str/includes? (:err dirty) "refusing dirty checkout")
                   (str/blank? (slurp trace))))))
  (finally
    (p/shell {} "rm" "-rf" tmp)))

(let [failed (remove second @checks)]
  (println (str "\nfram promotion: " (- (count @checks) (count failed))
                "/" (count @checks) " passed"))
  (when (seq failed)
    (System/exit 1)))

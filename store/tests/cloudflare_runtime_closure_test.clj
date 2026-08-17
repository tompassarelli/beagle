;; The Nix package must carry every repo-root file the server load-files; the
;; container carries only the static native artifact.
(require '[clojure.string :as str])

(def server-source
  (->> (str/split-lines (slurp "server.clj"))
       (map #(str/replace % #";.*$" ""))
       (str/join "\n")))
(def native-docker-source (slurp "deploy/cloudflare/Dockerfile.native"))
(def native-image-builder-source (slurp "bin/beagle-store-cloudflare-native-image"))
(def compose-source (slurp "deploy/cloudflare/docker-compose.yml"))
(def image-build-source (slurp "deploy/cloudflare/build-native-image.sh"))
(def flake-source (slurp "flake.nix"))
(def package-smoke-source (slurp "tests/package_server_smoke.sh"))

(def direct-loads
  (map second
       (re-seq #"\(load-file\s+\"([^\"]+)\"\)" server-source)))
(def cwd-loads
  (map second
       (re-seq #"\(load-file\s+\(str\s+\(System/getProperty\s+\"user.dir\"\)\s+\"/([^\"]+)\"\)\)"
               server-source)))
(def load-assets (set (concat direct-loads cwd-loads)))
(def root-assets
  (conj (set (remove #(str/starts-with? % "out/") load-assets))
        "server.clj"))

(def checks (atom []))
(defn chk [label ok detail]
  (swap! checks conj [label ok detail]))

(chk "server load-file closure is recognized"
     (= #{"database.clj" "writer_authority.clj"} load-assets)
     load-assets)
(chk "Cloudflare image accepts only a matching static READY artifact"
     (and (str/includes? native-docker-source "FROM scratch")
          (str/includes? native-docker-source "BEAGLE_STORE_NATIVE_ARTIFACT_HASH")
          (str/includes? native-docker-source "beagle-store-native-build/v1")
          (str/includes? native-docker-source "COPY READY")
          (str/includes? native-image-builder-source "artifact directory name is not a content hash")
          (str/includes? native-image-builder-source "artifact READY receipt does not match")
          (str/includes? native-image-builder-source "dynamically linked")
          (not (str/includes? native-docker-source "native/build.sh"))
          (not (str/includes? native-docker-source "graalvm"))
          (not (str/includes? native-docker-source "clojure:")))
     nil)
(chk "compose consumes one built server image and never builds the server"
     (and (str/includes? compose-source "image: ${BEAGLE_STORE_SERVER_IMAGE:?")
          (= 1 (count (re-seq #"(?m)^\s+dockerfile:" compose-source)))
          (str/includes? compose-source "deploy/cloudflare/Dockerfile.shim")
          (str/includes? image-build-source "BEAGLE_STORE_NATIVE_STATIC=1")
          (str/includes? image-build-source "bin/beagle-store-cloudflare-native-image"))
     nil)
(chk "Nix package includes every root runtime asset"
     (every? #(str/includes? flake-source %) root-assets)
     root-assets)
(chk "installed-package smoke asserts every root runtime asset"
     (every? #(str/includes? package-smoke-source (str "$runtime/" %))
             root-assets)
     root-assets)

(let [failures (remove second @checks)]
  (doseq [[label ok detail] @checks]
    (println (if ok "  [PASS]" "  [FAIL]") label)
    (when-not ok (println "         " (pr-str detail))))
  (if (empty? failures)
    (println "\ncloudflare runtime closure:" (count @checks) "/" (count @checks) "PASS")
    (do
      (println "\ncloudflare runtime closure:" (count failures) "FAILED")
      (System/exit 1))))

;; Authoritative registry of live Beagle downstream consumers (gate C1).
;;
;; Each entry names ONLY stable seams: which repo, which target, and how that
;; consumer's OWN build script enumerates its Beagle sources (the enumerator
;; source + extraction kind + a shape marker). The volatile file roster is
;; NEVER hand-listed here — it is DERIVED at runtime by re-executing each
;; consumer's enumerator against its current working tree. If a consumer
;; changes its enumerator MECHANISM (array → manifest, glob root moves, find
;; excludes change) the recorded shape no longer matches and the drift guard
;; fails closed rather than silently deriving a wrong/empty set.
;;
;; enumerator kinds:
;;   glob          walk `root` for `ext`, apply skip rules (mirrors a compile
;;                 script's directory walk). `require-absent` trips drift if a
;;                 manifest appears where the seam assumes glob-only.
;;   bash-array    parse `NAME=( ... )` from `source`, map each element through
;;                 `template` ({} = element). Drift if the array is gone.
;;   bash-for-list parse `for VAR in ... ; do` from `source`, map via `template`.
;;                 Drift if the loop is gone.
;;   find-exclude  replicate a `find`-based sweep: collect `ext` under the repo,
;;                 drop the find `-not -path` dirs, the case-excluded relpath
;;                 prefixes, and the excluded basenames. Drift if the find line
;;                 marker is gone.
(
 (consumer
  (name "gjoa")
  (repo-env "GJOA_REPO")
  (repo-default "~/code/gjoa")
  (target "js")
  (enumerators
   ((enumerator
     (kind glob)
     (source "tools/chrome-bundle/compile.bjs")
     (root "src/gjoa/chrome/bjs")
     (ext ".bjs")
     (recursive #t)
     (skip-basenames ("macros.bjs"))
     (skip-suffixes (".test.bjs"))
     (skip-prefixes ("test/"))
     (shape-markers ("BJS-ROOT" "macros.bjs" ".test.bjs" "test/"))))))

 (consumer
  (name "wake")
  (repo-env "WAKE_REPO")
  (repo-default "~/code/wake")
  (target "js")
  (enumerators
   ((enumerator
     (kind bash-array)
     (source "web/bin/wake-compile")
     (array-name "modules")
     (template "web/compiler/{}.bjs")
     (shape-markers ("modules=("))))))

 (consumer
  (name "north")
  (repo-env "NORTH_REPO")
  (repo-default "~/code/north")
  (target "clj+js")
  (enumerators
   ((enumerator
     (kind bash-for-list)
     (source "build.sh")
     (loop-var "m")
     (template "src/north/{}.bclj")
     (shape-markers ("for m in")))
    (enumerator
     (kind glob)
     (source #f)
     (root "web-bjs/src")
     (ext ".bjs")
     (recursive #f)
     (skip-basenames ())
     (skip-suffixes ())
     (skip-prefixes ())
     (require-absent "web-bjs/build.sh")
     (shape-markers ())))))

 (consumer
  (name "fram")
  (repo-env "FRAM_REPO")
  (repo-default "~/code/fram")
  (target "clj")
  (enumerators
   ((enumerator
     (kind bash-for-list)
     (source "build.sh")
     (loop-var "m")
     (template "src/fram/{}.bclj")
     (shape-markers ("for m in"))))))

 (consumer
  (name "nixos-config")
  (repo-env "NIXOS_CONFIG_REPO")
  (repo-default "~/code/nixos-config")
  (target "nix")
  (enumerators
   ((enumerator
     (kind find-exclude)
     (source "scripts/firn-build")
     (ext ".bnix")
     (find-not-paths ("result" ".direnv"))
     (exclude-relpath-prefixes ("scripts/" "tests/" "docs/fixtures/"))
     (exclude-basenames ("enabled-tags.bnix"))
     (shape-markers ("-name '*.bnix' -not -path './result*'" "enabled-tags.bnix")))))))

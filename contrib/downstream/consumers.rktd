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
;;   find-exclude  replicate firn-build's `find`-based emit sweep for the
;;                 membership rule (collect `ext`, drop the find `-not -path`
;;                 dirs, the case-excluded relpath prefixes, and the excluded
;;                 basenames), THEN reconcile against firn-validate's broader
;;                 discovery with a FAIL-CLOSED accounting layer: every .bnix
;;                 firn-build excludes from its emit membership must be listed
;;                 in `classified-excludes` with a class. An unclassified
;;                 excluded .bnix (a future good source dropped under an
;;                 excluded prefix, or a new negative fixture) trips a pointed
;;                 drift instead of silently leaving membership. firn-validate
;;                 (excludes only tests/fixtures/) is the authority separating
;;                 intentionally-broken fixtures (class negative-fixture) from
;;                 real sources firn checks but does not emit as a module
;;                 (class resolver-input | doc-fixture).
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
     ;; firn-build's emit membership = every discovered .bnix minus these
     ;; skip arms (a faithful mirror of scripts/firn-build's `case "$src"`).
     (exclude-relpath-prefixes ("scripts/" "tests/" "docs/fixtures/"))
     (exclude-basenames ("enabled-tags.bnix"))
     (shape-markers ("find . -name '*.bnix' -not -path './result*'"
                     "./scripts/*) continue"
                     "./tests/*) continue"
                     "./docs/fixtures/*) continue"
                     "*/enabled-tags.bnix) continue"))
     ;; firn-validate's broader discovery (excludes only tests/fixtures/): the
     ;; authority separating negative fixtures from real-but-non-emitted sources.
     (validate-source "scripts/firn-validate")
     (validate-shape-markers ("find . -type f -name '*.bnix'"
                              "-not -path './tests/fixtures/*'"))
     (validate-negative-prefixes ("tests/fixtures/"))
     ;; FAIL-CLOSED accounting: every firn-build-excluded .bnix, classified.
     ;;   negative-fixture — intentionally broken; firn-validate ALSO excludes it.
     ;;   resolver-input   — enabled-tags authoring metadata; emits nix beagle
     ;;                      accepts but bare tag symbols aren't a valid module,
     ;;                      so firn-build skips it; firn-validate validates it.
     ;;   doc-fixture      — illustrative source firn-build skips; validated.
     (classified-excludes
      ((exclude (relpath "tests/fixtures/attrsof-leaf-nested.bnix")     (class negative-fixture))
       (exclude (relpath "tests/fixtures/attrsof-submodule-typo.bnix")  (class negative-fixture))
       (exclude (relpath "tests/fixtures/clean.bnix")                   (class negative-fixture))
       (exclude (relpath "tests/fixtures/enum-mismatch.bnix")           (class negative-fixture))
       (exclude (relpath "tests/fixtures/listof-int-wrong-element.bnix") (class negative-fixture))
       (exclude (relpath "tests/fixtures/submodule-typo.bnix")          (class negative-fixture))
       (exclude (relpath "tests/fixtures/type-mismatch-bool.bnix")      (class negative-fixture))
       (exclude (relpath "tests/fixtures/unknown-path.bnix")            (class negative-fixture))
       (exclude (relpath "hosts/ashashi/enabled-tags.bnix")             (class resolver-input))
       (exclude (relpath "hosts/whiterabbit/enabled-tags.bnix")         (class resolver-input))
       (exclude (relpath "template/hosts/my-machine/enabled-tags.bnix") (class resolver-input))
       (exclude (relpath "docs/fixtures/tags-example.bnix")             (class doc-fixture)))))))))

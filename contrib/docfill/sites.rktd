;; Authoritative registry of doc-fill sites — the committed files whose
;; target-dependent spans are OWNED by the compiler.
;;
;; Sibling of contrib/downstream/consumers.rktd, same discipline: name only the
;; stable seam (which file, which mechanism), never the volatile content. The
;; content is DERIVED at run time from beagle-lib/private/targets.rkt by
;; `bin/beagle doc-fill`, and beagle-test/tests/docfill.rkt fails the build when
;; a registered file has drifted from that render.
;;
;; kinds:
;;   markers    (default) fill each `<!-- beagle:langs VIEW -->` …
;;              `<!-- /beagle:langs -->` span in place. A registered file with
;;              no marker is an ERROR, not a no-op — a site that lost its
;;              markers has silently stopped being maintained.
;;   generated  the whole file IS one view's render; (view NAME) required.
;;
;; In-repo sites only. A downstream consumer that wants the same guarantee
;; opts in on its own side by running `beagle doc-fill --registry <its own>`;
;; this file never reaches outside the checkout.

(
 (site (path "README.md")
       (note "headline target sentence, idiom clause, target table, pipeline diagram, emitter inventory"))

 (site (path "CLAUDE.md")
       (note "target count in the architecture section; idiomatic-per-target clause in the generative spec"))

 (site (path "docs/architecture.md")
       (note "target spans externalized from the README restructure; registered so they cannot drift unowned"))

 (site (path "share/targets.sh")
       (kind generated)
       (view shell)
       (note "bash projection sourced by bin/beagle, bin/beagle-build, bin/beagle-init, bin/beagle-doctor — keeps the shell entry points off a hand-written case list without paying a racket startup"))
)

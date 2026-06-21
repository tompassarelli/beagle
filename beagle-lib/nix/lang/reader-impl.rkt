#lang racket/base

;; Nix reader. As of #25, nix uses the BASE beagle reader VERBATIM:
;; `~`/`~@` = unquote, `,` = whitespace — uniform across all targets. The old
;; `~"…"`/`~''…''` tilde-string sugar was removed; nix string interpolation is
;; the `(s …)` / `(ms …)` forms (precisely what the tilde reader used to desugar
;; to — same nix-interpolated-string / nix-multiline-string AST). For verbatim
;; Nix text, add the function to beagle-lib/private/stdlib-nix.rkt or import a
;; sibling .nix file. beagle-nix-read* exist so build-all / firn-build select the
;; nix readtable explicitly (it currently equals the base).

(require beagle/lang/reader-impl)

(define beagle-nix-readtable
  ;; nix shares the base readtable exactly (no nix-only reader extensions).
  (make-readtable beagle-readtable))

(define (beagle-nix-read in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read in)))

(define (beagle-nix-read-syntax src in)
  (parameterize ([read-square-bracket-with-tag '#%brackets]
                 [current-readtable beagle-nix-readtable])
    (read-syntax src in)))

(provide beagle-nix-read beagle-nix-read-syntax beagle-nix-readtable)

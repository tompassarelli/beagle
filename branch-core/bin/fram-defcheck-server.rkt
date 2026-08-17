#lang racket/base
;; ============================================================================
;; fram-defcheck-server — persistent, warm Beagle def-level checker.
;; ============================================================================
;; THE FAST INNER LOOP. Profiling (docs/private/a2-profile-2026-07-03.md) showed
;; the 40-90s whole-tree gate is ~100% per-check racket PROCESS-SPAWN overhead
;; (~5s to instantiate the beagle compiler module graph, paid once per module
;; render AND once per build, every repair cycle). The type-check COMPUTE itself
;; is ~0.02s/module. So the lever is a persistent process: pay the ~5s compiler
;; load ONCE at boot, then serve def-level checks warm (target <1s, measured ~0.1s).
;;
;; It consumes the server's `:render` EDN directly via the datum-IR path
;; (edn-triples->syntax, the same front-end as `beagle-build-all --build-edn`),
;; skipping BOTH the text-render spawn and the re-parse. Cross-module types
;; resolve because sibling modules live as .bclj files in a primed `gwdir`
;; (source-path resolution) — verified: whole-dir resolution has full fidelity,
;; single-module EDN alone degrades siblings to `Any`. The incremental check is
;; therefore def-level authoritative for the EDITED module against the CACHED
;; sibling environment; the whole-tree gate remains authoritative at promotion
;; (a def that type-checks alone but breaks a sibling caller is caught THERE).
;;
;; Protocol: one whitespace-delimited command per line on a TCP socket (loopback),
;; one JSON response line per command. Serial (beagle's checker holds global
;; state — one check at a time; each is ~0.1s so contention is negligible).
;;   ping                          -> {"ok":true,"pong":true}
;;   check <triples-path> <src>    -> {"ok":true,"errors":[<diagnostic jsexpr>...]}
;;   render <triples-path> <out>   -> {"ok":true}   (warm EDN->text for gwdir prime)
;;   quit                          -> closes the connection
;;
;; `errors` empty => the module type-checks. Each error is beagle's own
;; `diagnostic->json` jsexpr (kind/file/line/col/message + folded details incl.
;; expected/actual/function/fix_plan) — the Clojure primitive maps it to the
;; adapter-v2 ERROR shape. Run under the pinned beagle racket (bin/fram-defcheck).
;; ============================================================================

(require racket/tcp
         racket/list
         racket/string
         racket/path
         racket/port
         json
         beagle/private/facts-roundtrip   ; edn-triples->syntax read-edn-triples edn-triples->datum datum->pretty
         beagle/private/parse               ; parse-program
         beagle/private/check               ; type-check-with-locs!
         beagle/private/check-all)          ; diagnostic->json

;; --- EDN triples (server :render output) -> top-level syntax forms ------
;; Mirrors build-one-edn: build the (beagle-file form ...) datum the reader would
;; have produced, drop the wrapper head, hand the forms to parse-program. src-path
;; is the sibling-resolution base (gwdir/<module>.bclj) — its DIRECTORY must hold
;; the sibling .bclj files for cross-module requires to resolve past `Any`.
(define (edn->stxs triples-path src-path)
  (define srcloc-source (simplify-path (path->complete-path src-path)))
  (define wrapper (edn-triples->syntax (read-edn-triples triples-path) srcloc-source))
  (define forms (if wrapper (syntax->list wrapper) '()))
  (if (and (pair? forms) (eq? (syntax->datum (car forms)) 'beagle-file))
      (cdr forms) forms))

;; Type-check one module (from EDN) against its primed sibling dir. Returns a
;; (listof jsexpr) — empty when clean. Every raised diagnostic (parse-time,
;; type-time, or unstructured) is caught and rendered by beagle's OWN
;; diagnostic->json, so structured fields (expected/got/fix_plan) survive.
(define (check-edn triples-path src-path)
  (define errs '())
  (define (report e loc-stx)
    (set! errs (cons (diagnostic->json e loc-stx src-path) errs)))
  (with-handlers ([exn:fail? (lambda (e) (report e #f))])
    (define stxs (edn->stxs triples-path src-path))
    (define prog (parse-program stxs #:source-path src-path))
    (type-check-with-locs! prog (lambda (e loc-stx) (report e loc-stx))))
  (reverse errs))

;; Warm EDN -> Beagle source text, for priming/refreshing the sibling gwdir with
;; zero extra process spawns. edn-triples->datum yields the (beagle-file
;; (define-target ..) form ...) wrapper the reader would build; we STRIP the
;; wrapper head and pretty-print the inner top-level forms (leading
;; (define-target clj) is the canonical #lang header). Emitting the wrapped datum
;; verbatim would write ONE (beagle-file ...) form — unreadable as a sibling, so
;; cross-module names would silently degrade to Any. Signature-faithful (comment
;; fidelity is irrelevant to the type checker).
(define (render-edn->string triples-path)
  (define d (edn-triples->datum (read-edn-triples triples-path)))
  (define forms (if (and (pair? d) (eq? (car d) 'beagle-file)) (cdr d) (list d)))
  (string-join (map (lambda (f) (datum->pretty f)) forms) "\n\n"))

;; --- request dispatch --------------------------------------------------------
(define (handle-line line)
  (define parts (string-split (string-trim line)))
  (cond
    [(null? parts) (hasheq 'ok #f 'error "empty request")]
    [else
     (define cmd (car parts))
     (define args (cdr parts))
     (with-handlers
       ([exn:fail? (lambda (e) (hasheq 'ok #f 'error (exn-message e)))])
       (cond
         [(string=? cmd "ping") (hasheq 'ok #t 'pong #t)]
         [(string=? cmd "check")
          (unless (= (length args) 2)
            (error "usage: check <triples-path> <src-path>"))
          (define errs (check-edn (car args) (cadr args)))
          (hasheq 'ok #t 'errors errs)]
         [(string=? cmd "render")
          (unless (= (length args) 2)
            (error "usage: render <triples-path> <out-path>"))
          (call-with-output-file (cadr args) #:exists 'replace
            (lambda (out) (write-string (render-edn->string (car args)) out)))
          (hasheq 'ok #t)]
         [else (hasheq 'ok #f 'error (format "unknown command: ~a" cmd))]))]))

(define (serve-conn in out)
  (let loop ()
    (define line (read-line in))
    (cond
      [(eof-object? line) (void)]
      [(string=? (string-trim line) "quit") (void)]
      [else
       (write-json (handle-line line) out)
       (write-char #\newline out)
       (flush-output out)
       (loop)])))

(define (serve port)
  (define listener (tcp-listen port 128 #t "127.0.0.1"))
  ;; announce readiness on stdout so the launcher can gate on it
  (printf "fram-defcheck-server: ready on 127.0.0.1:~a\n" port)
  (flush-output)
  (let loop ()
    (define-values (in out) (tcp-accept listener))
    ;; serial: beagle's checker holds global state; each check is ~0.1s.
    (dynamic-wind void
                  (lambda () (serve-conn in out))
                  (lambda () (close-input-port in) (close-output-port out)))
    (loop)))

(module+ main
  (define argv (vector->list (current-command-line-arguments)))
  (when (null? argv)
    (eprintf "usage: fram-defcheck-server <port>\n")
    (exit 2))
  (serve (string->number (car argv))))

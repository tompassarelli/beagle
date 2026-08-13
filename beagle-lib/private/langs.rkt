#lang racket/base

;; Rendered views of the canonical language-target table (targets.rkt).
;;
;; THE COMPILER RENDERS EVERY VIEW; CONSUMERS NEVER RE-RENDER. `bin/beagle
;; langs` prints a view for a human, `bin/beagle doc-fill` splices the exact
;; same string into a marked span in a committed doc, and the generated
;; share/targets.sh is just the `shell` view. One renderer, so a target added
;; to targets.rkt cannot show up in one place and not another.

(require racket/string
         racket/list
         racket/format
         json
         "targets.rkt")

;; --- small helpers ---------------------------------------------------------

;; "a, b, and c" — the Oxford-comma prose join used in README/CLAUDE sentences.
(define (prose-join items)
  (cond
    [(null? items) ""]
    [(null? (cdr items)) (car items)]
    [(null? (cddr items)) (string-append (car items) " and " (cadr items))]
    [else (string-append (string-join (drop-right items 1) ", ")
                         ", and "
                         (last items))]))

(define NUMBER-WORDS
  #hasheq((0 . "zero") (1 . "one") (2 . "two") (3 . "three") (4 . "four")
          (5 . "five") (6 . "six") (7 . "seven") (8 . "eight") (9 . "nine")
          (10 . "ten") (11 . "eleven") (12 . "twelve")))

(define (number-word n) (hash-ref NUMBER-WORDS n (lambda () (number->string n))))

(define (id-str t) (symbol->string (target-id t)))
(define (core-id-str) (symbol->string (core-profile-id CORE-PROFILE)))
(define (materializer-id-str m) (symbol->string (materializer-id m)))
(define (profile-names)
  (cons (core-profile-name CORE-PROFILE) (map target-name TARGETS)))

;; --- views -----------------------------------------------------------------
;; A single-line view splices INLINE inside a marker; a multi-line view is a
;; block. doc-fill decides from the rendered string, so a view's shape is
;; decided here and nowhere else.

;; "Clojure, JavaScript, and Nix"
(define (view-names)
  (prose-join (profile-names)))

;; "six" — for prose that counts targets ("all six targets").
(define (view-count)
  (number-word (source-profile-count)))

;; "Nix lazy attrsets, Clojure eager persistent maps, …" — the
;; idiomatic-per-target clause.
(define (view-idioms)
  (string-join (cons
                (string-append (core-profile-name CORE-PROFILE)
                               " frozen native program")
                (for/list ([t (in-list TARGETS)])
                  (string-append (target-name t) " " (target-idiom t))))
               ", "))

;; `beagle-lib/private/emit-{…}.rkt` — the live target emitters.
(define (view-emitters)
  (string-append
   "- `native-core/src/native/{stages,lower,obligations}.bclj` — the hosted "
   "implementation that lowers Core into one immutable validated Native Core "
   "program; "
   "`native-core/src/native/body_c17.bclj` implements C17 and the explicit "
   "C17/WASI Wasm bootstrap; `native-core/src/native/qbe.bclj` implements "
   "the direct QBE materializer.\n"
   "- `beagle-lib/private/emit-{"
   (string-join (map id-str TARGETS) ",")
   "}.rkt` — the live target emitters (one row each in\n"
   "  `beagle-lib/private/targets.rkt`, the canonical target table).\n"
   "- `beagle-lib/private/"
   (projection-emitter (car PROJECTIONS))
   "` — the "
   (projection-note (car PROJECTIONS))
   "."))

(define (md-row . cells) (string-append "| " (string-join cells " | ") " |"))

(define (view-table)
  (string-join
   (append
    (list (md-row "target" "language" "source" "`#lang`" "output" "status")
          "|---|---|---|---|---|---|")
    (list
     (md-row (string-append "`" (core-id-str) "`")
             (core-profile-name CORE-PROFILE)
             (string-append "`" (core-profile-source-ext CORE-PROFILE) "`")
             (string-append "`#lang " (core-profile-lang CORE-PROFILE) "`")
             "frozen native program"
             (format "~a — ~a"
                     (core-profile-status CORE-PROFILE)
                     (core-profile-note CORE-PROFILE))))
    (for/list ([t (in-list TARGETS)])
      (md-row (string-append "`" (id-str t) "`")
              (target-name t)
              (string-append "`" (target-source-ext t) "`")
              (string-append "`#lang " (target-lang t) "`")
              (string-append "`" (target-out-ext t) "`")
              (format "~a — ~a" (target-status t) (target-note t))))
    (list ""
          (string-append
           (string-titlecase (number-word (source-profile-count)))
           " source profiles. Core produces the authoritative frozen native program; "
           "`--materializer "
           (string-join (map materializer-id-str MATERIALIZERS) "|")
           "` selects a projection. `"
           (symbol->string (projection-id (car PROJECTIONS)))
           "` is not one of them — it is the "
           (projection-note (car PROJECTIONS))
           ".")))
   "\n"))

(define (view-extensions)
  (string-join
   (append
    (list (md-row "extension" "target") "|---|---|")
    (list
     (md-row (string-append "`" (core-profile-source-ext CORE-PROFILE) "`")
             (string-append "`" (core-id-str) "` (`#lang "
                            (core-profile-lang CORE-PROFILE) "`)")))
    (for/list ([t (in-list TARGETS)])
      (md-row (string-append "`" (target-source-ext t) "`")
              (string-append "`" (id-str t) "` (`#lang " (target-lang t) "`)")))
    (for/list ([p (in-list NEUTRAL-EXTENSIONS)])
      (md-row (string-append "`" (car p) "`") (cdr p))))
   "\n"))

(define (view-domains)
  (string-join
   (cons
    (format "- **~a** (`~a`, `~a`) — ~a"
            (core-profile-name CORE-PROFILE)
            (core-id-str)
            (core-profile-source-ext CORE-PROFILE)
            (core-profile-domain CORE-PROFILE))
    (for/list ([t (in-list TARGETS)])
      (format "- **~a** (`~a`, `~a`) — ~a"
              (target-name t) (id-str t) (target-source-ext t) (target-domain t))))
   "\n"))

;; The `parse → check → emit` diagram, fence included: markdown comments cannot
;; live inside a fenced block, so the marker wraps the fence and this view owns
;; the fence lines.
(define (view-pipeline)
  (define src-exts (string-join (map target-source-ext TARGETS) " / "))
  (define out-exts (string-join (map target-out-ext TARGETS) " / "))
  (define head (string-append src-exts "  ──▶  parse ──▶ "))
  (define flow (string-append head "check ──▶ emit  ──▶  " out-exts))
  (define caret-col (+ (string-length head) 2))   ; centred under "check"
  (define note-col (max 0 (- caret-col 14)))
  (string-join
   (list "```"
         (string-append (core-profile-source-ext CORE-PROFILE)
                        "  ──▶ parse ──▶ check ──▶ freeze native program"
                        " ──▶ --materializer "
                        (string-join (map materializer-id-str MATERIALIZERS) "|"))
         flow
         (string-append (make-string caret-col #\space) "▲")
         (string-append (make-string note-col #\space)
                        "macros, schema, stdlib, type narrowing")
         (string-append (make-string note-col #\space)
                        "all share one AST + diagnostic path")
         "```")
   "\n"))

;; Generated bash projection, sourced by bin/beagle, bin/beagle-build,
;; bin/beagle-init and bin/beagle-doctor so those scripts never hand-list a
;; target and never pay a racket startup to ask.
(define (view-shell)
  (define (assoc-array name core-value f)
    (string-append
     "declare -A " name "=("
     (string-join
      (cons (format "[~a]=~a" (core-id-str) core-value)
            (for/list ([t (in-list TARGETS)])
              (format "[~a]=~a" (id-str t) (f t))))
      " ")
     ")"))
  (define all-ids (map symbol->string (source-profile-ids)))
  (define materializer-ids* (map materializer-id-str MATERIALIZERS))
  (string-join
   (list
    "# GENERATED — do not edit. Regenerate with `bin/beagle doc-fill`."
    "# Source of truth: beagle-lib/private/targets.rkt (view: shell)."
    "# Drift is a build failure (beagle-test/tests/docfill.rkt)."
    ""
    (format "BEAGLE_TARGET_IDS=(~a)" (string-join all-ids " "))
    (format "BEAGLE_HOSTED_TARGET_IDS=(~a)" (string-join (map id-str TARGETS) " "))
    (format "BEAGLE_TARGET_IDS_RE='~a'" (string-join all-ids "|"))
    (format "BEAGLE_TARGET_IDS_LIST='~a'"
            (prose-join all-ids))
    (format "BEAGLE_TARGET_NAMES='~a'" (view-names))
    (format "BEAGLE_TARGET_COUNT=~a" (source-profile-count))
    (assoc-array "BEAGLE_TARGET_LANG" (core-profile-lang CORE-PROFILE) target-lang)
    (assoc-array "BEAGLE_TARGET_SRC_EXT"
                 (substring (core-profile-source-ext CORE-PROFILE) 1)
                 (lambda (t) (substring (target-source-ext t) 1)))
    (assoc-array "BEAGLE_TARGET_OUT_EXT"
                 "native-program"
                 (lambda (t) (substring (target-out-ext t) 1)))
    (assoc-array "BEAGLE_TARGET_STATUS"
                 (symbol->string (core-profile-status CORE-PROFILE))
                 (lambda (t) (symbol->string (target-status t))))
    (assoc-array "BEAGLE_TARGET_PIPELINE" "native-program"
                 (lambda (_t) "hosted-emitter"))
    (format "BEAGLE_MATERIALIZER_IDS=(~a)" (string-join materializer-ids* " "))
    (format "BEAGLE_MATERIALIZER_IDS_LIST='~a'" (prose-join materializer-ids*))
    (string-append
     "declare -A BEAGLE_MATERIALIZER_OUT_EXT=("
     (string-join
      (for/list ([m (in-list MATERIALIZERS)])
        (format "[~a]=~a" (materializer-id-str m)
                (substring (materializer-out-ext m) 1)))
      " ")
     ")")
    ""
    "beagle_known_target() {"
    "    local t=\"$1\""
    "    local k"
    "    for k in \"${BEAGLE_TARGET_IDS[@]}\"; do"
    "        [[ \"$k\" == \"$t\" ]] && return 0"
    "    done"
    "    return 1"
    "}"
    ""
    "beagle_known_hosted_target() {"
    "    local t=\"$1\""
    "    local k"
    "    for k in \"${BEAGLE_HOSTED_TARGET_IDS[@]}\"; do"
    "        [[ \"$k\" == \"$t\" ]] && return 0"
    "    done"
    "    return 1"
    "}"
    ""
    "beagle_known_materializer() {"
    "    local m=\"$1\""
    "    local k"
    "    for k in \"${BEAGLE_MATERIALIZER_IDS[@]}\"; do"
    "        [[ \"$k\" == \"$m\" ]] && return 0"
    "    done"
    "    return 1"
    "}")
   "\n"))

(define VIEWS
  (list (cons 'names      view-names)
        (cons 'count      view-count)
        (cons 'idioms     view-idioms)
        (cons 'table      view-table)
        (cons 'extensions view-extensions)
        (cons 'domains    view-domains)
        (cons 'pipeline   view-pipeline)
        (cons 'emitters   view-emitters)
        (cons 'shell      view-shell)))

(define (view-names-list) (map (lambda (p) (symbol->string (car p))) VIEWS))

;; #f when the name is unknown — callers decide how loudly to fail.
(define (render-view name)
  (define p (assq (if (symbol? name) name (string->symbol name)) VIEWS))
  (and p ((cdr p))))

;; --- machine view ----------------------------------------------------------

(define (targets-jsexpr)
  (hasheq 'schemaVersion 1
          'count (source-profile-count)
          'coreTarget
          (hasheq
           'id (core-id-str)
           'name (core-profile-name CORE-PROFILE)
           'sourceExtension (core-profile-source-ext CORE-PROFILE)
           'lang (core-profile-lang CORE-PROFILE)
           'pipeline "native-program"
           'output "frozen native program"
           'status (symbol->string (core-profile-status CORE-PROFILE))
           'note (core-profile-note CORE-PROFILE)
           'domain (core-profile-domain CORE-PROFILE)
           'materializers
           (for/list ([m (in-list MATERIALIZERS)])
             (hasheq 'id (materializer-id-str m)
                     'name (materializer-name m)
                     'outputExtension (materializer-out-ext m)
                     'artifact (materializer-artifact m)
                     'note (materializer-note m))))
          'hostedTargetCount (target-count)
          'targets (for/list ([t (in-list TARGETS)])
                     (hasheq 'id (id-str t)
                             'name (target-name t)
                             'sourceExtension (target-source-ext t)
                             'lang (target-lang t)
                             'pipeline "hosted-emitter"
                             'outputExtension (target-out-ext t)
                             'status (symbol->string (target-status t))
                             'note (target-note t)
                             'emitter (string-append "beagle-lib/private/"
                                                     (target-emitter t))
                             'idiom (target-idiom t)
                             'domain (target-domain t)))
          'projections (for/list ([p (in-list PROJECTIONS)])
                         (hasheq 'id (symbol->string (projection-id p))
                                 'name (projection-name p)
                                 'emitter (string-append "beagle-lib/private/"
                                                         (projection-emitter p))
                                 'note (projection-note p)))
          'views (view-names-list)))

(provide view-names-list
         render-view
         targets-jsexpr)

;; --- CLI -------------------------------------------------------------------

(module+ main
  (define view "table")
  (define as-json #f)
  (let loop ([args (vector->list (current-command-line-arguments))])
    (cond
      [(null? args) (void)]
      [(equal? (car args) "--json") (set! as-json #t) (loop (cdr args))]
      [(equal? (car args) "--list-views")
       (displayln (string-join (view-names-list) "\n"))
       (exit 0)]
      [(equal? (car args) "--view")
       (when (null? (cdr args))
         (eprintf "beagle langs: --view needs a view name (one of: ~a)\n"
                  (string-join (view-names-list) ", "))
         (exit 2))
       (set! view (cadr args))
       (loop (cddr args))]
      [(regexp-match #rx"^--view=(.*)$" (car args))
       => (lambda (m) (set! view (cadr m)) (loop (cdr args)))]
      [(member (car args) '("--help" "-h"))
       (displayln "usage: beagle langs [--json] [--view NAME] [--list-views]")
       (displayln (string-append "views: " (string-join (view-names-list) ", ")))
       (exit 0)]
      [else
       (eprintf "beagle langs: unknown argument '~a'\n" (car args))
       (exit 2)]))
  (cond
    [as-json (displayln (jsexpr->string (targets-jsexpr)))]
    [else
     (define out (render-view view))
     (unless out
       (eprintf "beagle langs: unknown view '~a' (one of: ~a)\n"
                view (string-join (view-names-list) ", "))
       (exit 2))
     (displayln out)]))

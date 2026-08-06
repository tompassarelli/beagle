#lang racket/base

;; Deterministic, source-only semantic index for native Beagle consumers.
;; The index is assembled completely before a byte is written.

(require json
         openssl/sha1
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         "extensions.rkt"
         "module-interface.rkt"
         "parse.rkt"
         "validate-nix.rkt")

(define SEMANTIC-INDEX-SCHEMA-VERSION 1)
(define INDEXED-EXTENSIONS
  (filter (lambda (ext) (not (equal? ext ".rkt"))) BEAGLE-EXTENSIONS))

(struct indexed-file (entry interface) #:transparent)

(define (sha256-hex bytes)
  (bytes->hex-string (sha256-bytes bytes)))

(define (indexed-source-file? path)
  (define s (path->string path))
  (ormap (lambda (ext) (string-suffix? s ext)) INDEXED-EXTENSIONS))

(define (absolute-existing-path path)
  (simplify-path (path->complete-path path) #t))

(define (path-inside-root root path)
  (define rel (find-relative-path root path))
  (and (relative-path? rel)
       (not (for/or ([part (in-list (explode-path rel))])
              (eq? part 'up)))
       rel))

(define (hidden-relative-path? rel)
  (for/or ([part (in-list (explode-path rel))])
    (and (path? part)
         (let ([s (path->string part)])
           (and (positive? (string-length s))
                (char=? (string-ref s 0) #\.))))))

(define (source-input->files root input)
  (define path (absolute-existing-path input))
  (cond
    [(file-exists? path)
     (unless (indexed-source-file? path)
       (error 'semantic-index "unknown Beagle source extension: ~a" input))
     (list path)]
    [(directory-exists? path)
     (for/list ([candidate (in-list (find-files file-exists? path))]
                #:when (indexed-source-file? candidate)
                #:do [(define rel (path-inside-root root
                                                    (absolute-existing-path candidate)))]
                #:when (and rel (not (hidden-relative-path? rel))))
       (absolute-existing-path candidate))]
    [else
     (error 'semantic-index "source does not exist: ~a" input)]))

(define (collect-source-paths root inputs)
  (when (null? inputs)
    (error 'semantic-index "expected at least one source file or directory"))
  (define by-relative (make-hash))
  (for ([input (in-list inputs)])
    (for ([source (in-list (source-input->files root input))])
      (define rel (path-inside-root root source))
      (unless rel
        (error 'semantic-index
               "source is outside index root ~a: ~a"
               (path->string root)
               (path->string source)))
      (define rel-string (path->string rel))
      (hash-set! by-relative rel-string source)))
  (when (zero? (hash-count by-relative))
    (error 'semantic-index "no Beagle source files found"))
  (for/list ([rel (in-list (sort (hash-keys by-relative) string<?))])
    (cons rel (hash-ref by-relative rel))))

(define (json-key-string key)
  (cond
    [(symbol? key)
     (define s (symbol->string key))
     (if (and (positive? (string-length s))
              (char=? (string-ref s 0) #\:))
         (substring s 1)
         s)]
    [(string? key) key]
    [else
     (error 'semantic-index "metadata map key is not a symbol or string: ~v" key)]))

(define (datum->json value)
  (cond
    [(eq? value 'true) #t]
    [(eq? value 'false) #f]
    [(or (eq? value 'nil) (eq? value 'null)) 'null]
    [(symbol? value) (json-key-string value)]
    [(or (string? value) (boolean? value) (number? value)) value]
    [(vector? value) (map datum->json (vector->list value))]
    [(list? value) (map datum->json value)]
    [else
     (error 'semantic-index "metadata value is not JSON-native: ~v" value)]))

(define (metadata-value->json value)
  (cond
    [(map-form? value)
     (for/fold ([result (hash)]) ([pair (in-list (map-form-pairs value))])
       (define key (json-key-string (car pair)))
       (when (hash-has-key? result key)
         (error 'semantic-index "duplicate metadata key: ~a" key))
       (hash-set result key (metadata-value->json (cdr pair))))]
    [(vec-form? value)
     (map metadata-value->json (vec-form-items value))]
    [(set-form? value)
     (sort (map metadata-value->json (set-form-items value))
           string<?
           #:key (lambda (item) (format "~s" item)))]
    [(quoted? value) (datum->json (quoted-datum value))]
    [(nix-path? value) (nix-path-path-string value)]
    [else (datum->json value)]))

(define (map-value body-map key [fallback #f])
  (cond
    [(not body-map) fallback]
    [else
     (define pair
       (for/or ([entry (in-list (map-form-pairs body-map))])
         (and (eq? (car entry) key) entry)))
     (if pair (cdr pair) fallback)]))

(define (unwrap-module-map value [depth 0])
  (cond
    [(> depth 8) #f]
    [(map-form? value) value]
    [(let-form? value)
     (define body (let-form-body value))
     (and (pair? body) (unwrap-module-map (last body) (add1 depth)))]
    [(and (call-form? value)
          (memq (call-form-fn value) '(lib/mkIf lib.mkIf))
          (pair? (call-form-args value)))
     (unwrap-module-map (last (call-form-args value)) (add1 depth))]
    [else #f]))

(define (program-module-map prog)
  (for/or ([form (in-list (program-forms prog))])
    (and (nix-fn-set? form)
         (unwrap-module-map (nix-fn-set-body form)))))

(define (metadata-list body-map key)
  (define value (map-value body-map key #f))
  (cond
    [(not value) '()]
    [(vec-form? value) (map metadata-value->json (vec-form-items value))]
    [else (error 'semantic-index "~a metadata must be a vector" key)]))

(define (metadata-map body-map key)
  (define value (map-value body-map key #f))
  (cond
    [(not value) (hash)]
    [(map-form? value) (metadata-value->json value)]
    [else (error 'semantic-index "~a metadata must be a map" key)]))

(define (module-metadata rel prog)
  (cond
    [(not (regexp-match? #px"^modules/[^/]+/default[.]bnix$" rel)) 'null]
    [else
     (define body (program-module-map prog))
     (unless body
       (error 'semantic-index "~a: module source has no top-level nix/module" rel))
     (hasheq 'tags (metadata-list body ':tags)
             'tagsOptIn (metadata-list body ':tags-opt-in)
             'tagOverrides (metadata-map body ':tag-overrides)
             'flakeInputs (metadata-map body ':flake-inputs))]))

(define (host-name rel)
  (define match (regexp-match #px"^hosts/([^/]+)/enabled-tags[.]bnix$" rel))
  (and match (cadr match)))

(define (host-metadata rel prog)
  (define name (host-name rel))
  (cond
    [(not name) 'null]
    [else
     (define body
       (for/or ([form (in-list (program-forms prog))])
         (and (map-form? form) form)))
     (unless body
       (error 'semantic-index "~a: host metadata source has no top-level map" rel))
     (define platform-value (map-value body ':platform 'linux))
     (define platform (metadata-value->json platform-value))
     (unless (string? platform)
       (error 'semantic-index "~a: host platform must be a symbol or string" rel))
     (hasheq 'name name
             'platform platform
             'enabled (metadata-list body ':enabled)
             'disabled (metadata-list body ':disabled))]))

(define (token-boundary? text index)
  (or (< index 0)
      (>= index (string-length text))
      (char-whitespace? (string-ref text index))
      (memv (string-ref text index)
            '(#\( #\) #\[ #\] #\{ #\} #\" #\' #\; #\,))))

(define (offset->src-loc source text start span)
  (define prefix (substring text 0 start))
  (define line (add1 (for/sum ([char (in-string prefix)])
                       (if (char=? char #\newline) 1 0))))
  (define last-newline
    (for/last ([index (in-range (string-length prefix))]
               #:when (char=? (string-ref prefix index) #\newline))
      index))
  (define col (- start (if last-newline (add1 last-newline) 0)))
  (src-loc line col source 'original #f (add1 start) span))

(define (source-key-locations source symbols)
  ;; The Beagle map reader currently gives every map child its enclosing map
  ;; location. Use the parsed walk to decide WHICH authored keys matter, then
  ;; recover those exact token spans from source text. The scanner only records
  ;; the key position of each real `{key value}` pair; an identical keyword in
  ;; a value, comment, or string is not a candidate occurrence.
  (define text (file->string source))
  (define wanted
    (for/hash ([symbol (in-list (remove-duplicates symbols eq?))])
      (values (symbol->string symbol) symbol)))
  (define found (make-hasheq))
  (define length (string-length text))
  (define (starts-at? index literal)
    (define end (+ index (string-length literal)))
    (and (<= end length)
         (string=? (substring text index end) literal)))
  (define (token-end start)
    (let loop ([index start])
      (if (or (>= index length) (token-boundary? text index))
          index
          (loop (add1 index)))))
  (define (skip-string start)
    (let loop ([index (add1 start)])
      (cond
        [(>= index length) length]
        [(char=? (string-ref text index) #\\)
         (loop (min length (+ index 2)))]
        [(char=? (string-ref text index) #\")
         (add1 index)]
        [else (loop (add1 index))])))
  (define (skip-nix-multiline start)
    (let loop ([index (+ start 3)])
      (cond
        [(>= index length) length]
        [(starts-at? index "''") (+ index 2)]
        [else (loop (add1 index))])))
  (define (skip-comment start)
    (let loop ([index (add1 start)])
      (cond
        [(>= index length) length]
        [(char=? (string-ref text index) #\newline) (add1 index)]
        [else (loop (add1 index))])))
  (define (skip-layout start)
    (let loop ([index start])
      (cond
        [(>= index length) length]
        [(or (char-whitespace? (string-ref text index))
             (char=? (string-ref text index) #\,))
         (loop (add1 index))]
        [(char=? (string-ref text index) #\;)
         (loop (skip-comment index))]
        [else index])))
  (define (record-key! start end)
    (define token (substring text start end))
    (define symbol (hash-ref wanted token #f))
    (when symbol
      (hash-update!
       found
       symbol
       (lambda (locations)
         (cons (offset->src-loc source text start (- end start))
               locations))
       '())))
  (define (scan-delimited start close)
    (let loop ([index start])
      (define next (skip-layout index))
      (cond
        [(>= next length) length]
        [(char=? (string-ref text next) close) (add1 next)]
        [else (loop (scan-form next))])))
  (define (scan-map start)
    (let loop ([index (add1 start)])
      (define key-start (skip-layout index))
      (cond
        [(>= key-start length) length]
        [(char=? (string-ref text key-start) #\}) (add1 key-start)]
        [else
         (when (char=? (string-ref text key-start) #\:)
           (record-key! key-start (token-end key-start)))
         (define after-key (scan-form key-start))
         (define value-start (skip-layout after-key))
         (cond
           [(>= value-start length) length]
           ;; The real reader rejects odd maps. Avoid inventing a value or
           ;; looping here if a malformed source reaches this recovery pass.
           [(char=? (string-ref text value-start) #\}) (add1 value-start)]
           [else (loop (scan-form value-start))])])))
  (define (scan-form start)
    (define index (skip-layout start))
    (cond
      [(>= index length) length]
      [(starts-at? index "~''") (skip-nix-multiline index)]
      [(starts-at? index "#{") (scan-delimited (+ index 2) #\})]
      [(starts-at? index "#(") (scan-delimited (+ index 2) #\))]
      [(starts-at? index "#\"") (skip-string (add1 index))]
      [else
       (define char (string-ref text index))
       (cond
         [(char=? char #\") (skip-string index)]
         [(char=? char #\() (scan-delimited (add1 index) #\))]
         [(char=? char #\[) (scan-delimited (add1 index) #\])]
         [(char=? char #\{) (scan-map index)]
         ;; Reader prefixes form one datum with the following form. Metadata
         ;; consumes both its metadata datum and the annotated datum.
         [(memv char '(#\' #\` #\@))
          (scan-form (add1 index))]
         [(char=? char #\~)
          (scan-form (+ index (if (starts-at? index "~@") 2 1)))]
         [(char=? char #\^)
          (scan-form (scan-form (add1 index)))]
         ;; Character literals may spell a quote or semicolon without starting
         ;; a string/comment. Consume the escaped character before scanning on.
         [(char=? char #\\)
          (token-end (min length (+ index 2)))]
         [(memv char '(#\) #\] #\})) (add1 index)]
         [else
          (define end (token-end index))
          (if (= end index) (add1 index) end)])]))
  (let loop ([index 0])
    (define next (skip-layout index))
    (unless (>= next length)
      (loop (scan-form next))))
  (for/hash ([symbol (in-list (remove-duplicates symbols eq?))])
    (values symbol (reverse (hash-ref found symbol '())))))

(define (loc->json loc)
  (hasheq 'line (src-loc-line loc)
          'col (src-loc-col loc)
          'pos (src-loc-pos loc)
          'span (src-loc-span loc)))

(define (program-option-refs prog source)
  (define-values (keys _warnings) (collect-program-keys prog))
  (define src-table (program-src-table prog))
  (define locations
    (source-key-locations source (map found-key-key-sym keys)))
  ;; Keep the text-span recovery tied to the same parsed source. The table is
  ;; the compiler's source-of-truth for AST provenance even though its map
  ;; children currently share the enclosing map position.
  (for ([loc (in-hash-values src-table)] #:when (src-loc? loc))
    (define loc-source (src-loc-source loc))
    (when (and loc-source
               (not (equal? (simplify-path (path->complete-path loc-source) #t)
                            (simplify-path (path->complete-path source) #t))))
      (error 'semantic-index
             "program source table points outside indexed source: ~a"
             loc-source)))
  (for/list ([key (in-list keys)]
             #:do
             [(define candidates
                (hash-ref locations (found-key-key-sym key) '()))
              (define occurrence (found-key-occurrence key))
              (define loc
                (and (< occurrence (length candidates))
                     (list-ref candidates occurrence)))]
             #:when loc)
    (hasheq 'path (found-key-path key)
            'span (loc->json loc))))

(define (requires->json interface)
  (for/list ([entry (in-list
                     (sort (module-interface-requires interface)
                           string<?
                           #:key (lambda (candidate)
                                   (symbol->string
                                    (require-entry-ns candidate)))))])
    (symbol->string (require-entry-ns entry))))

(define (build-indexed-file rel source)
  (define stxs (read-beagle-syntax source))
  (define datums (map syntax->datum stxs))
  (define prog (parse-program stxs #:source-path source))
  (define interface
    (program->module-interface prog #:source-id rel #:datums datums))
  (indexed-file
   (hasheq 'path rel
           'sha256 (sha256-hex (file->bytes source))
           'namespace (symbol->string (module-interface-namespace interface))
           'target (symbol->string (module-interface-target interface))
           'requires (requires->json interface)
           'moduleMetadata (module-metadata rel prog)
           'hostMetadata (host-metadata rel prog)
           'optionRefs (program-option-refs prog source))
   interface))

(define (root-hash entries)
  ;; Domain is the sorted sequence: UTF-8 path, NUL, lowercase file hash, LF.
  (define bytes
    (call-with-output-bytes
     (lambda (out)
       (for ([entry (in-list entries)])
         (display (hash-ref entry 'path) out)
         (write-byte 0 out)
         (display (hash-ref entry 'sha256) out)
         (newline out)))))
  (sha256-hex bytes))

(define (build-semantic-index root inputs)
  (define root-path (absolute-existing-path root))
  (unless (directory-exists? root-path)
    (error 'semantic-index "index root is not a directory: ~a" root))
  (define indexed
    (for/list ([source (in-list (collect-source-paths root-path inputs))])
      (build-indexed-file (car source) (cdr source))))
  ;; Use the compiler's canonical module/source/overlay digest boundary while all
  ;; modules are still in memory. JSON v1 intentionally exposes only raw file
  ;; hashes and its own root hash.
  (module-interfaces-overlay-digest (map indexed-file-interface indexed))
  (define entries (map indexed-file-entry indexed))
  (hasheq 'schemaVersion SEMANTIC-INDEX-SCHEMA-VERSION
          'rootHash (root-hash entries)
          'files entries))

(define (write-canonical-json value [out (current-output-port)])
  (cond
    [(hash? value)
     (display "{" out)
     (for ([key (in-list (sort (hash-keys value)
                               string<?
                               #:key json-key-string))]
           [index (in-naturals)])
       (unless (zero? index) (display "," out))
       (write-json (json-key-string key) out)
       (display ":" out)
       (write-canonical-json (hash-ref value key) out))
     (display "}" out)]
    [(list? value)
     (display "[" out)
     (for ([item (in-list value)] [index (in-naturals)])
       (unless (zero? index) (display "," out))
       (write-canonical-json item out))
     (display "]" out)]
    [else (write-json value out)]))

(define (write-semantic-index index [out (current-output-port)])
  (write-canonical-json index out)
  (newline out))

(provide SEMANTIC-INDEX-SCHEMA-VERSION
         build-semantic-index
         write-canonical-json
         write-semantic-index)

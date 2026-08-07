#lang racket/base

;; TypeScript declarations -> beagle externs. The mapping is lossy by design: a TS
;; shape beagle cannot express degrades to `Any` rather than being guessed.

(require racket/string
         racket/list
         racket/file
         racket/path
         racket/match
         racket/format)

(provide run-ts-externs
         ts-type->beagle
         parse-declarations
         (struct-out ts-class)
         (struct-out ts-member)
         (struct-out ts-param))

(struct ts-param (name type optional? rest?) #:transparent)
;; kind: 'constructor | 'method | 'static-method | 'property | 'static-property
(struct ts-member (kind name params type readonly?) #:transparent)
(struct ts-class (name source base members) #:transparent)

;; --- lexing ------------------------------------------------------------------

;; Strip comments without touching string or template literals.
(define (strip-comments s)
  (define out (open-output-string))
  (define len (string-length s))
  (let loop ([i 0])
    (when (< i len)
      (define c (string-ref s i))
      (define c2 (and (< (add1 i) len) (string-ref s (add1 i))))
      (cond
        [(and (char=? c #\/) (eqv? c2 #\*))
         (define end (let scan ([j (+ i 2)])
                       (cond [(>= j (sub1 len)) len]
                             [(and (char=? (string-ref s j) #\*)
                                   (char=? (string-ref s (add1 j)) #\/)) (+ j 2)]
                             [else (scan (add1 j))])))
         ;; A comment can separate two tokens; collapse it to whitespace.
         (write-char #\space out)
         (loop end)]
        [(and (char=? c #\/) (eqv? c2 #\/))
         (define end (let scan ([j (+ i 2)])
                       (cond [(>= j len) len]
                             [(char=? (string-ref s j) #\newline) j]
                             [else (scan (add1 j))])))
         (write-char #\space out)
         (loop end)]
        [(or (char=? c #\") (char=? c #\') (char=? c #\`))
         (define end (let scan ([j (add1 i)])
                       (cond [(>= j len) len]
                             [(char=? (string-ref s j) #\\) (scan (+ j 2))]
                             [(char=? (string-ref s j) c) (add1 j)]
                             [else (scan (add1 j))])))
         (write-string (substring s i (min end len)) out)
         (loop end)]
        [else (write-char c out) (loop (add1 i))])))
  (get-output-string out))

(define OPENERS (hash #\( #\) #\[ #\] #\{ #\} #\< #\>))

;; Split on `sep` at nesting depth zero. `<` is counted only when it plausibly
;; opens a type argument list, since it is also the less-than operator.
(define (split-top-level s sep)
  (define len (string-length s))
  (define pieces '())
  (define start 0)
  (let loop ([i 0] [depth 0] [angle 0])
    (cond
      [(>= i len)
       (set! pieces (cons (substring s start len) pieces))]
      [else
       (define c (string-ref s i))
       (cond
         [(or (char=? c #\") (char=? c #\') (char=? c #\`))
          (define end (let scan ([j (add1 i)])
                        (cond [(>= j len) len]
                              [(char=? (string-ref s j) #\\) (scan (+ j 2))]
                              [(char=? (string-ref s j) c) (add1 j)]
                              [else (scan (add1 j))])))
          (loop end depth angle)]
         [(and (char=? c sep) (= depth 0) (= angle 0))
          (set! pieces (cons (substring s start i) pieces))
          (set! start (add1 i))
          (loop (add1 i) depth angle)]
         [(memv c '(#\( #\[ #\{)) (loop (add1 i) (add1 depth) angle)]
         [(memv c '(#\) #\] #\})) (loop (add1 i) (max 0 (sub1 depth)) angle)]
         [(char=? c #\<) (loop (add1 i) depth (add1 angle))]
         [(char=? c #\>)
          ;; `=>` is a function-type arrow, not a closing type bracket.
          (if (and (> i 0) (char=? (string-ref s (sub1 i)) #\=))
              (loop (add1 i) depth angle)
              (loop (add1 i) depth (max 0 (sub1 angle))))]
         [else (loop (add1 i) depth angle)])]))
  (reverse pieces))

;; Index of the `{ ... }` body that starts at or after `from`, as (values open close).
(define (brace-range s from)
  (define len (string-length s))
  (define open (let scan ([i from])
                 (cond [(>= i len) #f]
                       [(char=? (string-ref s i) #\{) i]
                       [else (scan (add1 i))])))
  (cond
    [(not open) (values #f #f)]
    [else
     (define close
       (let scan ([i open] [depth 0])
         (cond
           [(>= i len) #f]
           [else
            (define c (string-ref s i))
            (cond
              [(or (char=? c #\") (char=? c #\') (char=? c #\`))
               (define end (let inner ([j (add1 i)])
                             (cond [(>= j len) len]
                                   [(char=? (string-ref s j) #\\) (inner (+ j 2))]
                                   [(char=? (string-ref s j) c) (add1 j)]
                                   [else (inner (add1 j))])))
               (scan end depth)]
              [(char=? c #\{) (scan (add1 i) (add1 depth))]
              [(char=? c #\})
               (if (= depth 1) i (scan (add1 i) (sub1 depth)))]
              [else (scan (add1 i) depth)])])))
     (values open close)]))

;; --- type mapping ------------------------------------------------------------

(define (strip-parens t)
  (define s (string-trim t))
  (if (and (> (string-length s) 1)
           (char=? (string-ref s 0) #\()
           ;; Only when the leading paren closes at the very end.
           (let ([parts (split-top-level (substring s 1 (sub1 (string-length s))) #\,)])
             (and parts (char=? (string-ref s (sub1 (string-length s))) #\)))))
      (strip-parens (substring s 1 (sub1 (string-length s))))
      s))

(define (generic-of t name)
  (define s (string-trim t))
  (define prefix (string-append name "<"))
  (and (string-prefix? s prefix)
       (string-suffix? s ">")
       (string-trim (substring s (string-length prefix) (sub1 (string-length s))))))

;; TS type expression -> beagle type string. Unmappable shapes become "Any".
(define (ts-type->beagle t0)
  (define t (strip-parens t0))
  (define union (split-top-level t #\|))
  (cond
    [(string=? t "") "Any"]
    ;; `T | null` / `T | undefined`: beagle has no optionality in the type, so the
    ;; nullable member is dropped and the payload type carries through.
    [(> (length union) 1)
     (define members
       (filter (lambda (m) (not (member (string-trim m) '("null" "undefined" "void"))))
               union))
     (define mapped (remove-duplicates (map (lambda (m) (ts-type->beagle m)) members)))
     (if (= (length mapped) 1) (car mapped) "Any")]
    [else
     (define s (string-trim t))
     (cond
       [(member s '("number")) "Float"]
       [(member s '("string")) "String"]
       [(member s '("boolean")) "Bool"]
       [(member s '("void" "undefined" "null" "never")) "Nil"]
       [(member s '("any" "unknown" "object" "this" "symbol" "bigint")) "Any"]
       [(regexp-match #rx"^-?[0-9]+(\\.[0-9]+)?$" s) "Float"]
       [(regexp-match #rx"^[\"'].*[\"']$" s) "String"]
       [(string-suffix? s "[]")
        (format "(Vec ~a)" (ts-type->beagle (substring s 0 (- (string-length s) 2))))]
       [(generic-of s "Array") => (lambda (inner) (format "(Vec ~a)" (ts-type->beagle inner)))]
       [(generic-of s "ReadonlyArray") => (lambda (inner) (format "(Vec ~a)" (ts-type->beagle inner)))]
       [(generic-of s "Promise") => (lambda (inner) (format "(Promise ~a)" (ts-type->beagle inner)))]
       ;; Class and interface handles have no nominal representation in beagle:
       ;; an object is an opaque `Any`. Same for generics, tuples, mapped types,
       ;; and function types.
       [else "Any"])]))

;; --- declaration parsing -----------------------------------------------------

(define (parse-params params-src)
  (define src (string-trim params-src))
  (if (string=? src "")
      '()
      (for/list ([piece (in-list (split-top-level src #\,))]
                 #:unless (string=? (string-trim piece) ""))
        (define p (string-trim piece))
        (define rest? (string-prefix? p "..."))
        (define body (if rest? (string-trim (substring p 3)) p))
        (define colon (let scan ([parts (split-top-level body #\:)])
                        (and (> (length parts) 1) parts)))
        (define-values (name-part type-part)
          (if colon
              (values (car colon) (string-join (cdr colon) ":"))
              (values body "any")))
        (define raw-name (string-trim name-part))
        (define optional? (string-suffix? raw-name "?"))
        (define name (string-trim (if optional? (substring raw-name 0 (sub1 (string-length raw-name))) raw-name)))
        (ts-param name (string-trim type-part) optional? rest?))))

;; One `;`-separated statement inside a class body.
(define (parse-member stmt)
  (define s (string-trim stmt))
  (cond
    [(string=? s "") #f]
    ;; Modifiers beagle cannot express are dropped along with their members.
    [(regexp-match #rx"^(private|protected)[ \t]" s) #f]
    [else
     (define static? (regexp-match? #rx"^static[ \t]" s))
     (define body (if static? (string-trim (substring s 6)) s))
     (define readonly? (regexp-match? #rx"^readonly[ \t]" body))
     (define body2 (if readonly? (string-trim (substring body 8)) body))
     (cond
       [(string-prefix? body2 "constructor")
        (define-values (open close) (paren-range body2))
        (and open close
             (ts-member 'constructor "constructor"
                        (parse-params (substring body2 (add1 open) close)) "this" #f))]
       ;; get/set accessors read as properties.
       [(regexp-match #rx"^(get|set)[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*\\(" body2)
        => (lambda (m)
             (define kind (cadr m))
             (define name (caddr m))
             (if (string=? kind "get")
                 (ts-member (if static? 'static-property 'property) name '()
                            (or (return-type-of body2) "any") #f)
                 #f))]
       [(regexp-match #rx"^([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*[<(]" body2)
        => (lambda (m)
             (define name (cadr m))
             (define-values (open close) (paren-range body2))
             (and open close
                  (ts-member (if static? 'static-method 'method) name
                             (parse-params (substring body2 (add1 open) close))
                             (or (return-type-of body2) "any")
                             #f)))]
       [(regexp-match #rx"^([A-Za-z_$][A-Za-z0-9_$]*)[ \t]*\\??[ \t]*:[ \t]*(.+)$" body2)
        => (lambda (m)
             (ts-member (if static? 'static-property 'property) (cadr m) '() (caddr m) readonly?))]
       [else #f])]))

;; The `( ... )` parameter list: (values open-index close-index).
(define (paren-range s)
  (define len (string-length s))
  (define open (let scan ([i 0] [angle 0])
                 (cond [(>= i len) #f]
                       [(char=? (string-ref s i) #\() i]
                       [(char=? (string-ref s i) #\<) (scan (add1 i) (add1 angle))]
                       [else (scan (add1 i) angle)])))
  (cond
    [(not open) (values #f #f)]
    [else
     (define close (let scan ([i open] [depth 0])
                     (cond [(>= i len) #f]
                           [(char=? (string-ref s i) #\() (scan (add1 i) (add1 depth))]
                           [(char=? (string-ref s i) #\))
                            (if (= depth 1) i (scan (add1 i) (sub1 depth)))]
                           [else (scan (add1 i) depth)])))
     (values open close)]))

(define (return-type-of s)
  (define-values (open close) (paren-range s))
  (and open close
       (let ([tail (string-trim (substring s (add1 close)))])
         (and (string-prefix? tail ":")
              (string-trim (substring tail 1))))))

;; --- module resolution -------------------------------------------------------

(define (resolve-spec spec from-file)
  (and (or (string-prefix? spec ".") (string-prefix? spec "/"))
       (let* ([dir (path-only (path->complete-path from-file))]
              [base (simplify-path (build-path dir spec) #f)]
              [base-str (path->string base)]
              [stem (cond
                      [(string-suffix? base-str ".d.ts") (substring base-str 0 (- (string-length base-str) 5))]
                      [(string-suffix? base-str ".js") (substring base-str 0 (- (string-length base-str) 3))]
                      [(string-suffix? base-str ".ts") (substring base-str 0 (- (string-length base-str) 3))]
                      [else base-str])]
              [candidates (list (string-append stem ".d.ts")
                                (string-append stem ".ts")
                                (build-path stem "index.d.ts"))])
         (for/first ([c (in-list candidates)] #:when (file-exists? c)) c))))

;; Every `export class` in `file`, plus the files it re-exports from.
(define (parse-declarations file)
  (define src (strip-comments (file->string file)))
  (define classes '())
  (define reexports '())

  (for ([m (in-list (regexp-match* #rx"(export[ \t]+\\*|export[ \t]*\\{[^}]*\\})[ \t]*from[ \t]*[\"']([^\"']+)[\"']"
                                   src #:match-select values))])
    (set! reexports (cons (caddr m) reexports)))

  ;; `export declare class X<T> extends Base<T> implements I {`
  (let loop ([pos 0])
    (define m (regexp-match-positions
               #rx"(^|[\n;}])[ \t]*(export[ \t]+)?(declare[ \t]+)?(abstract[ \t]+)?class[ \t]+([A-Za-z_$][A-Za-z0-9_$]*)"
               src pos))
    (when m
      (define head-end (cdar m))
      (define name (let ([r (list-ref m 5)]) (substring src (car r) (cdr r))))
      (define-values (open close) (brace-range src head-end))
      (when (and open close)
        (define header (substring src head-end open))
        (define base
          (let ([bm (regexp-match #rx"extends[ \t]+([A-Za-z_$][A-Za-z0-9_$.]*)" header)])
            (and bm (cadr bm))))
        (define members
          (filter values (map parse-member (split-top-level (substring src (add1 open) close) #\;))))
        (set! classes (cons (ts-class name file base members) classes)))
      (loop (if (and open close) close head-end))))

  (values (reverse classes) (reverse reexports)))

;; Walk the export graph from `entry`, collecting classes by name.
(define (collect-package entry)
  (define seen (make-hash))
  (define classes (make-hash))
  (define order '())
  (let walk ([file (path->complete-path entry)])
    (define key (path->string (simplify-path file #f)))
    (unless (hash-has-key? seen key)
      (hash-set! seen key #t)
      (define-values (found reexports) (parse-declarations file))
      (for ([c (in-list found)])
        (unless (hash-has-key? classes (ts-class-name c))
          (hash-set! classes (ts-class-name c) c)
          (set! order (cons (ts-class-name c) order))))
      (for ([spec (in-list reexports)])
        (define resolved (resolve-spec spec file))
        (when resolved (walk resolved)))))
  (values classes (reverse order)))

;; --- emission ----------------------------------------------------------------

(define (kebab s)
  (define chars (string->list s))
  (define out (open-output-string))
  (for ([c (in-list chars)] [i (in-naturals)])
    (define prev (and (> i 0) (list-ref chars (sub1 i))))
    (define next (and (< (add1 i) (length chars)) (list-ref chars (add1 i))))
    ;; A digit never opens a new word: Object3D is object3d, not object3-d.
    (when (and (char-upper-case? c) prev
               (or (and (char-alphabetic? prev) (char-lower-case? prev))
                   (and (char-upper-case? prev) next (char-lower-case? next))))
      (write-char #\- out))
    (write-char (char-downcase c) out))
  (regexp-replace* #rx"-+" (string-downcase (get-output-string out)) "-"))

(define (param-name-for p index)
  (define raw (kebab (ts-param-name p)))
  (define cleaned (regexp-replace* #rx"[^a-z0-9-]" raw ""))
  (if (or (string=? cleaned "") (regexp-match? #rx"^[0-9-]" cleaned))
      (format "a~a" index)
      cleaned))

;; TS optional params have no beagle counterpart, so each prefix length becomes a
;; clause of one multi-arity defn. Overloads that share an arity keep the first.
(define (fixed-arities params)
  (define required (length (takef params (lambda (p) (not (ts-param-optional? p))))))
  (for/list ([n (in-range required (add1 (length params)))]) (take params n)))

(define (params->beagle params)
  (string-join
   (for/list ([p (in-list params)] [i (in-naturals)])
     (format "~a~a: ~a"
             (if (ts-param-rest? p) "& " "")
             (param-name-for p i)
             (let ([t (ts-type->beagle (ts-param-type p))])
               ;; A beagle rest param is typed by its element.
               (if (ts-param-rest? p) (vec-element t) t))))
   " "))

(define (vec-element t)
  (define m (regexp-match #rx"^\\(Vec (.*)\\)$" t))
  (if m (cadr m) t))

(define (arg-refs params)
  (string-join
   (for/list ([p (in-list params)] [i (in-naturals)])
     (if (ts-param-rest? p)
         (format "(js/spread ~a)" (param-name-for p i))
         (param-name-for p i)))
   " "))

;; clause: (list params ret-type body-format), body-format taking the argument list.
(define (emit-clauses name clauses)
  (define (clause-text params ret body)
    (format "[~a] -> ~a\n     ~a" (params->beagle params) ret body))
  (cond
    [(= (length clauses) 1)
     (match-define (list params ret body) (car clauses))
     (format "(js/export\n  (defn ~a [~a] -> ~a\n    ~a))\n" name (params->beagle params) ret body)]
    [else
     (string-append
      (format "(js/export\n  (defn ~a\n" name)
      (string-join
       (for/list ([c (in-list clauses)])
         (match-define (list params ret body) c)
         (format "    (~a)" (clause-text params ret body)))
       "\n")
      "))\n")]))

;; Every signature of one member name, collapsed to distinct arities. A variadic
;; signature wins outright: it already covers every arity above its prefix.
(define (member-clauses members build-params build-body)
  (define variadic (findf (lambda (m) (findf ts-param-rest? (ts-member-params m))) members))
  (define chosen
    (cond
      [variadic (list (cons (ts-member-params variadic) variadic))]
      [else
       (for*/list ([m (in-list members)]
                   [params (in-list (fixed-arities (ts-member-params m)))])
         (cons params m))]))
  (define seen (make-hash))
  (for/list ([entry (in-list chosen)]
             #:unless (hash-has-key? seen (length (car entry))))
    (hash-set! seen (length (car entry)) #t)
    (define params (car entry))
    (define m (cdr entry))
    (list (build-params params)
          (ts-type->beagle (ts-member-type m))
          (build-body params m))))

(define (group-members members kind)
  (define order '())
  (define groups (make-hash))
  (for ([m (in-list members)] #:when (eq? (ts-member-kind m) kind))
    (unless (hash-has-key? groups (ts-member-name m))
      (set! order (cons (ts-member-name m) order)))
    (hash-update! groups (ts-member-name m) (lambda (xs) (append xs (list m))) '()))
  (for/list ([name (in-list (reverse order))]) (cons name (hash-ref groups name))))

(define (emit-class c taken)
  (define cname (ts-class-name c))
  (define prefix (kebab cname))
  (define out (open-output-string))
  (define emitted-any? (box #f))
  (define (emit! name clauses)
    (define final
      (if (hash-has-key? taken name)
          (let loop ([n 2])
            (define candidate (format "~a-~a" name n))
            (if (hash-has-key? taken candidate) (loop (add1 n)) candidate))
          name))
    (hash-set! taken final #t)
    (set-box! emitted-any? #t)
    (write-string (emit-clauses final clauses) out))

  (define ctors (filter (lambda (m) (eq? (ts-member-kind m) 'constructor)) (ts-class-members c)))
  ;; A class with no declared constructor still constructs with zero arguments.
  (emit! (format "make-~a" prefix)
         (if (null? ctors)
             (list (list '() "Any" (format "(~a.)" cname)))
             (member-clauses ctors
                             values
                             (lambda (params m)
                               (if (null? params)
                                   (format "(~a.)" cname)
                                   (format "(~a. ~a)" cname (arg-refs params)))))))
  ;; The declared return of a constructor is the instance, not `this`-as-Nil.
  (void)

  (for ([group (in-list (group-members (ts-class-members c) 'method))])
    (define name (car group))
    (emit! (format "~a-~a" prefix (kebab name))
           (member-clauses (cdr group)
                           (lambda (params) (cons (ts-param "self" "any" #f #f) params))
                           (lambda (params m)
                             (if (null? params)
                                 (format "(.~a self)" name)
                                 (format "(.~a self ~a)" name (arg-refs params)))))))

  (for ([group (in-list (group-members (ts-class-members c) 'static-method))])
    (define name (car group))
    (emit! (format "~a-~a" prefix (kebab name))
           (member-clauses (cdr group)
                           values
                           (lambda (params m)
                             (if (null? params)
                                 (format "(~a/~a)" cname name)
                                 (format "(~a/~a ~a)" cname name (arg-refs params)))))))

  ;; Only primitive-typed properties are worth wrapping: an `Any` accessor buys
  ;; nothing over `(.-prop obj)`.
  (define seen-props (make-hash))
  (for ([m (in-list (ts-class-members c))]
        #:when (eq? (ts-member-kind m) 'property)
        #:unless (hash-has-key? seen-props (ts-member-name m)))
    (hash-set! seen-props (ts-member-name m) #t)
    (define bt (ts-type->beagle (ts-member-type m)))
    (when (member bt '("Float" "String" "Bool"))
      (define self-param (list (ts-param "self" "any" #f #f)))
      (emit! (format "~a-~a" prefix (kebab (ts-member-name m)))
             (list (list self-param bt (format "(.-~a self)" (ts-member-name m)))))
      (unless (ts-member-readonly? m)
        (emit! (format "set-~a-~a!" prefix (kebab (ts-member-name m)))
               (list (list (append self-param (list (ts-param "value" (ts-member-type m) #f #f)))
                           "Nil"
                           (format "(do (set! (.-~a self) value) nil)" (ts-member-name m))))))))
  (values (get-output-string out) (unbox emitted-any?)))

(define (emit-module namespace module-spec classes names)
  (define taken (make-hash))
  (define bodies '())
  (define used '())
  (for ([name (in-list names)])
    (define c (hash-ref classes name))
    (define-values (body any?) (emit-class c taken))
    (when any?
      (set! used (cons name used))
      (set! bodies (cons (format ";; --- ~a ---\n\n~a" name body) bodies))))
  (define used-names (reverse used))
  (string-append
   "#lang beagle/js\n"
   ";; GENERATED by `beagle ts-externs` — do not edit.\n"
   (format ";; ~a classes, mapped from TypeScript declarations.\n" (length used-names))
   ";; Unmappable TS shapes degrade to Any; a method lives on the class that\n"
   ";; declares it, so a subclass instance is passed to its base class wrapper.\n\n"
   (format "(ns ~a\n  (:require [~a :refer [~a]]))\n\n"
           namespace module-spec (string-join used-names " "))
   (string-join (reverse bodies) "\n")))

;; --- CLI ---------------------------------------------------------------------

(define (die msg)
  (fprintf (current-error-port) "beagle ts-externs: ~a\n" msg)
  (exit 2))

(define (usage)
  (fprintf (current-error-port)
           (string-append
            "usage: beagle ts-externs <entry.d.ts> [options]\n"
            "\n"
            "  --module SPEC   ESM specifier the wrappers import from (default: entry's package name)\n"
            "  --ns NAME       generated namespace (default: <module>.api)\n"
            "  --out FILE      write here (default: stdout)\n"
            "  --only A,B,C    only these classes (default: every exported class)\n"
            "  --list          list the classes found and exit\n"))
  (exit 2))

(define (package-name-of entry)
  (define parts (map path->string (explode-path (path->complete-path entry))))
  (define idx (let loop ([i (sub1 (length parts))])
                (cond [(< i 0) #f]
                      [(string=? (list-ref parts i) "node_modules") i]
                      [else (loop (sub1 i))])))
  (cond
    [(and idx (< (add1 idx) (length parts)))
     (define first-seg (list-ref parts (add1 idx)))
     (if (and (string-prefix? first-seg "@") (< (+ idx 2) (length parts)))
         (string-append first-seg "/" (list-ref parts (+ idx 2)))
         first-seg)]
    [else #f]))

;; `@types/three` declares the types for `three`; the wrappers must import from
;; the runtime package, never the declaration package.
(define (runtime-package-of name)
  (cond
    [(not name) #f]
    [(string-prefix? name "@types/")
     (define rest (substring name (string-length "@types/")))
     ;; @types/foo__bar is the scoped package @foo/bar.
     (if (string-contains? rest "__")
         (let ([parts (string-split rest "__")])
           (format "@~a/~a" (car parts) (cadr parts)))
         rest)]
    [else name]))

(define (run-ts-externs args)
  (when (null? args) (usage))
  (define entry (car args))
  (unless (file-exists? entry) (die (format "no such file: ~a" entry)))
  (define module-spec (box #f))
  (define namespace (box #f))
  (define out-file (box #f))
  (define only (box #f))
  (define list-only? (box #f))
  (let loop ([rest (cdr args)])
    (match rest
      ['() (void)]
      [(list* "--module" v more) (set-box! module-spec v) (loop more)]
      [(list* "--ns" v more) (set-box! namespace v) (loop more)]
      [(list* "--out" v more) (set-box! out-file v) (loop more)]
      [(list* "--only" v more) (set-box! only (string-split v ",")) (loop more)]
      [(list* "--list" more) (set-box! list-only? #t) (loop more)]
      [_ (usage)]))

  (define-values (classes order) (collect-package entry))
  (when (unbox list-only?)
    (for ([name (in-list order)])
      (define c (hash-ref classes name))
      (printf "~a~a (~a members)\n" name
              (if (ts-class-base c) (format " extends ~a" (ts-class-base c)) "")
              (length (ts-class-members c))))
    (printf "\n~a classes\n" (length order))
    (exit 0))

  (define selected
    (cond
      [(unbox only)
       (for ([name (in-list (unbox only))])
         (unless (hash-has-key? classes name)
           (die (format "class not found in the declarations: ~a" name))))
       (filter (lambda (n) (member n (unbox only))) order)]
      [else order]))
  (when (null? selected) (die "no exported classes found"))

  (define spec (or (unbox module-spec)
                   (runtime-package-of (package-name-of entry))
                   (die "cannot infer the runtime package; pass --module SPEC")))
  (define ns (or (unbox namespace)
                 (format "~a.api" (regexp-replace* #rx"[@/]" (regexp-replace* #rx"^@" spec "") "."))))
  (define text (emit-module ns spec classes selected))
  (cond
    [(unbox out-file)
     (make-parent-directory* (unbox out-file))
     (display-to-file text (unbox out-file) #:exists 'replace)
     (fprintf (current-error-port) "beagle ts-externs: ~a classes -> ~a\n" (length selected) (unbox out-file))]
    [else (display text)]))

#lang racket/base

;; Babashka-runtime stdlib entries: the built-in libraries a bb-targeted
;; CLI reaches for — babashka.fs / babashka.process / babashka.http-client,
;; cheshire (JSON), clj-yaml (YAML), babashka.cli + clojure.tools.cli
;; (args), and java.time statics + instance methods.
;;
;; Typing policy: precise where the signature is genuinely stable
;; (String/Bool/Int positions), Any where bb returns heterogeneous maps
;; (process results, HTTP responses, parsed JSON/YAML). The value of an
;; entry is existence + arity + the precise positions; an Any here is a
;; deliberate shallow type, not a TODO.
;;
;; Merged into the clj-target stdlib (stdlib-types.rkt).

(require "types.rkt"
         "stdlib-helpers.rkt")

(define STDLIB-BB
  (hash
   ;; --- babashka.fs ---------------------------------------------------------
   'babashka.fs/exists?          (fn-of '(Any) 'Bool)
   'babashka.fs/directory?       (fn-of '(Any) 'Bool)
   'babashka.fs/regular-file?    (fn-of '(Any) 'Bool)
   'babashka.fs/hidden?          (fn-of '(Any) 'Bool)
   'babashka.fs/readable?        (fn-of '(Any) 'Bool)
   'babashka.fs/writable?        (fn-of '(Any) 'Bool)
   'babashka.fs/relative?        (fn-of '(Any) 'Bool)
   'babashka.fs/absolute?        (fn-of '(Any) 'Bool)
   'babashka.fs/list-dir         (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.fs/glob             (fn-of '(Any String) 'Any #:rest 'Any)
   'babashka.fs/match            (fn-of '(Any String) 'Any #:rest 'Any)
   'babashka.fs/walk-file-tree   (fn-of '(Any Any) 'Any)
   'babashka.fs/file-name        (fn-of '(Any) 'String)
   'babashka.fs/parent           (fn-of '(Any) 'Any)
   'babashka.fs/path             (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.fs/file             (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.fs/absolutize       (fn-of '(Any) 'Any)
   'babashka.fs/canonicalize     (fn-of '(Any) 'Any)
   'babashka.fs/relativize       (fn-of '(Any Any) 'Any)
   'babashka.fs/normalize        (fn-of '(Any) 'Any)
   'babashka.fs/expand-home      (fn-of '(Any) 'Any)
   'babashka.fs/home             (fn-of '() 'Any)
   'babashka.fs/cwd              (fn-of '() 'Any)
   'babashka.fs/extension        (fn-of '(Any) 'Any)
   'babashka.fs/strip-ext        (fn-of '(Any) 'String)
   'babashka.fs/split-ext        (fn-of '(Any) 'Any)
   'babashka.fs/components       (fn-of '(Any) 'Any)
   'babashka.fs/create-dir       (fn-of '(Any) 'Any)
   'babashka.fs/create-dirs      (fn-of '(Any) 'Any)
   'babashka.fs/create-file      (fn-of '(Any) 'Any)
   'babashka.fs/create-temp-dir  (fn-of '() 'Any #:rest 'Any)
   'babashka.fs/temp-dir         (fn-of '() 'Any)
   'babashka.fs/delete           (fn-of '(Any) 'Nil)
   'babashka.fs/delete-if-exists (fn-of '(Any) 'Bool)
   'babashka.fs/delete-tree      (fn-of '(Any) 'Nil)
   'babashka.fs/copy             (fn-of '(Any Any) 'Any #:rest 'Any)
   'babashka.fs/copy-tree        (fn-of '(Any Any) 'Any #:rest 'Any)
   'babashka.fs/move             (fn-of '(Any Any) 'Any #:rest 'Any)
   'babashka.fs/which            (fn-of '(Any) 'Any)
   'babashka.fs/last-modified-time (fn-of '(Any) 'Any)
   'babashka.fs/modified-since   (fn-of '(Any Any) 'Any)
   'babashka.fs/size             (fn-of '(Any) 'Int)
   'babashka.fs/read-all-lines   (fn-of '(Any) 'Any)
   'babashka.fs/unixify          (fn-of '(Any) 'String)
   ;; --- babashka.process ----------------------------------------------------
   ;; shell/sh return the process map {:exit :out :err ...}.
   'babashka.process/shell       (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.process/sh          (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.process/process     (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.process/check       (fn-of '(Any) 'Any)
   'babashka.process/exec        (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.process/destroy     (fn-of '(Any) 'Any)
   'babashka.process/destroy-tree (fn-of '(Any) 'Any)
   'babashka.process/alive?      (fn-of '(Any) 'Bool)
   'babashka.process/tokenize    (fn-of '(String) 'Any)
   ;; --- babashka.http-client --------------------------------------------------
   ;; Responses are maps {:status :body :headers ...}.
   'babashka.http-client/get     (fn-of '(String) 'Any #:rest 'Any)
   'babashka.http-client/post    (fn-of '(String) 'Any #:rest 'Any)
   'babashka.http-client/put     (fn-of '(String) 'Any #:rest 'Any)
   'babashka.http-client/delete  (fn-of '(String) 'Any #:rest 'Any)
   'babashka.http-client/patch   (fn-of '(String) 'Any #:rest 'Any)
   'babashka.http-client/head    (fn-of '(String) 'Any #:rest 'Any)
   'babashka.http-client/request (fn-of '(Any) 'Any)
   ;; --- cheshire (JSON) -------------------------------------------------------
   'cheshire.core/generate-string (fn-of '(Any) 'String #:rest 'Any)
   'cheshire.core/parse-string    (fn-of '(String) 'Any #:rest 'Any)
   'cheshire.core/generate-stream (fn-of '(Any Any) 'Any #:rest 'Any)
   'cheshire.core/parse-stream    (fn-of '(Any) 'Any #:rest 'Any)
   'cheshire.core/encode          (fn-of '(Any) 'String #:rest 'Any)
   'cheshire.core/decode          (fn-of '(String) 'Any #:rest 'Any)
   ;; --- clj-yaml (YAML) -------------------------------------------------------
   'clj-yaml.core/parse-string    (fn-of '(String) 'Any #:rest 'Any)
   'clj-yaml.core/generate-string (fn-of '(Any) 'String #:rest 'Any)
   'clj-yaml.core/parse-stream    (fn-of '(Any) 'Any #:rest 'Any)
   ;; --- babashka.cli / clojure.tools.cli (args) -------------------------------
   'babashka.cli/parse-opts      (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.cli/parse-args      (fn-of '(Any) 'Any #:rest 'Any)
   'babashka.cli/dispatch        (fn-of '(Any Any) 'Any #:rest 'Any)
   'babashka.cli/format-opts     (fn-of '(Any) 'String)
   'clojure.tools.cli/parse-opts (fn-of '(Any Any) 'Any #:rest 'Any)
   ;; --- java.time statics ------------------------------------------------------
   'LocalDate/parse              (fn-of '(Any) 'Any #:rest 'Any)
   'LocalDate/now                (fn-of '() 'Any)
   'LocalDate/of                 (fn-of '(Int Int Int) 'Any)
   'LocalDateTime/now            (fn-of '() 'Any)
   'LocalDateTime/parse          (fn-of '(Any) 'Any #:rest 'Any)
   'LocalTime/now                (fn-of '() 'Any)
   'ZonedDateTime/now            (fn-of '() 'Any)
   'ZoneId/of                    (fn-of '(String) 'Any)
   'ZoneId/systemDefault         (fn-of '() 'Any)
   'Duration/between             (fn-of '(Any Any) 'Any)
   'Duration/ofDays              (fn-of '(Int) 'Any)
   'Duration/ofHours             (fn-of '(Int) 'Any)
   'Duration/ofMinutes           (fn-of '(Int) 'Any)
   'Period/between               (fn-of '(Any Any) 'Any)
   'ChronoUnit/DAYS              (p 'Any)
   'ChronoUnit/HOURS             (p 'Any)
   'ChronoUnit/MINUTES           (p 'Any)
   'DateTimeFormatter/ofPattern  (fn-of '(String) 'Any)
   'DateTimeFormatter/ISO_LOCAL_DATE (p 'Any)
   'DateTimeFormatter/ISO_DATE   (p 'Any)
   ;; --- java.time instance methods ---------------------------------------------
   '.plusDays    (fn-of '(Any Int) 'Any)
   '.minusDays   (fn-of '(Any Int) 'Any)
   '.plusWeeks   (fn-of '(Any Int) 'Any)
   '.minusWeeks  (fn-of '(Any Int) 'Any)
   '.plusMonths  (fn-of '(Any Int) 'Any)
   '.minusMonths (fn-of '(Any Int) 'Any)
   '.plusYears   (fn-of '(Any Int) 'Any)
   '.minusYears  (fn-of '(Any Int) 'Any)
   '.isBefore    (fn-of '(Any Any) 'Bool)
   '.isAfter     (fn-of '(Any Any) 'Bool)
   '.isEqual     (fn-of '(Any Any) 'Bool)
   '.getYear     (fn-of '(Any) 'Int)
   '.getMonthValue (fn-of '(Any) 'Int)
   '.getDayOfMonth (fn-of '(Any) 'Int)
   '.getDayOfYear  (fn-of '(Any) 'Int)
   '.getDayOfWeek  (fn-of '(Any) 'Any)
   '.atStartOfDay  (fn-of '(Any) 'Any)
   '.toLocalDate   (fn-of '(Any) 'Any)
   '.toLocalDateTime (fn-of '(Any) 'Any)
   '.toEpochMilli  (fn-of '(Any) 'Int)
   '.toEpochDay    (fn-of '(Any) 'Int)
   '.until         (fn-of '(Any Any) 'Any #:rest 'Any)
   '.between       (fn-of '(Any Any Any) 'Any)
   '.toDays        (fn-of '(Any) 'Int)
   '.toHours       (fn-of '(Any) 'Int)
   '.toMinutes     (fn-of '(Any) 'Int)
   '.getSeconds    (fn-of '(Any) 'Int)
   ))

(provide STDLIB-BB)

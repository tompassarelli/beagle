#lang racket/base

(require rackunit
         racket/file
         racket/string
         racket/set
         racket/runtime-path
         json
         beagle/private/types
         beagle/private/nixos-schema
         beagle/private/validate-nix)

;; ============================================================================
;; Schema loading — both field name formats
;; ============================================================================

(define-runtime-path fixtures-dir "fixtures")

(define (make-temp-schema entries)
  (define tmp (make-temporary-file "schema-~a.json"))
  (call-with-output-file tmp
    (lambda (out) (write-json entries out))
    #:exists 'truncate/replace)
  tmp)

(test-case "load-nixos-schema reads 'p' field format"
  (define path (make-temp-schema
    (list (hasheq 'p "boot.loader.grub.enable" 't "bool")
          (hasheq 'p "boot.loader.grub.device" 't "str"))))
  (define schema (load-nixos-schema path))
  (check-equal? (hash-count (nixos-schema-table schema)) 2)
  (check-true (hash? (nixos-option-lookup schema "boot.loader.grub.enable")))
  (delete-file path))

(test-case "load-nixos-schema reads 'name' field format (HM style)"
  (define path (make-temp-schema
    (list (hasheq 'name "programs.git.enable" 't "bool")
          (hasheq 'name "programs.git.userName" 't "str"))))
  (define schema (load-nixos-schema path))
  (check-equal? (hash-count (nixos-schema-table schema)) 2)
  (check-true (hash? (nixos-option-lookup schema "programs.git.enable")))
  (delete-file path))

;; ============================================================================
;; Wildcard lookup
;; ============================================================================

(test-case "wildcard lookup resolves <name> patterns"
  (define path (make-temp-schema
    (list (hasheq 'p "services.nginx.virtualHosts.<name>.forceSSL" 't "bool"))))
  (define schema (load-nixos-schema path))
  (check-true (hash? (nixos-option-lookup/wildcard schema
    "services.nginx.virtualHosts.mysite.forceSSL")))
  (delete-file path))

(test-case "permissive parent stops lookup (attrsOf)"
  (define path (make-temp-schema
    (list (hasheq 'p "services.samba.settings" 't "attrsOf"
                  'inner (hasheq 't "str")))))
  (define schema (load-nixos-schema path))
  (check-equal? (nixos-option-lookup/wildcard schema
    "services.samba.settings.workgroup")
    'permissive)
  (delete-file path))

(test-case "permissive parent — dagOf (HM activation scripts)"
  (define path (make-temp-schema
    (list (hasheq 'name "home.activation" 't "dagOf"
                  'inner (hasheq 't "str")))))
  (define schema (load-nixos-schema path))
  (check-equal? (nixos-option-lookup/wildcard schema
    "home.activation.cloneDoomEmacs")
    'permissive)
  (delete-file path))

(test-case "permissive parent — nullOr nixpkgs-config"
  (define path (make-temp-schema
    (list (hasheq 'name "nixpkgs.config" 't "nullOr"
                  'inner (hasheq 't "nixpkgs-config")))))
  (define schema (load-nixos-schema path))
  (check-equal? (nixos-option-lookup/wildcard schema
    "nixpkgs.config.allowUnfree")
    'permissive)
  (delete-file path))

;; ============================================================================
;; Type checking
;; ============================================================================

(test-case "bool option rejects string value"
  (define entry (hasheq 't "bool"))
  (define result (nixos-check-value-type entry (type-prim 'String)))
  (check-true (and (pair? result) (eq? (car result) 'mismatch))))

(test-case "str option accepts string value"
  (define entry (hasheq 't "str"))
  (check-equal? (nixos-check-value-type entry (type-prim 'String)) 'ok))

(test-case "permissive type always accepts"
  (define entry (hasheq 't "submodule"))
  (check-equal? (nixos-check-value-type entry (type-prim 'Int)) 'ok))

(test-case "nullOr inner type checked"
  (define entry (hasheq 't "nullOr" 'inner (hasheq 't "bool")))
  (check-equal? (nixos-check-value-type entry (type-prim 'Bool)) 'ok)
  (check-equal? (nixos-check-value-type entry (type-prim 'Nil)) 'ok)
  (define bad (nixos-check-value-type entry (type-prim 'String)))
  (check-true (and (pair? bad) (eq? (car bad) 'mismatch))))

;; ============================================================================
;; Did-you-mean
;; ============================================================================

(test-case "find-similar returns close matches"
  (define path (make-temp-schema
    (list (hasheq 'p "programs.git.enable" 't "bool")
          (hasheq 'p "programs.git.userName" 't "str")
          (hasheq 'p "programs.git.userEmail" 't "str"))))
  (define schema (load-nixos-schema path))
  (define suggestions (nixos-find-similar schema "programs.git.userNam"))
  (check-not-false (member "programs.git.userName" suggestions))
  (delete-file path))

;; ============================================================================
;; HM schema file discovery
;; ============================================================================

(test-case "find-hm-schema-json locates schema-hm.json"
  (define tmp-dir (make-temporary-directory))
  (define cache-dir (build-path tmp-dir ".beagle-cache"))
  (make-directory cache-dir)
  (define hm-path (build-path cache-dir "schema-hm.json"))
  (call-with-output-file hm-path
    (lambda (out) (write-json (list (hasheq 'name "home.enable" 't "bool")) out)))
  (define dummy-file (build-path tmp-dir "test.bnix"))
  (call-with-output-file dummy-file (lambda (out) (display "" out)))
  (check-true (path? (find-hm-schema-json (path->string dummy-file))))
  (delete-directory/files tmp-dir))

(test-case "find-hm-schema-json returns #f when no schema-hm.json"
  (define tmp-dir (make-temporary-directory))
  (define dummy-file (build-path tmp-dir "test.bnix"))
  (call-with-output-file dummy-file (lambda (out) (display "" out)))
  (check-false (find-hm-schema-json (path->string dummy-file)))
  (delete-directory/files tmp-dir))

;; ============================================================================
;; Full validation with HM schema
;; ============================================================================

(test-case "validate-file-keys uses HM schema for HM-rooted paths"
  (define nixos-path (make-temp-schema
    (list (hasheq 'p "boot.loader.grub.enable" 't "bool"))))
  (define hm-path (make-temp-schema
    (list (hasheq 'name "programs.git.enable" 't "bool")
          (hasheq 'name "programs.git.userName" 't "str"))))
  (define nixos-schema (load-nixos-schema nixos-path))
  (define hm-schema (load-nixos-schema hm-path))

  (define fk-nixos (found-key "boot.loader.grub.enable" 'true ':boot.loader.grub.enable 0))
  (define fk-hm (found-key "programs.git.enable" 'true ':programs.git.enable 0))
  (define fk-unknown (found-key "programs.git.typo" 'true ':programs.git.typo 0))

  (define errs-nixos (validate-file-keys "/dev/null" (list fk-nixos) nixos-schema #:hm-schema hm-schema))
  (check-equal? (length errs-nixos) 0 "valid NixOS option should pass")

  (define errs-hm (validate-file-keys "/dev/null" (list fk-hm) nixos-schema #:hm-schema hm-schema))
  (check-equal? (length errs-hm) 0 "valid HM option should pass")

  (define errs-unknown (validate-file-keys "/dev/null" (list fk-unknown) nixos-schema #:hm-schema hm-schema))
  (check-equal? (length errs-unknown) 1 "unknown HM option should error")
  (check-true (string-contains? (validation-error-message (car errs-unknown)) "unknown HM option"))

  (delete-file nixos-path)
  (delete-file hm-path))

(test-case "HM paths silently skipped when no HM schema available"
  (define nixos-path (make-temp-schema
    (list (hasheq 'p "boot.loader.grub.enable" 't "bool"))))
  (define nixos-schema (load-nixos-schema nixos-path))

  (define fk-hm (found-key "programs.git.enable" 'true ':programs.git.enable 0))
  (define errs (validate-file-keys "/dev/null" (list fk-hm) nixos-schema))
  (check-equal? (length errs) 0 "HM path should be silently skipped without HM schema")

  (delete-file nixos-path))

;; ============================================================================
;; myConfig introspective validation
;; ============================================================================

(test-case "collect-myconfig-declarations extracts options.myConfig paths"
  (define decl1 (found-key "options.myConfig.modules.git.enable" 'true ':options.myConfig.modules.git.enable 0))
  (define decl2 (found-key "options.myConfig.modules.kanata.port" 'true ':options.myConfig.modules.kanata.port 0))
  (define non-decl (found-key "boot.loader.grub.enable" 'true ':boot.loader.grub.enable 0))
  (define all-file-keys (list (cons "/a.bnix" (list decl1 non-decl))
                              (cons "/b.bnix" (list decl2))))
  (define declared (collect-myconfig-declarations all-file-keys))
  (check-equal? (set-count declared) 2)
  (check-true (set-member? declared "myConfig.modules.git.enable"))
  (check-true (set-member? declared "myConfig.modules.kanata.port"))
  (check-false (set-member? declared "boot.loader.grub.enable")))

(test-case "myConfig usage of declared option passes"
  (define decl (found-key "options.myConfig.modules.git.enable" 'true ':options.myConfig.modules.git.enable 0))
  (define usage (found-key "myConfig.modules.git.enable" 'true ':myConfig.modules.git.enable 0))
  (define all-file-keys (list (cons "/decl.bnix" (list decl))
                              (cons "/use.bnix" (list usage))))
  (define declared (collect-myconfig-declarations all-file-keys))
  (define errs (detect-myconfig-errors all-file-keys declared))
  (check-equal? (length errs) 0))

(test-case "myConfig usage of undeclared option errors"
  (define decl (found-key "options.myConfig.modules.git.enable" 'true ':options.myConfig.modules.git.enable 0))
  (define typo (found-key "myConfig.modules.gti.enable" 'true ':myConfig.modules.gti.enable 0))
  (define all-file-keys (list (cons "/decl.bnix" (list decl))
                              (cons "/use.bnix" (list typo))))
  (define declared (collect-myconfig-declarations all-file-keys))
  (define errs (detect-myconfig-errors all-file-keys declared))
  (check-equal? (length errs) 1)
  (check-true (string-contains? (validation-error-message (car errs)) "unknown myConfig option"))
  (check-true (string-contains? (validation-error-message (car errs)) "did you mean")))

(test-case "myConfig prefix of declared option passes (intermediate path)"
  (define decl (found-key "options.myConfig.modules.kanata.enable" 'true ':options.myConfig.modules.kanata.enable 0))
  (define prefix-use (found-key "myConfig.modules.kanata" 'true ':myConfig.modules.kanata 0))
  (define all-file-keys (list (cons "/decl.bnix" (list decl))
                              (cons "/use.bnix" (list prefix-use))))
  (define declared (collect-myconfig-declarations all-file-keys))
  (define errs (detect-myconfig-errors all-file-keys declared))
  (check-equal? (length errs) 0 "intermediate path prefix of a declared option should pass"))

(test-case "myConfig paths still skipped in validate-file-keys"
  (define nixos-path (make-temp-schema
    (list (hasheq 'p "boot.loader.grub.enable" 't "bool"))))
  (define nixos-schema (load-nixos-schema nixos-path))
  (define fk (found-key "myConfig.modules.git.enable" 'true ':myConfig.modules.git.enable 0))
  (define errs (validate-file-keys "/dev/null" (list fk) nixos-schema))
  (check-equal? (length errs) 0 "myConfig skipped at per-file level — validated cross-file")
  (delete-file nixos-path))

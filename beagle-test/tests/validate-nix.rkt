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

(define (write-json-file path value)
  (call-with-output-file path
    (lambda (out) (write-json value out))
    #:exists 'truncate/replace))

(define (write-bnix-file dir name body)
  (define path (build-path dir name))
  (call-with-output-file path
    (lambda (out)
      (display "#lang beagle/nix\n\n" out)
      (display body out)
      (newline out))
    #:exists 'truncate/replace)
  path)

(define (validator-count files)
  (parameterize ([current-error-port (open-output-string)])
    (validation-result-error-count (validate-files files))))

(define (make-validator-repo nixos-entries
                             #:hm [hm-entries #f]
                             #:darwin [darwin-entries #f])
  (define dir (make-temporary-directory))
  (define cache-dir (build-path dir ".beagle-cache"))
  (make-directory cache-dir)
  (write-json-file (build-path cache-dir "schema.json") nixos-entries)
  (when hm-entries
    (write-json-file (build-path cache-dir "schema-hm.json") hm-entries))
  (when darwin-entries
    (write-json-file (build-path cache-dir "schema-darwin.json") darwin-entries))
  dir)

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

(test-case "freeform-container detection follows nested attrsOf values"
  (define path
    (make-temp-schema
     (list
      (hasheq 'p "services.pipewire.wireplumber.extraConfig"
              't "attrsOf"
              'inner
              (hasheq 't "attrsOf"
                      'inner
                      (hasheq 't "nullOr"
                              'inner
                              (hasheq 't "attrsOf"
                                      'inner (hasheq 't "either")))))
      (hasheq 'p "home-manager.users"
              't "attrsOf"
              'inner (hasheq 't "submodule")))))
  (define schema (load-nixos-schema path))
  (check-true
   (nixos-option-freeform-container?
    schema "services.pipewire.wireplumber.extraConfig"))
  (check-false
   (nixos-option-freeform-container? schema "home-manager.users"))
  (delete-file path))

(test-case "implicit HM settings fallback is scoped to a known module namespace"
  (define path
    (make-temp-schema
     (list (hasheq 'name "programs.ghostty.enable" 't "bool")
           (hasheq 'name "programs.ghostty.package" 't "package")
           (hasheq 'name "programs.git.enable" 't "bool"))))
  (define schema (load-nixos-schema path))
  (check-true
   (nixos-implicit-settings-path?
    schema "programs.ghostty.settings.window-padding-x"))
  (check-false
   (nixos-implicit-settings-path? schema "programs.ghostty.typo"))
  (check-false
   (nixos-implicit-settings-path?
    schema "programs.unknown.settings.window-padding-x"))
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

(test-case "find-darwin-schema-json locates schema-darwin.json"
  (define tmp-dir (make-temporary-directory))
  (define cache-dir (build-path tmp-dir ".beagle-cache"))
  (make-directory cache-dir)
  (define darwin-path (build-path cache-dir "schema-darwin.json"))
  (write-json-file
   darwin-path
   (list (hasheq 'name "system.stateVersion" 't "intBetween")))
  (define dummy-file (build-path tmp-dir "test.bnix"))
  (call-with-output-file dummy-file (lambda (out) (display "" out)))
  (check-true
   (path? (find-darwin-schema-json (path->string dummy-file))))
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

(test-case "HM freeform settings accept Ghostty and Mako values but reject siblings"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "boot.loader.grub.enable" 't "bool"))
     #:hm
     (list (hasheq 'name "programs.ghostty.enable" 't "bool")
           (hasheq 'name "programs.ghostty.package" 't "package")
           (hasheq 'name "services.mako.enable" 't "bool")
           (hasheq 'name "services.mako.extraConfig" 't "lines"))))
  (define settings-file
    (write-bnix-file
     dir "settings.bnix"
     #<<BNIX
(ns settings)
(def config-value
  {:programs.ghostty
    {:settings
      {:window-padding-x 6
       :window-padding-y 4
       :app-notifications "no-clipboard-copy"
       :command "/run/current-system/sw/bin/bash"
       :working-directory "home"}}
   :services.mako
    {:settings
      {:default-timeout 0
       :icons 0}}})
BNIX
     ))
  (check-equal? (validator-count (list settings-file)) 0)

  (define typo-file
    (write-bnix-file
     dir "hm-typo.bnix"
     "(ns hm-typo)\n(def config-value {:programs.ghostty.typo true})"))
  (check-equal? (validator-count (list typo-file)) 1)
  (delete-directory/files dir))

(test-case "freeform schema context suppresses dotted literal keys only inside it"
  (define dir
    (make-validator-repo
     (list
      (hasheq 'name "services.pipewire.wireplumber.extraConfig"
              't "attrsOf"
              'inner
              (hasheq 't "attrsOf"
                      'inner
                      (hasheq 't "nullOr"
                              'inner
                              (hasheq 't "attrsOf"
                                      'inner (hasheq 't "either"))))))))
  (define freeform-file
    (write-bnix-file
     dir "freeform.bnix"
     #<<BNIX
(ns freeform)
(def config-value
  {:services.pipewire.wireplumber.extraConfig
    {"50-laptop-mic"
      {"monitor.alsa.rules"
        [{:matches [{"device.name" "alsa_card.pci-0000_c1_00.6"}]
          :actions
           {:update-props
             {"device.profile" "HiFi (Mic1, Mic2, Speaker)"}}}]}}})
BNIX
     ))
  (check-equal? (validator-count (list freeform-file)) 0)

  (define suspicious-file
    (write-bnix-file
     dir "suspicious.bnix"
     "(ns suspicious)\n(def config-value {\"wrong.attributepath\" 1})"))
  (check-equal? (validator-count (list suspicious-file)) 1)
  (delete-directory/files dir))

(test-case "mixed-platform flake accepts Darwin stateVersion without cross-file conflict"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "system.stateVersion" 't "str")
           (hasheq 'name "services.demo.port" 't "int"))
     #:darwin
     (list (hasheq 'name "system.stateVersion" 't "intBetween"))))
  (define flake-file
    (write-bnix-file
     dir "flake.bnix"
     "(ns flake)\n(def darwin-config {:system.stateVersion 6})"))
  (define system-file
    (write-bnix-file
     dir "system.bnix"
     "(ns system)\n(def nixos-config {:system.stateVersion \"25.05\"})"))
  (check-equal? (validator-count (list flake-file system-file)) 0)

  (define invalid-nixos-file
    (write-bnix-file
     dir "invalid-nixos.bnix"
     "(ns invalid-nixos)\n(def nixos-config {:system.stateVersion 6})"))
  (check-equal? (validator-count (list invalid-nixos-file)) 1)

  (define ordinary-a
    (write-bnix-file
     dir "ordinary-a.bnix"
     "(ns ordinary-a)\n(def config-a {:services.demo.port 1})"))
  (define ordinary-b
    (write-bnix-file
     dir "ordinary-b.bnix"
     "(ns ordinary-b)\n(def config-b {:services.demo.port 2})"))
  (check-equal? (validator-count (list ordinary-a ordinary-b)) 1)
  (delete-directory/files dir))

(test-case "ordinary NixOS unknown paths still reject"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "boot.loader.grub.enable" 't "bool"))
     #:hm (list (hasheq 'name "programs.git.enable" 't "bool"))))
  (define source-file
    (write-bnix-file
     dir "ordinary-typo.bnix"
     "(ns ordinary-typo)\n(def config-value {:boot.loader.grub.enabel true})"))
  (check-equal? (validator-count (list source-file)) 1)
  (delete-directory/files dir))

(test-case "parsed validation reports missing required schema"
  (define dir (make-temporary-directory))
  (define source-file
    (write-bnix-file
     dir "missing-schema.bnix"
     "(ns missing-schema)\n(def config-value {:services.demo.enable true})"))
  (define result (validate-files (list source-file)))
  (check-equal? (validation-result-error-count result) 1)
  (check-eq? (validation-error-kind (car (validation-result-errors result)))
             'missing-schema)
  (delete-directory/files dir))

(test-case "schema-free Nix source skips option schema preflight"
  (define dir (make-temporary-directory))
  (define source-file
    (write-bnix-file
     dir "ordinary-program.bnix"
     "(ns ordinary-program)\n(def answer Int 42)"))
  (define result (validate-files (list source-file)))
  (check-equal? (validation-result-error-count result) 0)
  (check-false (validation-result-schema result))
  (delete-directory/files dir))

(test-case "unknown option result preserves nearest suggestion"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "services.openssh.enable" 't "bool"))))
  (define source-file
    (write-bnix-file
     dir "suggestion.bnix"
     "(ns suggestion)\n(def config-value {:services.openssh.enabl true})"))
  (define result (validate-files (list source-file)))
  (check-equal? (validation-result-error-count result) 1)
  (check-true
   (string-contains?
    (validation-error-message (car (validation-result-errors result)))
    "services.openssh.enable"))
  (delete-directory/files dir))

(test-case "Nix validation walks option keys inside binding constraints"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "services.demo.enable" 't "bool"))))
  (define source-file
    (write-bnix-file
     dir "constraint-option-typo.bnix"
     (string-append
      "(ns constraint-option-typo)\n"
      "(defn guarded [(value Int (fn [(candidate Int)] Bool "
      "(do {:services.demo.enabel true} (> candidate 0))))] Int value)")))
  (check-equal? (validator-count (list source-file)) 1)
  (delete-directory/files dir))

(test-case "Nix validation walks protocol, implementation, and letfn constraints"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "services.demo.enable" 't "bool"))))
  (define source-file
    (write-bnix-file
     dir "declaration-constraint-option-typos.bnix"
     #<<BNIX
(ns declaration-constraint-option-typos)
(defprotocol Checked
  (check-value
    [(value String
       (fn [(candidate String)] Bool
         (do {:services.demo.protocol-typo true} true)))]
    Bool))
(extend-type String
  Checked
  (check-value
    [(value String
       (fn [(candidate String)] Bool
         (do {:services.demo.implementation-typo true} true)))]
    Bool
    true))
(def result
  (letfn [(accept
            [(value Int
               (fn [(candidate Int)] Bool
                 (do {:services.demo.letfn-typo true} true)))]
            Int
            value)]
    (accept 1)))
BNIX
     ))
  (check-equal? (validator-count (list source-file)) 3)
  (delete-directory/files dir))

(test-case "Nix validation walks map-destructuring defaults in incoming scope"
  (define dir
    (make-validator-repo
     (list (hasheq 'name "services.demo.enable" 't "bool"))))
  (define source-file
    (write-bnix-file
     dir "destructuring-default-option-typo.bnix"
     (string-append
      "(ns destructuring-default-option-typo)\n"
      "(defn unpack "
      "[({:keys [value] :or {value (do {:services.demo.default-typo true} 1)}} "
      "  (Map Keyword Int))] "
      "Int value)")))
  (check-equal? (validator-count (list source-file)) 1)
  (delete-directory/files dir))

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

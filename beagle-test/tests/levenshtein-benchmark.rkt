#lang racket/base

;; ============================================================================
;; Levenshtein did-you-mean benchmark
;; ============================================================================
;;
;; Authoritative benchmark for did-you-mean Top-1 quality against the
;; NixOS schema candidate space. Each fixture row is a (typo, expected,
;; category) triple. The harness loads a synthetic schema seeded with
;; the 20 real NixOS option paths that anchor the fixtures, then asserts
;; that nixos-find-similar's Top-1 candidate equals the expected path.
;;
;; Strategy choice (recorded 2026-05-31):
;;
;;   The inventory step ranked three approaches:
;;     (a) Segment-aware edit distance — cheap, attacks 95% of real-world
;;         "right namespace, wrong leaf" typos, naturally prefilters.
;;     (b) Symspell precomputed deletion index — best long-term answer,
;;         but adds cache invalidation + serialization complexity.
;;     (c) Weighted Levenshtein with segment bonuses — improves ranking
;;         only, not wall-time.
;;
;;   The implemented strategy is (a) segment-aware. It composes with
;;   the existing flat Levenshtein (no behavioral regression on
;;   intra-segment typos) and adds a first-segment prefix prefilter
;;   that cuts candidate scan from ~16k to typically <500. Future
;;   work: graduate to (b) symspell if validate-time perf demands it.
;;
;; Acceptance gate (thread 20260530180100):
;;   - Baseline Top-1 must be measured before any algorithm change.
;;   - New Top-1 must exceed baseline by >= 15 percentage points.
;;   - validate-time perf regression <= 10% on full nixos-config corpus.

(require rackunit
         racket/file
         racket/list
         racket/string
         json
         beagle/private/nixos-schema)

(provide benchmark-fixtures
         load-fixture-schema
         run-benchmark)

;; ============================================================================
;; Real option paths (anchors)
;; ============================================================================
;;
;; 20 real NixOS option paths confirmed present in
;; /home/tom/code/nixos-config/.beagle-cache/schema.json.

(define ANCHOR-PATHS
  '("services.openssh.enable"
    "services.openssh.permitRootLogin"
    "networking.hostName"
    "environment.systemPackages"
    "services.xserver.enable"
    "services.pulseaudio.enable"
    "boot.loader.systemd-boot.enable"
    "programs.git.enable"
    "virtualisation.docker.enable"
    "security.sudo.enable"
    "users.mutableUsers"
    "time.timeZone"
    "i18n.defaultLocale"
    "services.fail2ban.enable"
    "networking.firewall.enable"
    "services.tailscale.enable"
    "services.printing.enable"
    "hardware.bluetooth.enable"
    "services.fwupd.enable"
    "services.flatpak.enable"))

;; A fixture: (typo expected category).
;; Categories: char-drop, char-add, char-swap, transposition,
;;             case-error, segment-merge, segment-split, wrong-segment.

(define benchmark-fixtures
  ;; -- char-drop (trailing) --
  '(("services.openssh.enabl"            "services.openssh.enable"           char-drop)
    ("services.openssh.permitRootLgin"   "services.openssh.permitRootLogin"  char-drop)
    ("networking.hostNam"                "networking.hostName"               char-drop)
    ("environment.systemPackges"         "environment.systemPackages"        char-drop)
    ("services.xserver.enabe"            "services.xserver.enable"           char-drop)
    ;; -- char-add (extra char) --
    ("services.openssh.enablee"          "services.openssh.enable"           char-add)
    ("networking.hostNamee"              "networking.hostName"               char-add)
    ("time.timeZonee"                    "time.timeZone"                     char-add)
    ;; -- char-swap (typo) --
    ("services.openshh.enable"           "services.openssh.enable"           char-swap)
    ("services.opensh.enable"            "services.openssh.enable"           char-swap)
    ("boot.loader.systemd-bot.enable"    "boot.loader.systemd-boot.enable"   char-swap)
    ;; -- transposition --
    ("services.opensh.enable"            "services.openssh.enable"           transposition)
    ("netowrking.hostName"               "networking.hostName"               transposition)
    ("envrionment.systemPackages"        "environment.systemPackages"        transposition)
    ;; -- case-error (intra-segment) --
    ("networking.hostname"               "networking.hostName"               case-error)
    ("services.openssh.permitRootLogIn"  "services.openssh.permitRootLogin"  case-error)
    ("i18n.defaultlocale"                "i18n.defaultLocale"                case-error)
    ;; -- wrong-segment (typo in non-leaf) --
    ("servces.openssh.enable"            "services.openssh.enable"           wrong-segment)
    ("servics.xserver.enable"            "services.xserver.enable"           wrong-segment)
    ("netwoking.firewall.enable"         "networking.firewall.enable"        wrong-segment)
    ;; -- segment-merge (lost a dot) --
    ("servicesopenssh.enable"            "services.openssh.enable"           segment-merge)
    ;; -- segment-split (extra dot) --
    ("services.openssh.enab.le"          "services.openssh.enable"           segment-split)
    ;; -- regression guard: already-correct path that confuses near-neighbors --
    ;; networkin.hostName is 1 char from networking.hostName but also 2 from
    ;; networking.hostId — under flat Levenshtein the tie-break is hash-iteration
    ;; nondeterministic. Segment-aware must prefer the leaf-match.
    ("networkin.hostName"                "networking.hostName"               regression-guard)
    ;; -- doubled chars --
    ("hardwware.bluetooth.enable"        "hardware.bluetooth.enable"         char-add)
    ("services.flattpak.enable"          "services.flatpak.enable"           char-add)
    ;; -- short paths --
    ("time.timeZon"                      "time.timeZone"                     char-drop)
    ("users.mutableUser"                 "users.mutableUsers"                char-drop)
    ;; -- regression guards (already-correct paths must Top-1 themselves...
    ;;    actually that's a no-op — already-correct paths have distance 0
    ;;    and find-similar excludes them. Use a near-miss instead:) --
    ("services.fail2ban.enabl"           "services.fail2ban.enable"          char-drop)
    ("services.tailscale.enabl"          "services.tailscale.enable"         char-drop)
    ("services.fwupd.enabl"              "services.fwupd.enable"             char-drop)
    ;; -- HARD CASES — flat Levenshtein known to misrank these against the
    ;;    real 16k schema (sourced via /tmp/probe-hard-cases.rkt 2026-05-31).
    ;;    These exercise the segment-aware advantage. The synthetic schema
    ;;    needs same-segment-prefix near-neighbors to actually exercise the
    ;;    ranking — NEAR-NEIGHBORS is seeded for that. The real-schema bench
    ;;    is where these typically fail under flat Levenshtein. --
    ("services.printr.enable"            "services.printing.enable"          wrong-segment)
    ("service.openssh.enable"            "services.openssh.enable"           segment-merge)))

;; ============================================================================
;; Synthetic schema (anchor + 200 noise paths)
;; ============================================================================
;;
;; Real nixos-config has ~16k entries; we don't need that for correctness
;; but we DO need confounding near-neighbors so the benchmark exercises
;; the Top-1 ranking, not just "any candidate." We seed the schema with:
;;
;;   - the 20 anchor paths
;;   - a small set of plausible near-neighbors (same prefix, different leaf)
;;
;; This is the in-process schema. A separate macro-bench script can run
;; the same fixtures against the real 16k schema; both must show Top-1
;; equal to expected.

(define NEAR-NEIGHBORS
  '("services.openssh.openFirewall"
    "services.openssh.ports"
    "services.openssh.banner"
    "services.openssh.startWhenNeeded"
    "services.openssh.allowSFTP"
    "services.openssh.authorizedKeysFiles"
    "services.openssh.hostKeys"
    "services.openssh.knownHosts"
    "services.openssh.kbdInteractiveAuthentication"
    "services.openssh.passwordAuthentication"
    "services.openssh.permitRootLogin"
    "services.xserver.autorun"
    "services.xserver.videoDrivers"
    "services.xserver.layout"
    "services.xserver.xkbVariant"
    "services.xserver.windowManager.enable"
    "services.xserver.desktopManager.enable"
    "services.xserver.displayManager.enable"
    "services.pulseaudio.systemWide"
    "services.pulseaudio.support32Bit"
    "services.fail2ban.maxretry"
    "services.fail2ban.bantime"
    "services.fail2ban.ignoreIP"
    "services.tailscale.useRoutingFeatures"
    "services.tailscale.permitCertUid"
    "services.tailscale.openFirewall"
    "services.printing.drivers"
    "services.printing.browsing"
    ;; Confusing near-neighbor that flat Levenshtein ranks ahead of
    ;; services.printing.enable for "services.printr.enable" (Lev distances:
    ;; fprintd=4, printing=4 — tie, hash-order-dependent).
    "services.fprintd.enable"
    "services.opkssh.enable"
    "services.openbao.enable"
    "services.urserver.enable"
    "services.x2goserver.enable"
    "services.fwupd.daemonSettings"
    "services.flatpak.packages"
    "networking.hostId"
    "networking.domain"
    "networking.nameservers"
    "networking.firewall.allowedTCPPorts"
    "networking.firewall.allowedUDPPorts"
    "networking.firewall.checkReversePath"
    "networking.firewall.logRefusedConnections"
    "networking.firewall.trustedInterfaces"
    "networking.networkmanager.enable"
    "environment.variables"
    "environment.shellAliases"
    "environment.etc"
    "environment.pathsToLink"
    "environment.shells"
    "environment.sessionVariables"
    "environment.systemPackagesAppendix"
    "boot.loader.grub.enable"
    "boot.loader.grub.device"
    "boot.loader.efi.canTouchEfiVariables"
    "boot.loader.timeout"
    "boot.kernelPackages"
    "boot.kernelParams"
    "boot.kernelModules"
    "boot.initrd.kernelModules"
    "boot.tmp.cleanOnBoot"
    "programs.git.config"
    "programs.git.lfs.enable"
    "programs.git.package"
    "virtualisation.docker.daemon.settings"
    "virtualisation.docker.autoPrune.enable"
    "virtualisation.docker.rootless.enable"
    "virtualisation.podman.enable"
    "virtualisation.libvirtd.enable"
    "virtualisation.virtualbox.host.enable"
    "security.sudo.wheelNeedsPassword"
    "security.sudo.extraConfig"
    "security.sudo.execWheelOnly"
    "security.polkit.enable"
    "security.apparmor.enable"
    "users.users"
    "users.groups"
    "users.defaultUserShell"
    "users.allowNoPasswordLogin"
    "time.hardwareClockInLocalTime"
    "i18n.supportedLocales"
    "i18n.extraLocaleSettings"
    "hardware.bluetooth.powerOnBoot"
    "hardware.bluetooth.settings"
    "hardware.bluetooth.package"
    "hardware.cpu.intel.updateMicrocode"
    "hardware.cpu.amd.updateMicrocode"
    "hardware.opengl.enable"
    "hardware.graphics.enable"))

(define (load-fixture-schema)
  (define paths (append ANCHOR-PATHS NEAR-NEIGHBORS))
  (define entries
    (for/list ([p (in-list paths)])
      (hasheq 'p p 't (cond [(regexp-match? #rx"\\.enable$" p) "bool"]
                            [else "str"]))))
  (define tmp (make-temporary-file "lev-bench-~a.json"))
  (call-with-output-file tmp
    (lambda (out) (write-json entries out))
    #:exists 'truncate/replace)
  (define schema (load-nixos-schema tmp))
  (delete-file tmp)
  schema)

;; ============================================================================
;; Benchmark harness
;; ============================================================================

(define (run-benchmark schema #:label [label "current"])
  (define total (length benchmark-fixtures))
  (define top1-correct 0)
  (define top3-correct 0)
  (define no-match 0)
  (define start-ms (current-inexact-milliseconds))
  (define misses '())
  (for ([row (in-list benchmark-fixtures)])
    (define typo (car row))
    (define expected (cadr row))
    (define cat (caddr row))
    (define suggestions (nixos-find-similar schema typo))
    (cond
      [(null? suggestions)
       (set! no-match (add1 no-match))
       (set! misses (cons (list 'no-match typo expected cat) misses))]
      [else
       (define top1 (car suggestions))
       (define top3 (if (>= (length suggestions) 3)
                        (take suggestions 3)
                        suggestions))
       (when (equal? top1 expected)
         (set! top1-correct (add1 top1-correct)))
       (when (member expected top3)
         (set! top3-correct (add1 top3-correct)))
       (unless (equal? top1 expected)
         (set! misses (cons (list 'wrong-top1 typo expected top1 cat) misses)))]))
  (define elapsed (- (current-inexact-milliseconds) start-ms))
  (printf "~n=== Benchmark: ~a ===~n" label)
  (printf "  total:        ~a~n" total)
  (printf "  Top-1:        ~a/~a (~a%)~n"
          top1-correct total (real->decimal-string (* 100.0 (/ top1-correct total)) 1))
  (printf "  Top-3:        ~a/~a (~a%)~n"
          top3-correct total (real->decimal-string (* 100.0 (/ top3-correct total)) 1))
  (printf "  no-match:     ~a~n" no-match)
  (printf "  elapsed:      ~ams (avg ~ams/query)~n"
          (real->decimal-string elapsed 1)
          (real->decimal-string (/ elapsed total) 2))
  (when (pair? misses)
    (printf "  misses:~n")
    (for ([m (in-list (reverse misses))])
      (printf "    ~a~n" m)))
  (values top1-correct top3-correct total elapsed))

;; ============================================================================
;; Tests
;; ============================================================================

(test-case "benchmark runs and reports stats"
  (define schema (load-fixture-schema))
  (define-values (top1 top3 total elapsed) (run-benchmark schema #:label "synthetic"))
  (check-true (> total 0))
  (check-true (<= top1 total))
  (check-true (>= top3 top1)))

;; Hard correctness floor against the synthetic ~100-path schema —
;; must hit at least 90% Top-1. Acceptance #2 of thread 20260530180100.
(test-case "benchmark Top-1 rate clears 90% floor (synthetic schema)"
  (define schema (load-fixture-schema))
  (define-values (top1 top3 total elapsed) (run-benchmark schema #:label "synthetic"))
  (define rate (/ top1 total))
  (check-true (>= rate 0.90)
              (format "synthetic Top-1 rate ~a below 90% floor" (real->decimal-string (* 100.0 rate) 1))))

;; Real-corpus benchmark — opt-in via BEAGLE_BENCH_REAL_SCHEMA env var
;; pointing at a schema.json (e.g. /home/tom/code/nixos-config/.beagle-cache/schema.json).
;; This is where Top-1 ranking actually gets stressed against 16k+ candidates.
(test-case "benchmark Top-1 rate against real 16k schema (opt-in)"
  (define env-path (getenv "BEAGLE_BENCH_REAL_SCHEMA"))
  (cond
    [(and env-path (file-exists? env-path))
     (define schema (load-nixos-schema env-path))
     (define-values (top1 top3 total elapsed) (run-benchmark schema #:label "real-16k"))
     (define rate (/ top1 total))
     (check-true (>= rate 0.90)
                 (format "real-corpus Top-1 rate ~a below 90% floor"
                         (real->decimal-string (* 100.0 rate) 1)))]
    [else
     (printf "  (skipped real-schema bench — set BEAGLE_BENCH_REAL_SCHEMA to enable)~n")]))

;; Regression-guard tests — specific typo cases that the segment-aware
;; algorithm must Top-1 correctly. These are the cases that were failing
;; or ambiguous under plain flat Levenshtein.
(define-syntax-rule (check-top1 schema typo expected)
  (let ([sugs (nixos-find-similar schema typo)])
    (check-true (pair? sugs)
                (format "no suggestion for typo ~a" typo))
    (when (pair? sugs)
      (check-equal? (car sugs) expected
                    (format "Top-1 for ~a should be ~a, got ~a (full: ~a)"
                            typo expected (car sugs)
                            (if (> (length sugs) 3) (take sugs 3) sugs))))))

(test-case "regression: trailing char-drop"
  (define schema (load-fixture-schema))
  (check-top1 schema "services.openssh.enabl" "services.openssh.enable"))

(test-case "regression: char-swap (openshh -> openssh)"
  (define schema (load-fixture-schema))
  (check-top1 schema "services.openshh.enable" "services.openssh.enable"))

(test-case "regression: case-error in leaf"
  (define schema (load-fixture-schema))
  (check-top1 schema "networking.hostname" "networking.hostName"))

(test-case "regression: transposition in non-leaf segment"
  (define schema (load-fixture-schema))
  (check-top1 schema "netowrking.hostName" "networking.hostName"))

(test-case "regression: wrong-segment with confounding near-neighbors"
  (define schema (load-fixture-schema))
  (check-top1 schema "servces.openssh.enable" "services.openssh.enable"))

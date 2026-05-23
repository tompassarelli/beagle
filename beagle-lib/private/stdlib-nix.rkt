#lang racket/base

;; Nix-specific stdlib type declarations.
;; Maps Nix builtins and lib.* functions to Beagle types.
;;
;; Higher-order combinators use `poly-fn` with forall vars (A, B, K, V, W).
;; Functions whose return type genuinely depends on dynamic shape (or where
;; modeling would mislead) stay at Any.

(require "types.rkt"
         "stdlib-helpers.rkt")

(provide STDLIB-NIX)

;; Type shorthands
(define ANY  (type-prim 'Any))
(define STR  (type-prim 'String))
(define BOOL (type-prim 'Bool))
(define INT  (type-prim 'Int))
(define NIXT (type-prim 'NixType))
(define (LIST-OF t) (type-app 'List (list (if (type? t) t (type-prim t)))))
(define (MAP-OF k v) (type-app 'Map (list (if (type? k) k (type-prim k))
                                          (if (type? v) v (type-prim v)))))

;; Convenience: take a list of symbol-or-type and a return symbol-or-type
;; and produce a type-fn.
(define (fn-of params ret)
  (type-fn (map (lambda (x) (if (type? x) x (type-prim x))) params)
           #f
           (if (type? ret) ret (type-prim ret))))

(define STDLIB-NIX
  (hash
   ;; ============================================================================
   ;; builtins.* — lists / seqs (parametric)
   ;; ============================================================================

   'builtins/length      (poly-fn '(A) (list (LIST-OF (tv 'A))) INT)
   'builtins/head        (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'builtins/tail        (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'builtins/elemAt      (poly-fn '(A) (list (LIST-OF (tv 'A)) INT) (tv 'A))
   'builtins/elem        (poly-fn '(A) (list (tv 'A) (LIST-OF (tv 'A))) BOOL)
   'builtins/map         (poly-fn '(A B)
                                  (list (type-fn (list (tv 'A)) #f (tv 'B))
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'B)))
   'builtins/filter      (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'A)))
   'builtins/foldl       (poly-fn '(A B)
                                  (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                        (tv 'B)
                                        (LIST-OF (tv 'A)))
                                  (tv 'B))
   'builtins/foldl'      (poly-fn '(A B)
                                  (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                        (tv 'B)
                                        (LIST-OF (tv 'A)))
                                  (tv 'B))
   'builtins/sort        (poly-fn '(A)
                                  (list (type-fn (list (tv 'A) (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'A)))
   'builtins/concatLists (poly-fn '(A) (list (LIST-OF (LIST-OF (tv 'A))))
                                  (LIST-OF (tv 'A)))
   'builtins/concatMap   (poly-fn '(A B)
                                  (list (type-fn (list (tv 'A)) #f (LIST-OF (tv 'B)))
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'B)))
   'builtins/genList     (poly-fn '(A)
                                  (list (type-fn (list INT) #f (tv 'A)) INT)
                                  (LIST-OF (tv 'A)))
   'builtins/all         (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  BOOL)
   'builtins/any         (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  BOOL)
   'builtins/partition   (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  (MAP-OF STR (LIST-OF (tv 'A))))
   'builtins/groupBy     (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f STR)
                                        (LIST-OF (tv 'A)))
                                  (MAP-OF STR (LIST-OF (tv 'A))))

   ;; ============================================================================
   ;; builtins.* — attrsets (parametric)
   ;; ============================================================================

   'builtins/attrNames       (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF STR))
   'builtins/attrValues      (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF (tv 'V)))
   'builtins/hasAttr         (poly-fn '(V) (list STR (MAP-OF STR (tv 'V))) BOOL)
   'builtins/getAttr         (poly-fn '(V) (list STR (MAP-OF STR (tv 'V))) (tv 'V))
   'builtins/removeAttrs     (poly-fn '(V) (list (MAP-OF STR (tv 'V)) (LIST-OF STR))
                                      (MAP-OF STR (tv 'V)))
   'builtins/intersectAttrs  (poly-fn '(V W) (list (MAP-OF STR (tv 'V)) (MAP-OF STR (tv 'W)))
                                      (MAP-OF STR (tv 'W)))
   'builtins/mapAttrs        (poly-fn '(V W)
                                      (list (type-fn (list STR (tv 'V)) #f (tv 'W))
                                            (MAP-OF STR (tv 'V)))
                                      (MAP-OF STR (tv 'W)))
   'builtins/catAttrs        (poly-fn '(V) (list STR (LIST-OF (MAP-OF STR (tv 'V))))
                                      (LIST-OF (tv 'V)))
   'builtins/listToAttrs     (poly-fn '(V) (list (LIST-OF (MAP-OF STR (tv 'V))))
                                      (MAP-OF STR (tv 'V)))
   'builtins/zipAttrsWith    (fn-of (list ANY ANY) ANY)
   'builtins/functionArgs    (fn-of (list ANY) (MAP-OF STR BOOL))

   ;; ============================================================================
   ;; builtins.* — type predicates (already sharp)
   ;; ============================================================================

   'builtins/isString    (fn-of (list ANY) BOOL)
   'builtins/isInt       (fn-of (list ANY) BOOL)
   'builtins/isBool      (fn-of (list ANY) BOOL)
   'builtins/isFloat     (fn-of (list ANY) BOOL)
   'builtins/isList      (fn-of (list ANY) BOOL)
   'builtins/isAttrs     (fn-of (list ANY) BOOL)
   'builtins/isNull      (fn-of (list ANY) BOOL)
   'builtins/isFunction  (fn-of (list ANY) BOOL)
   'builtins/isPath      (fn-of (list ANY) BOOL)
   'builtins/typeOf      (fn-of (list ANY) STR)

   ;; ============================================================================
   ;; builtins.* — strings / formatting
   ;; ============================================================================

   'builtins/toString         (fn-of (list ANY) STR)
   ;; bare aliases that Nix exposes without the builtins. prefix
   'toString                  (fn-of (list ANY) STR)
   'isNull                    (fn-of (list ANY) BOOL)
   'throw                     (fn-of (list STR) ANY)
   'abort                     (fn-of (list STR) ANY)
   'removeAttrs               (poly-fn '(V) (list (MAP-OF STR (tv 'V)) (LIST-OF STR))
                                       (MAP-OF STR (tv 'V)))
   'map                       (poly-fn '(A B)
                                       (list (type-fn (list (tv 'A)) #f (tv 'B))
                                             (LIST-OF (tv 'A)))
                                       (LIST-OF (tv 'B)))
   'baseNameOf                (fn-of (list ANY) STR)
   'dirOf                     (fn-of (list ANY) ANY)
   'derivation                (fn-of (list ANY) ANY)
   'fetchTarball              (fn-of (list ANY) ANY)
   'fetchurl                  (fn-of (list STR) ANY)
   'import                    (fn-of (list ANY) ANY)
   'placeholder               (fn-of (list STR) STR)
   'scopedImport              (fn-of (list ANY ANY) ANY)
   'builtins/toJSON           (fn-of (list ANY) STR)
   'builtins/fromJSON         (fn-of (list STR) ANY)
   'builtins/toXML            (fn-of (list ANY) STR)
   'builtins/replaceStrings   (fn-of (list (LIST-OF STR) (LIST-OF STR) STR) STR)
   'builtins/substring        (fn-of (list INT INT STR) STR)
   'builtins/stringLength     (fn-of (list STR) INT)
   'builtins/split            (fn-of (list STR STR) (LIST-OF ANY))
   'builtins/match            (fn-of (list STR STR) (LIST-OF STR))
   'builtins/concatStringsSep (fn-of (list STR (LIST-OF STR)) STR)
   'builtins/parseDrvName     (fn-of (list STR) (MAP-OF STR STR))
   'builtins/compareVersions  (fn-of (list STR STR) INT)
   'builtins/splitVersion     (fn-of (list STR) (LIST-OF STR))

   ;; ============================================================================
   ;; builtins.* — paths / IO
   ;; ============================================================================

   'builtins/toFile         (fn-of (list STR STR) ANY)
   'builtins/readFile       (fn-of (list ANY) STR)
   'builtins/readDir        (fn-of (list ANY) (MAP-OF STR STR))
   'builtins/pathExists     (fn-of (list ANY) BOOL)
   'builtins/dirOf          (fn-of (list ANY) ANY)
   'builtins/baseNameOf     (fn-of (list ANY) STR)
   'builtins/import         (fn-of (list ANY) ANY)
   'builtins/scopedImport   (fn-of (list ANY ANY) ANY)
   'builtins/fetchurl       (fn-of (list STR) ANY)
   'builtins/fetchTarball   (fn-of (list ANY) ANY)
   'builtins/fetchGit       (fn-of (list ANY) ANY)
   'builtins/fetchTree      (fn-of (list ANY) ANY)
   'builtins/filterSource   (fn-of (list ANY ANY) ANY)
   'builtins/path           (fn-of (list ANY) ANY)
   'builtins/placeholder    (fn-of (list STR) STR)
   'builtins/storePath      (fn-of (list ANY) ANY)
   'builtins/hashString     (fn-of (list STR STR) STR)
   'builtins/hashFile       (fn-of (list STR ANY) STR)

   ;; ============================================================================
   ;; builtins.* — control / debug
   ;; ============================================================================

   'builtins/trace        (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'builtins/traceVerbose (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'builtins/tryEval      (fn-of (list ANY) (MAP-OF STR ANY))
   'builtins/throw        (fn-of (list STR) ANY)
   'builtins/abort        (fn-of (list STR) ANY)
   'builtins/deepSeq      (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'builtins/seq          (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'builtins/break        (fn-of (list ANY) ANY)

   ;; ============================================================================
   ;; builtins.* — arithmetic / bit ops
   ;; ============================================================================

   'builtins/add        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   'builtins/sub        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   'builtins/mul        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   'builtins/div        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   'builtins/bitAnd     (fn-of (list INT INT) INT)
   'builtins/bitOr      (fn-of (list INT INT) INT)
   'builtins/bitXor     (fn-of (list INT INT) INT)
   'builtins/lessThan   (fn-of (list (type-prim 'Number) (type-prim 'Number)) BOOL)
   'builtins/floor      (fn-of (list (type-prim 'Number)) INT)
   'builtins/ceil       (fn-of (list (type-prim 'Number)) INT)

   ;; ============================================================================
   ;; builtins.* — system info
   ;; ============================================================================

   'builtins/currentSystem STR
   'builtins/currentTime   INT
   'builtins/storeDir      STR
   'builtins/nixVersion    STR
   'builtins/langVersion   INT
   'builtins/nixPath       ANY

   ;; ============================================================================
   ;; lib.* — NixOS module system (still mostly Any — return is module-shaped)
   ;; ============================================================================

   'lib/mkIf            (poly-fn '(A) (list BOOL (tv 'A)) (tv 'A))
   'lib/mkMerge         (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'lib/mkDefault       (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/mkForce         (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/mkOverride      (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   'lib/mkBefore        (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/mkAfter         (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/mkOrder         (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   'lib/mkEnableOption  (fn-of (list STR) NIXT)
   'lib/mkOption        (fn-of (list ANY) NIXT)
   'lib/mkPackageOption (fn-of (list ANY ANY ANY) NIXT)
   'lib/mkRenamedOptionModule (fn-of (list ANY ANY) ANY)
   'lib/mkRemovedOptionModule (fn-of (list ANY STR) ANY)
   'lib/mkAliasOptionModule   (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.* — conditional inclusion (parametric)
   ;; ============================================================================

   'lib/optional        (poly-fn '(A) (list BOOL (tv 'A)) (LIST-OF (tv 'A)))
   'lib/optionals       (poly-fn '(A) (list BOOL (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/optionalString  (fn-of (list BOOL STR) STR)
   'lib/optionalAttrs   (poly-fn '(V) (list BOOL (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))

   ;; ============================================================================
   ;; lib.* — strings
   ;; ============================================================================

   'lib/concatStrings        (fn-of (list (LIST-OF STR)) STR)
   'lib/concatStringsSep     (fn-of (list STR (LIST-OF STR)) STR)
   'lib/concatMapStrings     (poly-fn '(A)
                                      (list (type-fn (list (tv 'A)) #f STR)
                                            (LIST-OF (tv 'A)))
                                      STR)
   'lib/concatMapStringsSep  (poly-fn '(A)
                                      (list STR
                                            (type-fn (list (tv 'A)) #f STR)
                                            (LIST-OF (tv 'A)))
                                      STR)
   'lib/concatLines          (fn-of (list (LIST-OF STR)) STR)
   'lib/concatMapAttrs       (fn-of (list ANY ANY) ANY)
   'lib/splitString          (fn-of (list STR STR) (LIST-OF STR))
   'lib/hasPrefix            (fn-of (list STR STR) BOOL)
   'lib/hasSuffix            (fn-of (list STR STR) BOOL)
   'lib/hasInfix             (fn-of (list STR STR) BOOL)
   'lib/removePrefix         (fn-of (list STR STR) STR)
   'lib/removeSuffix         (fn-of (list STR STR) STR)
   'lib/toLower              (fn-of (list STR) STR)
   'lib/toUpper              (fn-of (list STR) STR)
   'lib/escapeShellArg       (fn-of (list STR) STR)
   'lib/escapeShellArgs      (fn-of (list (LIST-OF STR)) STR)
   'lib/escapeNixString      (fn-of (list STR) STR)
   'lib/escapeNixIdentifier  (fn-of (list STR) STR)
   'lib/escapeXML            (fn-of (list STR) STR)
   'lib/escapeRegex          (fn-of (list STR) STR)
   'lib/stringToCharacters   (fn-of (list STR) (LIST-OF STR))
   'lib/replaceStrings       (fn-of (list (LIST-OF STR) (LIST-OF STR) STR) STR)
   'lib/fixedWidthString     (fn-of (list INT STR STR) STR)
   'lib/fixedWidthNumber     (fn-of (list INT INT) STR)
   'lib/floatToString        (fn-of (list (type-prim 'Number)) STR)
   'lib/boolToString         (fn-of (list BOOL) STR)
   'lib/toInt                (fn-of (list STR) INT)
   'lib/toIntBase10          (fn-of (list STR) INT)

   ;; ============================================================================
   ;; lib.* — versions
   ;; ============================================================================

   'lib/versionAtLeast       (fn-of (list STR STR) BOOL)
   'lib/versionOlder         (fn-of (list STR STR) BOOL)
   'lib/getName              (fn-of (list ANY) STR)
   'lib/getVersion           (fn-of (list ANY) STR)

   ;; ============================================================================
   ;; lib.* — attrsets (parametric)
   ;; ============================================================================

   'lib/filterAttrs            (poly-fn '(V)
                                        (list (type-fn (list STR (tv 'V)) #f BOOL)
                                              (MAP-OF STR (tv 'V)))
                                        (MAP-OF STR (tv 'V)))
   'lib/filterAttrsRecursive   (fn-of (list ANY ANY) ANY)
   'lib/mapAttrs               (poly-fn '(V W)
                                        (list (type-fn (list STR (tv 'V)) #f (tv 'W))
                                              (MAP-OF STR (tv 'V)))
                                        (MAP-OF STR (tv 'W)))
   'lib/mapAttrs'              (fn-of (list ANY ANY) ANY)
   'lib/mapAttrsToList         (poly-fn '(V W)
                                        (list (type-fn (list STR (tv 'V)) #f (tv 'W))
                                              (MAP-OF STR (tv 'V)))
                                        (LIST-OF (tv 'W)))
   'lib/mapAttrsRecursive      (fn-of (list ANY ANY) ANY)
   'lib/mapAttrsRecursiveCond  (fn-of (list ANY ANY ANY) ANY)
   'lib/concatMapAttrsToList   (fn-of (list ANY ANY) ANY)
   'lib/genAttrs               (poly-fn '(A)
                                        (list (LIST-OF STR)
                                              (type-fn (list STR) #f (tv 'A)))
                                        (MAP-OF STR (tv 'A)))
   'lib/recursiveUpdate        (fn-of (list ANY ANY) ANY)
   'lib/recursiveUpdateUntil   (fn-of (list ANY ANY ANY) ANY)
   'lib/foldAttrs              (fn-of (list ANY ANY ANY) ANY)
   'lib/getAttrs               (poly-fn '(V) (list (LIST-OF STR) (MAP-OF STR (tv 'V)))
                                        (MAP-OF STR (tv 'V)))
   'lib/attrByPath             (poly-fn '(A)
                                        (list (LIST-OF STR) (tv 'A) ANY)
                                        (tv 'A))
   'lib/hasAttrByPath          (fn-of (list (LIST-OF STR) ANY) BOOL)
   'lib/setAttrByPath          (fn-of (list (LIST-OF STR) ANY) ANY)
   'lib/getAttrFromPath        (fn-of (list (LIST-OF STR) ANY) ANY)
   'lib/nameValuePair          (poly-fn '(A) (list STR (tv 'A)) (MAP-OF STR ANY))
   'lib/listToAttrs            (poly-fn '(V) (list (LIST-OF (MAP-OF STR (tv 'V))))
                                        (MAP-OF STR (tv 'V)))
   'lib/zipAttrs               (fn-of (list (LIST-OF ANY)) ANY)
   'lib/zipAttrsWith           (fn-of (list ANY ANY) ANY)
   'lib/unionOfDisjoint        (fn-of (list ANY ANY) ANY)
   'lib/cartesianProductOfSets (fn-of (list ANY) ANY)
   'lib/updateManyAttrsByPath  (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.* — lists (parametric)
   ;; ============================================================================

   'lib/flatten         (poly-fn '(A) (list ANY) (LIST-OF (tv 'A)))
   'lib/unique          (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/intersectLists  (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'A)))
   'lib/subtractLists   (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'A)))
   'lib/reverseList     (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/take            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/drop            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/sublist         (poly-fn '(A) (list INT INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/last            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'lib/init            (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/range           (fn-of (list INT INT) (LIST-OF INT))
   'lib/imap0           (poly-fn '(A B)
                                 (list (type-fn (list INT (tv 'A)) #f (tv 'B))
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'B)))
   'lib/imap1           (poly-fn '(A B)
                                 (list (type-fn (list INT (tv 'A)) #f (tv 'B))
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'B)))
   'lib/zipLists        (fn-of (list ANY ANY) ANY)
   'lib/zipListsWith    (fn-of (list ANY ANY ANY) ANY)
   'lib/foldr           (poly-fn '(A B)
                                 (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   'lib/foldl           (poly-fn '(A B)
                                 (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   'lib/fold            (poly-fn '(A B)
                                 (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   'lib/foldl'          (poly-fn '(A B)
                                 (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   'lib/count           (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 INT)
   'lib/any             (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 BOOL)
   'lib/all             (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 BOOL)
   'lib/partition       (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 (MAP-OF STR (LIST-OF (tv 'A))))
   'lib/groupBy         (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f STR)
                                       (LIST-OF (tv 'A)))
                                 (MAP-OF STR (LIST-OF (tv 'A))))
   'lib/findFirst       (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (tv 'A) (LIST-OF (tv 'A)))
                                 (tv 'A))
   'lib/findFirstIndex  (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       ANY (LIST-OF (tv 'A)))
                                 INT)
   'lib/forEach         (poly-fn '(A B)
                                 (list (LIST-OF (tv 'A))
                                       (type-fn (list (tv 'A)) #f (tv 'B)))
                                 (LIST-OF (tv 'B)))
   'lib/concatLists     (poly-fn '(A) (list (LIST-OF (LIST-OF (tv 'A))))
                                 (LIST-OF (tv 'A)))
   'lib/concatMap       (poly-fn '(A B)
                                 (list (type-fn (list (tv 'A)) #f (LIST-OF (tv 'B)))
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'B)))
   'lib/crossLists      (fn-of (list ANY ANY) ANY)
   'lib/naturalSort     (fn-of (list (LIST-OF STR)) (LIST-OF STR))
   'lib/sort            (poly-fn '(A)
                                 (list (type-fn (list (tv 'A) (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'A)))

   ;; ============================================================================
   ;; lib.* — combinators / trivial
   ;; ============================================================================

   'lib/id        (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/const     (poly-fn '(A B) (list (tv 'A) (tv 'B)) (tv 'A))
   'lib/flip      (poly-fn '(A B C)
                           (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'C))
                                 (tv 'B) (tv 'A))
                           (tv 'C))
   'lib/pipe      (poly-fn '(A) (list (tv 'A) (LIST-OF ANY)) ANY)
   'lib/compose   (fn-of (list ANY ANY) ANY)
   'lib/throwIf   (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   'lib/throwIfNot (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   'lib/assertMsg (fn-of (list BOOL STR) BOOL)
   'lib/warn      (poly-fn '(A) (list STR (tv 'A)) (tv 'A))
   'lib/warnIf    (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   'lib/seq       (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'lib/deepSeq   (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'lib/min       (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))
   'lib/max       (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))

   ;; ============================================================================
   ;; lib.* — modules / overlays
   ;; ============================================================================

   'lib/evalModules            (fn-of (list ANY) ANY)
   'lib/composeExtensions      (fn-of (list ANY ANY) ANY)
   'lib/composeManyExtensions  (fn-of (list (LIST-OF ANY)) ANY)
   'lib/makeOverridable        (fn-of (list ANY ANY) ANY)
   'lib/callPackageWith        (fn-of (list ANY ANY ANY) ANY)
   'lib/callPackagesWith       (fn-of (list ANY ANY ANY) ANY)
   'lib/extends                (fn-of (list ANY ANY) ANY)
   'lib/fix                    (poly-fn '(A) (list (type-fn (list (tv 'A)) #f (tv 'A))) (tv 'A))
   'lib/fix'                   (poly-fn '(A) (list (type-fn (list (tv 'A)) #f (tv 'A))) (tv 'A))

   ;; ============================================================================
   ;; lib.* — sources / paths
   ;; ============================================================================

   'lib/cleanSource              (fn-of (list ANY) ANY)
   'lib/cleanSourceWith          (fn-of (list ANY) ANY)
   'lib/sourceByRegex            (fn-of (list ANY (LIST-OF STR)) ANY)
   'lib/sourceFilesBySuffices    (fn-of (list ANY (LIST-OF STR)) ANY)
   'lib/pathHasContext           (fn-of (list ANY) BOOL)
   'lib/getLib                   (fn-of (list ANY) ANY)
   'lib/getBin                   (fn-of (list ANY) ANY)
   'lib/getDev                   (fn-of (list ANY) ANY)
   'lib/getMan                   (fn-of (list ANY) ANY)
   'lib/getOutput                (fn-of (list STR ANY) ANY)
   'lib/makeBinPath              (fn-of (list (LIST-OF ANY)) STR)
   'lib/makeLibraryPath          (fn-of (list (LIST-OF ANY)) STR)
   'lib/makeSearchPath           (fn-of (list STR (LIST-OF ANY)) STR)
   'lib/makeSearchPathOutput     (fn-of (list STR STR (LIST-OF ANY)) STR)

   ;; ============================================================================
   ;; lib.types.* — opaque NixType values + parametric helpers
   ;; ============================================================================

   'lib/types.bool          NIXT
   'lib/types.str           NIXT
   'lib/types.nonEmptyStr   NIXT
   'lib/types.singleLineStr NIXT
   'lib/types.strMatching   (fn-of (list STR) NIXT)
   'lib/types.int           NIXT
   'lib/types.float         NIXT
   'lib/types.number        NIXT
   'lib/types.path          NIXT
   'lib/types.package       NIXT
   'lib/types.port          NIXT
   'lib/types.anything      NIXT
   'lib/types.unspecified   NIXT
   'lib/types.raw           NIXT
   'lib/types.attrs         NIXT
   'lib/types.lines         NIXT
   'lib/types.commas        NIXT
   'lib/types.envVar        NIXT
   'lib/types.shellPackage  NIXT
   'lib/types.listOf        (fn-of (list NIXT) NIXT)
   'lib/types.attrsOf       (fn-of (list NIXT) NIXT)
   'lib/types.lazyAttrsOf   (fn-of (list NIXT) NIXT)
   'lib/types.nullOr        (fn-of (list NIXT) NIXT)
   'lib/types.uniq          (fn-of (list NIXT) NIXT)
   'lib/types.unique        (fn-of (list ANY NIXT) NIXT)
   'lib/types.enum          (fn-of (list (LIST-OF ANY)) NIXT)
   'lib/types.submodule     (fn-of (list ANY) NIXT)
   'lib/types.submoduleWith (fn-of (list ANY) NIXT)
   'lib/types.deferredModule NIXT
   'lib/types.either        (fn-of (list NIXT NIXT) NIXT)
   'lib/types.oneOf         (fn-of (list (LIST-OF NIXT)) NIXT)
   'lib/types.coercedTo     (fn-of (list NIXT ANY NIXT) NIXT)
   'lib/types.functionTo    (fn-of (list NIXT) NIXT)
   'lib/types.addCheck      (fn-of (list NIXT ANY) NIXT)
   'lib/types.ints.unsigned NIXT
   'lib/types.ints.positive NIXT
   'lib/types.ints.between  (fn-of (list INT INT) NIXT)
   'lib/types.ints.u8       NIXT
   'lib/types.ints.u16      NIXT
   'lib/types.ints.u32      NIXT
   'lib/types.ints.u64      NIXT
   'lib/types.ints.s8       NIXT
   'lib/types.ints.s16      NIXT
   'lib/types.ints.s32      NIXT
   'lib/types.ints.s64      NIXT

   ;; ============================================================================
   ;; lib.attrsets.* — qualified forms (in addition to lib/X)
   ;; ============================================================================

   'lib/attrsets.attrNames         (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF STR))
   'lib/attrsets.attrValues        (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF (tv 'V)))
   'lib/attrsets.hasAttr           (poly-fn '(V) (list STR (MAP-OF STR (tv 'V))) BOOL)
   'lib/attrsets.getAttrs          (poly-fn '(V) (list (LIST-OF STR) (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))
   'lib/attrsets.filterAttrs       (poly-fn '(V) (list (type-fn (list STR (tv 'V)) #f BOOL) (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))
   'lib/attrsets.mapAttrs          (poly-fn '(V W) (list (type-fn (list STR (tv 'V)) #f (tv 'W)) (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'W)))
   'lib/attrsets.mapAttrsToList    (poly-fn '(V W) (list (type-fn (list STR (tv 'V)) #f (tv 'W)) (MAP-OF STR (tv 'V))) (LIST-OF (tv 'W)))
   'lib/attrsets.foldlAttrs        (fn-of (list ANY ANY ANY) ANY)
   'lib/attrsets.attrByPath        (fn-of (list (LIST-OF STR) ANY ANY) ANY)
   'lib/attrsets.hasAttrByPath     (fn-of (list (LIST-OF STR) ANY) BOOL)
   'lib/attrsets.setAttrByPath     (fn-of (list (LIST-OF STR) ANY) ANY)
   'lib/attrsets.recursiveUpdate   (fn-of (list ANY ANY) ANY)
   'lib/attrsets.nameValuePair     (poly-fn '(V) (list STR (tv 'V)) (MAP-OF STR ANY))
   'lib/attrsets.listToAttrs       (poly-fn '(V) (list (LIST-OF (MAP-OF STR (tv 'V)))) (MAP-OF STR (tv 'V)))
   'lib/attrsets.cartesianProduct  (fn-of (list ANY) (LIST-OF ANY))
   'lib/attrsets.zipAttrs          (fn-of (list (LIST-OF ANY)) ANY)
   'lib/attrsets.zipAttrsWith      (fn-of (list ANY ANY) ANY)
   'lib/attrsets.optionalAttrs     (poly-fn '(V) (list BOOL (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))
   'lib/attrsets.removeAttrs       (poly-fn '(V) (list (MAP-OF STR (tv 'V)) (LIST-OF STR)) (MAP-OF STR (tv 'V)))

   ;; ============================================================================
   ;; lib.lists.* — qualified forms
   ;; ============================================================================

   'lib/lists.head            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'lib/lists.tail            (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.last            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'lib/lists.init            (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.length          (poly-fn '(A) (list (LIST-OF (tv 'A))) INT)
   'lib/lists.elem            (poly-fn '(A) (list (tv 'A) (LIST-OF (tv 'A))) BOOL)
   'lib/lists.elemAt          (poly-fn '(A) (list (LIST-OF (tv 'A)) INT) (tv 'A))
   'lib/lists.map             (poly-fn '(A B) (list (type-fn (list (tv 'A)) #f (tv 'B)) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))
   'lib/lists.filter          (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.foldl           (poly-fn '(A B) (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B)) (tv 'B) (LIST-OF (tv 'A))) (tv 'B))
   'lib/lists.foldr           (poly-fn '(A B) (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'B)) (tv 'B) (LIST-OF (tv 'A))) (tv 'B))
   'lib/lists.any             (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) BOOL)
   'lib/lists.all             (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) BOOL)
   'lib/lists.count           (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) INT)
   'lib/lists.take            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.drop            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.reverseList     (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.sort            (poly-fn '(A) (list (type-fn (list (tv 'A) (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.unique          (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.partition       (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) (MAP-OF STR (LIST-OF (tv 'A))))
   'lib/lists.groupBy         (poly-fn '(A) (list (type-fn (list (tv 'A)) #f STR) (LIST-OF (tv 'A))) (MAP-OF STR (LIST-OF (tv 'A))))
   'lib/lists.flatten         (fn-of (list ANY) ANY)
   'lib/lists.range           (fn-of (list INT INT) (LIST-OF INT))
   'lib/lists.zipLists        (fn-of (list ANY ANY) ANY)
   'lib/lists.concatLists     (poly-fn '(A) (list (LIST-OF (LIST-OF (tv 'A)))) (LIST-OF (tv 'A)))
   'lib/lists.concatMap       (poly-fn '(A B) (list (type-fn (list (tv 'A)) #f (LIST-OF (tv 'B))) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))
   'lib/lists.intersectLists  (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.subtractLists   (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'lib/lists.findFirst       (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (tv 'A) (LIST-OF (tv 'A))) (tv 'A))
   'lib/lists.imap0           (poly-fn '(A B) (list (type-fn (list INT (tv 'A)) #f (tv 'B)) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))
   'lib/lists.imap1           (poly-fn '(A B) (list (type-fn (list INT (tv 'A)) #f (tv 'B)) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))

   ;; ============================================================================
   ;; lib.strings.* — qualified
   ;; ============================================================================

   'lib/strings.concatStrings     (fn-of (list (LIST-OF STR)) STR)
   'lib/strings.concatStringsSep  (fn-of (list STR (LIST-OF STR)) STR)
   'lib/strings.concatMapStrings  (poly-fn '(A) (list (type-fn (list (tv 'A)) #f STR) (LIST-OF (tv 'A))) STR)
   'lib/strings.concatLines       (fn-of (list (LIST-OF STR)) STR)
   'lib/strings.hasPrefix         (fn-of (list STR STR) BOOL)
   'lib/strings.hasSuffix         (fn-of (list STR STR) BOOL)
   'lib/strings.hasInfix          (fn-of (list STR STR) BOOL)
   'lib/strings.removePrefix      (fn-of (list STR STR) STR)
   'lib/strings.removeSuffix      (fn-of (list STR STR) STR)
   'lib/strings.replaceStrings    (fn-of (list (LIST-OF STR) (LIST-OF STR) STR) STR)
   'lib/strings.splitString       (fn-of (list STR STR) (LIST-OF STR))
   'lib/strings.stringToCharacters (fn-of (list STR) (LIST-OF STR))
   'lib/strings.stringLength      (fn-of (list STR) INT)
   'lib/strings.substring         (fn-of (list INT INT STR) STR)
   'lib/strings.toLower           (fn-of (list STR) STR)
   'lib/strings.toUpper           (fn-of (list STR) STR)
   'lib/strings.escapeNixString   (fn-of (list STR) STR)
   'lib/strings.escapeShellArg    (fn-of (list STR) STR)
   'lib/strings.escapeShellArgs   (fn-of (list (LIST-OF STR)) STR)
   'lib/strings.escapeURL         (fn-of (list STR) STR)
   'lib/strings.escapeXML         (fn-of (list STR) STR)
   'lib/strings.escapeRegex       (fn-of (list STR) STR)
   'lib/strings.fixedWidthString  (fn-of (list INT STR STR) STR)
   'lib/strings.fixedWidthNumber  (fn-of (list INT INT) STR)
   'lib/strings.toInt             (fn-of (list STR) INT)
   'lib/strings.toIntBase10       (fn-of (list STR) INT)
   'lib/strings.versionAtLeast    (fn-of (list STR STR) BOOL)
   'lib/strings.versionOlder      (fn-of (list STR STR) BOOL)
   'lib/strings.normalizePath     (fn-of (list STR) STR)
   'lib/strings.optionalString    (fn-of (list BOOL STR) STR)

   ;; ============================================================================
   ;; lib.path.*
   ;; ============================================================================

   'lib/path.append           (fn-of (list ANY STR) ANY)
   'lib/path.removePrefix     (fn-of (list ANY ANY) ANY)
   'lib/path.hasPrefix        (fn-of (list ANY ANY) BOOL)
   'lib/path.subpath.isValid  (fn-of (list ANY) BOOL)
   'lib/path.subpath.normalise (fn-of (list ANY) ANY)
   'lib/path.subpath.join     (fn-of (list ANY) ANY)
   'lib/path.subpath.components (fn-of (list ANY) (LIST-OF STR))

   ;; ============================================================================
   ;; lib.fileset.* (Nix 23.11+)
   ;; ============================================================================

   'lib/fileset.toSource      (fn-of (list ANY) ANY)
   'lib/fileset.union         (fn-of (list ANY ANY) ANY)
   'lib/fileset.unions        (fn-of (list (LIST-OF ANY)) ANY)
   'lib/fileset.intersection  (fn-of (list ANY ANY) ANY)
   'lib/fileset.difference    (fn-of (list ANY ANY) ANY)
   'lib/fileset.fromSource    (fn-of (list ANY) ANY)
   'lib/fileset.maybeMissing  (fn-of (list ANY) ANY)
   'lib/fileset.gitTracked    (fn-of (list ANY) ANY)
   'lib/fileset.fileFilter    (fn-of (list ANY ANY) ANY)
   'lib/fileset.trace         (fn-of (list ANY) ANY)
   'lib/fileset.traceVal      (fn-of (list ANY) ANY)

   ;; ============================================================================
   ;; lib.generators.*
   ;; ============================================================================

   'lib/generators.toINI           (fn-of (list ANY ANY) STR)
   'lib/generators.toINIWithGlobalSection (fn-of (list ANY ANY) STR)
   'lib/generators.toGitINI        (fn-of (list ANY) STR)
   'lib/generators.toJSON          (fn-of (list ANY ANY) STR)
   'lib/generators.toYAML          (fn-of (list ANY ANY) STR)
   'lib/generators.toPretty        (fn-of (list ANY ANY) STR)
   'lib/generators.toKeyValue      (fn-of (list ANY ANY) STR)
   'lib/generators.toPlist         (fn-of (list ANY ANY) STR)
   'lib/generators.toLua           (fn-of (list ANY ANY) STR)
   'lib/generators.toDhall         (fn-of (list ANY ANY) STR)

   ;; ============================================================================
   ;; lib.modules.*
   ;; ============================================================================

   'lib/modules.evalModules        (fn-of (list ANY) ANY)
   'lib/modules.mkOption           (fn-of (list ANY) NIXT)
   'lib/modules.mkIf               (poly-fn '(A) (list BOOL (tv 'A)) (tv 'A))
   'lib/modules.mkForce            (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/modules.mkDefault          (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/modules.mkOverride         (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   'lib/modules.mkMerge            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'lib/modules.mkOptionDefault    (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/modules.mkBefore           (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/modules.mkAfter            (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/modules.mkOrder            (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   'lib/modules.mkRemovedOptionModule  (fn-of (list ANY STR) ANY)
   'lib/modules.mkRenamedOptionModule  (fn-of (list ANY ANY) ANY)
   'lib/modules.mkChangedOptionModule  (fn-of (list ANY ANY ANY) ANY)
   'lib/modules.mkAliasOptionModule    (fn-of (list ANY ANY) ANY)
   'lib/modules.mkAliasOptionModuleMD  (fn-of (list ANY ANY) ANY)
   'lib/modules.mkAliasOptionModuleWithPriority (fn-of (list ANY ANY) ANY)
   'lib/modules.doRename           (fn-of (list ANY) ANY)
   'lib/modules.filterOverrides    (fn-of (list (LIST-OF ANY)) (LIST-OF ANY))

   ;; ============================================================================
   ;; lib.options.*
   ;; ============================================================================

   'lib/options.mkOption           (fn-of (list ANY) NIXT)
   'lib/options.mkEnableOption     (fn-of (list STR) NIXT)
   'lib/options.mkPackageOption    (fn-of (list ANY ANY ANY) NIXT)
   'lib/options.mkSinkUndeclaredOptions (fn-of (list ANY) ANY)
   'lib/options.literalExpression  (fn-of (list STR) ANY)
   'lib/options.literalMD          (fn-of (list STR) ANY)
   'lib/options.literalDocBook     (fn-of (list STR) ANY)
   'lib/options.showOption         (fn-of (list (LIST-OF STR)) STR)
   'lib/options.unknownModule      ANY
   'lib/options.mergeDefaultOption (fn-of (list ANY ANY) ANY)
   'lib/options.mergeOneOption     (fn-of (list ANY ANY) ANY)
   'lib/options.mergeEqualOption   (fn-of (list ANY ANY) ANY)
   'lib/options.mergeUniqueOption  (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.customisation.*
   ;; ============================================================================

   'lib/customisation.makeOverridable   (fn-of (list ANY ANY) ANY)
   'lib/customisation.callPackageWith   (fn-of (list ANY ANY ANY) ANY)
   'lib/customisation.callPackagesWith  (fn-of (list ANY ANY ANY) ANY)
   'lib/customisation.extendDerivation  (fn-of (list ANY ANY ANY) ANY)
   'lib/customisation.hydraJob          (fn-of (list ANY) ANY)
   'lib/customisation.makeScope         (fn-of (list ANY ANY) ANY)
   'lib/customisation.makeScopeWithSplicing (fn-of (list ANY ANY ANY ANY ANY) ANY)
   'lib/customisation.overrideDerivation (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.debug.*
   ;; ============================================================================

   'lib/debug.traceIf            (poly-fn '(A) (list BOOL ANY (tv 'A)) (tv 'A))
   'lib/debug.traceVal           (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/debug.traceValFn         (poly-fn '(A) (list (type-fn (list (tv 'A)) #f ANY) (tv 'A)) (tv 'A))
   'lib/debug.traceSeq           (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   'lib/debug.traceSeqN          (poly-fn '(A) (list INT ANY (tv 'A)) (tv 'A))
   'lib/debug.traceFnSeqN        (poly-fn '(A B) (list INT (type-fn (list (tv 'A)) #f ANY) (tv 'A) (tv 'B)) (tv 'B))
   'lib/debug.runTests           (fn-of (list ANY) ANY)

   ;; ============================================================================
   ;; lib.cli.*
   ;; ============================================================================

   'lib/cli.toGNUCommandLine            (fn-of (list ANY ANY) (LIST-OF STR))
   'lib/cli.toGNUCommandLineShell       (fn-of (list ANY ANY) STR)

   ;; ============================================================================
   ;; lib.licenses.* — opaque License values
   ;; ============================================================================

   'lib/licenses.mit         ANY
   'lib/licenses.bsd2        ANY
   'lib/licenses.bsd3        ANY
   'lib/licenses.gpl2        ANY
   'lib/licenses.gpl2Only    ANY
   'lib/licenses.gpl2Plus    ANY
   'lib/licenses.gpl3        ANY
   'lib/licenses.gpl3Only    ANY
   'lib/licenses.gpl3Plus    ANY
   'lib/licenses.lgpl2       ANY
   'lib/licenses.lgpl2Plus   ANY
   'lib/licenses.lgpl3       ANY
   'lib/licenses.lgpl3Plus   ANY
   'lib/licenses.apsl20      ANY
   'lib/licenses.asl20       ANY
   'lib/licenses.cc-by-30    ANY
   'lib/licenses.cc-by-40    ANY
   'lib/licenses.cc-by-sa-30 ANY
   'lib/licenses.cc-by-sa-40 ANY
   'lib/licenses.cc0         ANY
   'lib/licenses.isc         ANY
   'lib/licenses.mpl20       ANY
   'lib/licenses.unfree      ANY
   'lib/licenses.unfreeRedistributable ANY
   'lib/licenses.publicDomain ANY
   'lib/licenses.zlib        ANY
   'lib/licenses.wtfpl       ANY
   'lib/licenses.unlicense   ANY

   ;; ============================================================================
   ;; lib.platforms.* — opaque platform-set values
   ;; ============================================================================

   'lib/platforms.all         (LIST-OF STR)
   'lib/platforms.linux       (LIST-OF STR)
   'lib/platforms.darwin      (LIST-OF STR)
   'lib/platforms.unix        (LIST-OF STR)
   'lib/platforms.x86_64      (LIST-OF STR)
   'lib/platforms.aarch64     (LIST-OF STR)
   'lib/platforms.i686        (LIST-OF STR)
   'lib/platforms.x86         (LIST-OF STR)
   'lib/platforms.arm         (LIST-OF STR)
   'lib/platforms.windows     (LIST-OF STR)
   'lib/platforms.freebsd     (LIST-OF STR)
   'lib/platforms.openbsd     (LIST-OF STR)
   'lib/platforms.netbsd      (LIST-OF STR)
   'lib/platforms.cygwin      (LIST-OF STR)
   'lib/platforms.mips        (LIST-OF STR)
   'lib/platforms.s390x       (LIST-OF STR)
   'lib/platforms.riscv       (LIST-OF STR)
   'lib/platforms.riscv32     (LIST-OF STR)
   'lib/platforms.riscv64     (LIST-OF STR)
   'lib/platforms.power       (LIST-OF STR)
   'lib/platforms.power64     (LIST-OF STR)
   'lib/platforms.ppc64       (LIST-OF STR)
   'lib/platforms.ppc64le     (LIST-OF STR)
   'lib/platforms.wasi        (LIST-OF STR)

   ;; ============================================================================
   ;; lib.systems.*
   ;; ============================================================================

   'lib/systems.elaborate         (fn-of (list ANY) ANY)
   'lib/systems.parse.parseSystem (fn-of (list STR) ANY)
   'lib/systems.parse.tripleFromSystem (fn-of (list ANY) STR)
   'lib/systems.examples.aarch64-multiplatform ANY
   'lib/systems.examples.gnu64    ANY
   'lib/systems.examples.musl64   ANY
   'lib/systems.flakeExposed      (LIST-OF STR)
   'lib/systems.doubles.all       (LIST-OF STR)

   ;; ============================================================================
   ;; lib.maintainers.* — opaque maintainer values (sparse; only generic shape)
   ;; ============================================================================
   ;; Don't enumerate; user can write lib/maintainers.tom etc. and they'll
   ;; type-check via the "/" qualified-call fallback as ANY.

   ;; ============================================================================
   ;; lib.* — additional top-level helpers
   ;; ============================================================================

   'lib/trivial.id            (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'lib/trivial.const         (poly-fn '(A B) (list (tv 'A) (tv 'B)) (tv 'A))
   'lib/trivial.flip          (poly-fn '(A B C) (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'C)) (tv 'B) (tv 'A)) (tv 'C))
   'lib/trivial.pipe          (poly-fn '(A) (list (tv 'A) (LIST-OF ANY)) ANY)
   'lib/trivial.compose       (fn-of (list ANY ANY) ANY)
   'lib/trivial.warn          (poly-fn '(A) (list STR (tv 'A)) (tv 'A))
   'lib/trivial.warnIf        (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   'lib/trivial.throwIf       (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   'lib/trivial.throwIfNot    (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   'lib/trivial.boolToString  (fn-of (list BOOL) STR)
   'lib/trivial.bitAnd        (fn-of (list INT INT) INT)
   'lib/trivial.bitOr         (fn-of (list INT INT) INT)
   'lib/trivial.bitXor        (fn-of (list INT INT) INT)
   'lib/trivial.min           (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))
   'lib/trivial.max           (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))))

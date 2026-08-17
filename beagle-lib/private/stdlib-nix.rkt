#lang racket/base

;; Nix-specific stdlib type declarations.
;; Maps Nix builtins and lib.* functions to Beagle types.
;;
;; Higher-order combinators use `poly-fn` with forall vars (A, B, K, V, W).
;; Functions whose return type genuinely depends on dynamic shape (or where
;; modeling would mislead) stay at Any.

(require "ast.rkt"
         "types.rkt"
         "stdlib-helpers.rkt")

(define (q qualifier name)
  (qualified-ref qualifier name #f))

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

   (q 'builtins 'length)      (poly-fn '(A) (list (LIST-OF (tv 'A))) INT)
   (q 'builtins 'head)        (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   (q 'builtins 'tail)        (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'builtins 'elemAt)      (poly-fn '(A) (list (LIST-OF (tv 'A)) INT) (tv 'A))
   (q 'builtins 'elem)        (poly-fn '(A) (list (tv 'A) (LIST-OF (tv 'A))) BOOL)
   (q 'builtins 'map)         (poly-fn '(A B)
                                  (list (type-fn (list (tv 'A)) #f (tv 'B))
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'B)))
   (q 'builtins 'filter)      (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'A)))
   (q 'builtins 'foldl)       (poly-fn '(A B)
                                  (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                        (tv 'B)
                                        (LIST-OF (tv 'A)))
                                  (tv 'B))
   (q 'builtins '|foldl'|)    (poly-fn '(A B)
                                  (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                        (tv 'B)
                                        (LIST-OF (tv 'A)))
                                  (tv 'B))
   (q 'builtins 'sort)        (poly-fn '(A)
                                  (list (type-fn (list (tv 'A) (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'A)))
   (q 'builtins 'concatLists) (poly-fn '(A) (list (LIST-OF (LIST-OF (tv 'A))))
                                  (LIST-OF (tv 'A)))
   (q 'builtins 'concatMap)   (poly-fn '(A B)
                                  (list (type-fn (list (tv 'A)) #f (LIST-OF (tv 'B)))
                                        (LIST-OF (tv 'A)))
                                  (LIST-OF (tv 'B)))
   (q 'builtins 'genList)     (poly-fn '(A)
                                  (list (type-fn (list INT) #f (tv 'A)) INT)
                                  (LIST-OF (tv 'A)))
   (q 'builtins 'all)         (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  BOOL)
   (q 'builtins 'any)         (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  BOOL)
   (q 'builtins 'partition)   (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f BOOL)
                                        (LIST-OF (tv 'A)))
                                  (MAP-OF STR (LIST-OF (tv 'A))))
   (q 'builtins 'groupBy)     (poly-fn '(A)
                                  (list (type-fn (list (tv 'A)) #f STR)
                                        (LIST-OF (tv 'A)))
                                  (MAP-OF STR (LIST-OF (tv 'A))))

   ;; ============================================================================
   ;; builtins.* — attrsets (parametric)
   ;; ============================================================================

   (q 'builtins 'attrNames)       (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF STR))
   (q 'builtins 'attrValues)      (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF (tv 'V)))
   (q 'builtins 'hasAttr)         (poly-fn '(V) (list STR (MAP-OF STR (tv 'V))) BOOL)
   (q 'builtins 'getAttr)         (poly-fn '(V) (list STR (MAP-OF STR (tv 'V))) (tv 'V))
   (q 'builtins 'removeAttrs)     (poly-fn '(V) (list (MAP-OF STR (tv 'V)) (LIST-OF STR))
                                      (MAP-OF STR (tv 'V)))
   (q 'builtins 'intersectAttrs)  (poly-fn '(V W) (list (MAP-OF STR (tv 'V)) (MAP-OF STR (tv 'W)))
                                      (MAP-OF STR (tv 'W)))
   (q 'builtins 'mapAttrs)        (poly-fn '(V W)
                                      (list (type-fn (list STR (tv 'V)) #f (tv 'W))
                                            (MAP-OF STR (tv 'V)))
                                      (MAP-OF STR (tv 'W)))
   (q 'builtins 'catAttrs)        (poly-fn '(V) (list STR (LIST-OF (MAP-OF STR (tv 'V))))
                                      (LIST-OF (tv 'V)))
   (q 'builtins 'listToAttrs)     (poly-fn '(V) (list (LIST-OF (MAP-OF STR (tv 'V))))
                                      (MAP-OF STR (tv 'V)))
   (q 'builtins 'zipAttrsWith)    (fn-of (list ANY ANY) ANY)
   (q 'builtins 'functionArgs)    (fn-of (list ANY) (MAP-OF STR BOOL))

   ;; ============================================================================
   ;; builtins.* — type predicates (already sharp)
   ;; ============================================================================

   (q 'builtins 'isString)    (fn-of (list ANY) BOOL)
   (q 'builtins 'isInt)       (fn-of (list ANY) BOOL)
   (q 'builtins 'isBool)      (fn-of (list ANY) BOOL)
   (q 'builtins 'isFloat)     (fn-of (list ANY) BOOL)
   (q 'builtins 'isList)      (fn-of (list ANY) BOOL)
   (q 'builtins 'isAttrs)     (fn-of (list ANY) BOOL)
   (q 'builtins 'isNull)      (fn-of (list ANY) BOOL)
   (q 'builtins 'isFunction)  (fn-of (list ANY) BOOL)
   (q 'builtins 'isPath)      (fn-of (list ANY) BOOL)
   (q 'builtins 'typeOf)      (fn-of (list ANY) STR)

   ;; ============================================================================
   ;; builtins.* — strings / formatting
   ;; ============================================================================

   (q 'builtins 'toString)         (fn-of (list ANY) STR)
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
   (q 'builtins 'toJSON)           (fn-of (list ANY) STR)
   (q 'builtins 'fromJSON)         (fn-of (list STR) ANY)
   (q 'builtins 'toXML)            (fn-of (list ANY) STR)
   (q 'builtins 'replaceStrings)   (fn-of (list (LIST-OF STR) (LIST-OF STR) STR) STR)
   (q 'builtins 'substring)        (fn-of (list INT INT STR) STR)
   (q 'builtins 'stringLength)     (fn-of (list STR) INT)
   (q 'builtins 'split)            (fn-of (list STR STR) (LIST-OF ANY))
   (q 'builtins 'match)            (fn-of (list STR STR) (LIST-OF STR))
   (q 'builtins 'concatStringsSep) (fn-of (list STR (LIST-OF STR)) STR)
   (q 'builtins 'parseDrvName)     (fn-of (list STR) (MAP-OF STR STR))
   (q 'builtins 'compareVersions)  (fn-of (list STR STR) INT)
   (q 'builtins 'splitVersion)     (fn-of (list STR) (LIST-OF STR))

   ;; ============================================================================
   ;; builtins.* — paths / IO
   ;; ============================================================================

   (q 'builtins 'toFile)         (fn-of (list STR STR) ANY)
   (q 'builtins 'readFile)       (fn-of (list ANY) STR)
   (q 'builtins 'readDir)        (fn-of (list ANY) (MAP-OF STR STR))
   (q 'builtins 'pathExists)     (fn-of (list ANY) BOOL)
   (q 'builtins 'dirOf)          (fn-of (list ANY) ANY)
   (q 'builtins 'baseNameOf)     (fn-of (list ANY) STR)
   (q 'builtins 'import)         (fn-of (list ANY) ANY)
   (q 'builtins 'scopedImport)   (fn-of (list ANY ANY) ANY)
   (q 'builtins 'fetchurl)       (fn-of (list STR) ANY)
   (q 'builtins 'fetchTarball)   (fn-of (list ANY) ANY)
   (q 'builtins 'fetchGit)       (fn-of (list ANY) ANY)
   (q 'builtins 'fetchTree)      (fn-of (list ANY) ANY)
   (q 'builtins 'filterSource)   (fn-of (list ANY ANY) ANY)
   (q 'builtins 'path)           (fn-of (list ANY) ANY)
   (q 'builtins 'placeholder)    (fn-of (list STR) STR)
   (q 'builtins 'storePath)      (fn-of (list ANY) ANY)
   (q 'builtins 'hashString)     (fn-of (list STR STR) STR)
   (q 'builtins 'hashFile)       (fn-of (list STR ANY) STR)

   ;; ============================================================================
   ;; builtins.* — control / debug
   ;; ============================================================================

   (q 'builtins 'trace)        (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'builtins 'traceVerbose) (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'builtins 'tryEval)      (fn-of (list ANY) (MAP-OF STR ANY))
   (q 'builtins 'throw)        (fn-of (list STR) ANY)
   (q 'builtins 'abort)        (fn-of (list STR) ANY)
   (q 'builtins 'deepSeq)      (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'builtins 'seq)          (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'builtins 'break)        (fn-of (list ANY) ANY)

   ;; ============================================================================
   ;; builtins.* — arithmetic / bit ops
   ;; ============================================================================

   (q 'builtins 'add)        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   (q 'builtins 'sub)        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   (q 'builtins 'mul)        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   (q 'builtins 'div)        (fn-of (list (type-prim 'Number) (type-prim 'Number))
                               (type-prim 'Number))
   (q 'builtins 'bitAnd)     (fn-of (list INT INT) INT)
   (q 'builtins 'bitOr)      (fn-of (list INT INT) INT)
   (q 'builtins 'bitXor)     (fn-of (list INT INT) INT)
   (q 'builtins 'lessThan)   (fn-of (list (type-prim 'Number) (type-prim 'Number)) BOOL)
   (q 'builtins 'floor)      (fn-of (list (type-prim 'Number)) INT)
   (q 'builtins 'ceil)       (fn-of (list (type-prim 'Number)) INT)

   ;; ============================================================================
   ;; builtins.* — system info
   ;; ============================================================================

   (q 'builtins 'currentSystem) STR
   (q 'builtins 'currentTime)   INT
   (q 'builtins 'storeDir)      STR
   (q 'builtins 'nixVersion)    STR
   (q 'builtins 'langVersion)   INT
   (q 'builtins 'nixPath)       ANY

   ;; ============================================================================
   ;; lib.* — NixOS module system (still mostly Any — return is module-shaped)
   ;; ============================================================================

   (q 'lib 'mkIf)            (poly-fn '(A) (list BOOL (tv 'A)) (tv 'A))
   (q 'lib 'mkMerge)         (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   (q 'lib 'mkDefault)       (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'mkForce)         (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'mkOverride)      (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   (q 'lib 'mkBefore)        (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'mkAfter)         (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'mkOrder)         (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   (q 'lib 'mkEnableOption)  (fn-of (list STR) NIXT)
   (q 'lib 'mkOption)        (fn-of (list ANY) NIXT)
   (q 'lib 'mkPackageOption) (fn-of (list ANY ANY ANY) NIXT)
   (q 'lib 'mkRenamedOptionModule) (fn-of (list ANY ANY) ANY)
   (q 'lib 'mkRemovedOptionModule) (fn-of (list ANY STR) ANY)
   (q 'lib 'mkAliasOptionModule)   (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.* — conditional inclusion (parametric)
   ;; ============================================================================

   (q 'lib 'optional)        (poly-fn '(A) (list BOOL (tv 'A)) (LIST-OF (tv 'A)))
   (q 'lib 'optionals)       (poly-fn '(A) (list BOOL (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'optionalString)  (fn-of (list BOOL STR) STR)
   (q 'lib 'optionalAttrs)   (poly-fn '(V) (list BOOL (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))

   ;; ============================================================================
   ;; lib.* — strings
   ;; ============================================================================

   (q 'lib 'concatStrings)        (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'concatStringsSep)     (fn-of (list STR (LIST-OF STR)) STR)
   (q 'lib 'concatMapStrings)     (poly-fn '(A)
                                      (list (type-fn (list (tv 'A)) #f STR)
                                            (LIST-OF (tv 'A)))
                                      STR)
   (q 'lib 'concatMapStringsSep)  (poly-fn '(A)
                                      (list STR
                                            (type-fn (list (tv 'A)) #f STR)
                                            (LIST-OF (tv 'A)))
                                      STR)
   (q 'lib 'concatLines)          (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'concatMapAttrs)       (fn-of (list ANY ANY) ANY)
   (q 'lib 'splitString)          (fn-of (list STR STR) (LIST-OF STR))
   (q 'lib 'hasPrefix)            (fn-of (list STR STR) BOOL)
   (q 'lib 'hasSuffix)            (fn-of (list STR STR) BOOL)
   (q 'lib 'hasInfix)             (fn-of (list STR STR) BOOL)
   (q 'lib 'removePrefix)         (fn-of (list STR STR) STR)
   (q 'lib 'removeSuffix)         (fn-of (list STR STR) STR)
   (q 'lib 'toLower)              (fn-of (list STR) STR)
   (q 'lib 'toUpper)              (fn-of (list STR) STR)
   (q 'lib 'escapeShellArg)       (fn-of (list STR) STR)
   (q 'lib 'escapeShellArgs)      (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'escapeNixString)      (fn-of (list STR) STR)
   (q 'lib 'escapeNixIdentifier)  (fn-of (list STR) STR)
   (q 'lib 'escapeXML)            (fn-of (list STR) STR)
   (q 'lib 'escapeRegex)          (fn-of (list STR) STR)
   (q 'lib 'stringToCharacters)   (fn-of (list STR) (LIST-OF STR))
   (q 'lib 'replaceStrings)       (fn-of (list (LIST-OF STR) (LIST-OF STR) STR) STR)
   (q 'lib 'fixedWidthString)     (fn-of (list INT STR STR) STR)
   (q 'lib 'fixedWidthNumber)     (fn-of (list INT INT) STR)
   (q 'lib 'floatToString)        (fn-of (list (type-prim 'Number)) STR)
   (q 'lib 'boolToString)         (fn-of (list BOOL) STR)
   (q 'lib 'toInt)                (fn-of (list STR) INT)
   (q 'lib 'toIntBase10)          (fn-of (list STR) INT)

   ;; ============================================================================
   ;; lib.* — versions
   ;; ============================================================================

   (q 'lib 'versionAtLeast)       (fn-of (list STR STR) BOOL)
   (q 'lib 'versionOlder)         (fn-of (list STR STR) BOOL)
   (q 'lib 'getName)              (fn-of (list ANY) STR)
   (q 'lib 'getVersion)           (fn-of (list ANY) STR)

   ;; ============================================================================
   ;; lib.* — attrsets (parametric)
   ;; ============================================================================

   (q 'lib 'filterAttrs)            (poly-fn '(V)
                                        (list (type-fn (list STR (tv 'V)) #f BOOL)
                                              (MAP-OF STR (tv 'V)))
                                        (MAP-OF STR (tv 'V)))
   (q 'lib 'filterAttrsRecursive)   (fn-of (list ANY ANY) ANY)
   (q 'lib 'mapAttrs)               (poly-fn '(V W)
                                        (list (type-fn (list STR (tv 'V)) #f (tv 'W))
                                              (MAP-OF STR (tv 'V)))
                                        (MAP-OF STR (tv 'W)))
   (q 'lib '|mapAttrs'|)            (fn-of (list ANY ANY) ANY)
   (q 'lib 'mapAttrsToList)         (poly-fn '(V W)
                                        (list (type-fn (list STR (tv 'V)) #f (tv 'W))
                                              (MAP-OF STR (tv 'V)))
                                        (LIST-OF (tv 'W)))
   (q 'lib 'mapAttrsRecursive)      (fn-of (list ANY ANY) ANY)
   (q 'lib 'mapAttrsRecursiveCond)  (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'concatMapAttrsToList)   (fn-of (list ANY ANY) ANY)
   (q 'lib 'genAttrs)               (poly-fn '(A)
                                        (list (LIST-OF STR)
                                              (type-fn (list STR) #f (tv 'A)))
                                        (MAP-OF STR (tv 'A)))
   (q 'lib 'recursiveUpdate)        (fn-of (list ANY ANY) ANY)
   (q 'lib 'recursiveUpdateUntil)   (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'foldAttrs)              (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'getAttrs)               (poly-fn '(V) (list (LIST-OF STR) (MAP-OF STR (tv 'V)))
                                        (MAP-OF STR (tv 'V)))
   (q 'lib 'attrByPath)             (poly-fn '(A)
                                        (list (LIST-OF STR) (tv 'A) ANY)
                                        (tv 'A))
   (q 'lib 'hasAttrByPath)          (fn-of (list (LIST-OF STR) ANY) BOOL)
   (q 'lib 'setAttrByPath)          (fn-of (list (LIST-OF STR) ANY) ANY)
   (q 'lib 'getAttrFromPath)        (fn-of (list (LIST-OF STR) ANY) ANY)
   (q 'lib 'nameValuePair)          (poly-fn '(A) (list STR (tv 'A)) (MAP-OF STR ANY))
   (q 'lib 'listToAttrs)            (poly-fn '(V) (list (LIST-OF (MAP-OF STR (tv 'V))))
                                        (MAP-OF STR (tv 'V)))
   (q 'lib 'zipAttrs)               (fn-of (list (LIST-OF ANY)) ANY)
   (q 'lib 'zipAttrsWith)           (fn-of (list ANY ANY) ANY)
   (q 'lib 'unionOfDisjoint)        (fn-of (list ANY ANY) ANY)
   (q 'lib 'cartesianProductOfSets) (fn-of (list ANY) ANY)
   (q 'lib 'updateManyAttrsByPath)  (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.* — lists (parametric)
   ;; ============================================================================

   (q 'lib 'flatten)         (poly-fn '(A) (list ANY) (LIST-OF (tv 'A)))
   (q 'lib 'unique)          (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'intersectLists)  (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'A)))
   (q 'lib 'subtractLists)   (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'A)))
   (q 'lib 'reverseList)     (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'take)            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'drop)            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'sublist)         (poly-fn '(A) (list INT INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'last)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   (q 'lib 'init)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'range)           (fn-of (list INT INT) (LIST-OF INT))
   (q 'lib 'imap0)           (poly-fn '(A B)
                                 (list (type-fn (list INT (tv 'A)) #f (tv 'B))
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'B)))
   (q 'lib 'imap1)           (poly-fn '(A B)
                                 (list (type-fn (list INT (tv 'A)) #f (tv 'B))
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'B)))
   (q 'lib 'zipLists)        (fn-of (list ANY ANY) ANY)
   (q 'lib 'zipListsWith)    (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'foldr)           (poly-fn '(A B)
                                 (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   (q 'lib 'foldl)           (poly-fn '(A B)
                                 (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   (q 'lib 'fold)            (poly-fn '(A B)
                                 (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   (q 'lib '|foldl'|)        (poly-fn '(A B)
                                 (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                       (tv 'B) (LIST-OF (tv 'A)))
                                 (tv 'B))
   (q 'lib 'count)           (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 INT)
   (q 'lib 'any)             (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 BOOL)
   (q 'lib 'all)             (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 BOOL)
   (q 'lib 'partition)       (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 (MAP-OF STR (LIST-OF (tv 'A))))
   (q 'lib 'groupBy)         (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f STR)
                                       (LIST-OF (tv 'A)))
                                 (MAP-OF STR (LIST-OF (tv 'A))))
   (q 'lib 'findFirst)       (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       (tv 'A) (LIST-OF (tv 'A)))
                                 (tv 'A))
   (q 'lib 'findFirstIndex)  (poly-fn '(A)
                                 (list (type-fn (list (tv 'A)) #f BOOL)
                                       ANY (LIST-OF (tv 'A)))
                                 INT)
   (q 'lib 'forEach)         (poly-fn '(A B)
                                 (list (LIST-OF (tv 'A))
                                       (type-fn (list (tv 'A)) #f (tv 'B)))
                                 (LIST-OF (tv 'B)))
   (q 'lib 'concatLists)     (poly-fn '(A) (list (LIST-OF (LIST-OF (tv 'A))))
                                 (LIST-OF (tv 'A)))
   (q 'lib 'concatMap)       (poly-fn '(A B)
                                 (list (type-fn (list (tv 'A)) #f (LIST-OF (tv 'B)))
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'B)))
   (q 'lib 'crossLists)      (fn-of (list ANY ANY) ANY)
   (q 'lib 'naturalSort)     (fn-of (list (LIST-OF STR)) (LIST-OF STR))
   (q 'lib 'sort)            (poly-fn '(A)
                                 (list (type-fn (list (tv 'A) (tv 'A)) #f BOOL)
                                       (LIST-OF (tv 'A)))
                                 (LIST-OF (tv 'A)))

   ;; ============================================================================
   ;; lib.* — combinators / trivial
   ;; ============================================================================

   (q 'lib 'id)        (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'const)     (poly-fn '(A B) (list (tv 'A) (tv 'B)) (tv 'A))
   (q 'lib 'flip)      (poly-fn '(A B C)
                           (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'C))
                                 (tv 'B) (tv 'A))
                           (tv 'C))
   (q 'lib 'pipe)      (poly-fn '(A) (list (tv 'A) (LIST-OF ANY)) ANY)
   (q 'lib 'compose)   (fn-of (list ANY ANY) ANY)
   (q 'lib 'throwIf)   (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   (q 'lib 'throwIfNot) (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   (q 'lib 'assertMsg) (fn-of (list BOOL STR) BOOL)
   (q 'lib 'warn)      (poly-fn '(A) (list STR (tv 'A)) (tv 'A))
   (q 'lib 'warnIf)    (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   (q 'lib 'seq)       (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'lib 'deepSeq)   (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'lib 'min)       (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))
   (q 'lib 'max)       (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))

   ;; ============================================================================
   ;; lib.* — modules / overlays
   ;; ============================================================================

   (q 'lib 'evalModules)            (fn-of (list ANY) ANY)
   (q 'lib 'composeExtensions)      (fn-of (list ANY ANY) ANY)
   (q 'lib 'composeManyExtensions)  (fn-of (list (LIST-OF ANY)) ANY)
   (q 'lib 'makeOverridable)        (fn-of (list ANY ANY) ANY)
   (q 'lib 'callPackageWith)        (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'callPackagesWith)       (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'extends)                (fn-of (list ANY ANY) ANY)
   (q 'lib 'fix)                    (poly-fn '(A) (list (type-fn (list (tv 'A)) #f (tv 'A))) (tv 'A))
   (q 'lib '|fix'|)                 (poly-fn '(A) (list (type-fn (list (tv 'A)) #f (tv 'A))) (tv 'A))

   ;; ============================================================================
   ;; lib.* — sources / paths
   ;; ============================================================================

   (q 'lib 'cleanSource)              (fn-of (list ANY) ANY)
   (q 'lib 'cleanSourceWith)          (fn-of (list ANY) ANY)
   (q 'lib 'sourceByRegex)            (fn-of (list ANY (LIST-OF STR)) ANY)
   (q 'lib 'sourceFilesBySuffices)    (fn-of (list ANY (LIST-OF STR)) ANY)
   (q 'lib 'pathHasContext)           (fn-of (list ANY) BOOL)
   (q 'lib 'getLib)                   (fn-of (list ANY) ANY)
   (q 'lib 'getBin)                   (fn-of (list ANY) ANY)
   (q 'lib 'getDev)                   (fn-of (list ANY) ANY)
   (q 'lib 'getMan)                   (fn-of (list ANY) ANY)
   (q 'lib 'getOutput)                (fn-of (list STR ANY) ANY)
   (q 'lib 'makeBinPath)              (fn-of (list (LIST-OF ANY)) STR)
   (q 'lib 'makeLibraryPath)          (fn-of (list (LIST-OF ANY)) STR)
   (q 'lib 'makeSearchPath)           (fn-of (list STR (LIST-OF ANY)) STR)
   (q 'lib 'makeSearchPathOutput)     (fn-of (list STR STR (LIST-OF ANY)) STR)

   ;; ============================================================================
   ;; lib.types.* — opaque NixType values + parametric helpers
   ;; ============================================================================

   (q 'lib 'types.bool)          NIXT
   (q 'lib 'types.str)           NIXT
   (q 'lib 'types.nonEmptyStr)   NIXT
   (q 'lib 'types.singleLineStr) NIXT
   (q 'lib 'types.strMatching)   (fn-of (list STR) NIXT)
   (q 'lib 'types.int)           NIXT
   (q 'lib 'types.float)         NIXT
   (q 'lib 'types.number)        NIXT
   (q 'lib 'types.path)          NIXT
   (q 'lib 'types.package)       NIXT
   (q 'lib 'types.port)          NIXT
   (q 'lib 'types.anything)      NIXT
   (q 'lib 'types.unspecified)   NIXT
   (q 'lib 'types.raw)           NIXT
   (q 'lib 'types.attrs)         NIXT
   (q 'lib 'types.lines)         NIXT
   (q 'lib 'types.commas)        NIXT
   (q 'lib 'types.envVar)        NIXT
   (q 'lib 'types.shellPackage)  NIXT
   (q 'lib 'types.listOf)        (fn-of (list NIXT) NIXT)
   (q 'lib 'types.attrsOf)       (fn-of (list NIXT) NIXT)
   (q 'lib 'types.lazyAttrsOf)   (fn-of (list NIXT) NIXT)
   (q 'lib 'types.nullOr)        (fn-of (list NIXT) NIXT)
   (q 'lib 'types.uniq)          (fn-of (list NIXT) NIXT)
   (q 'lib 'types.unique)        (fn-of (list ANY NIXT) NIXT)
   (q 'lib 'types.enum)          (fn-of (list (LIST-OF ANY)) NIXT)
   (q 'lib 'types.submodule)     (fn-of (list ANY) NIXT)
   (q 'lib 'types.submoduleWith) (fn-of (list ANY) NIXT)
   (q 'lib 'types.deferredModule) NIXT
   (q 'lib 'types.either)        (fn-of (list NIXT NIXT) NIXT)
   (q 'lib 'types.oneOf)         (fn-of (list (LIST-OF NIXT)) NIXT)
   (q 'lib 'types.coercedTo)     (fn-of (list NIXT ANY NIXT) NIXT)
   (q 'lib 'types.functionTo)    (fn-of (list NIXT) NIXT)
   (q 'lib 'types.addCheck)      (fn-of (list NIXT ANY) NIXT)
   (q 'lib 'types.ints.unsigned) NIXT
   (q 'lib 'types.ints.positive) NIXT
   (q 'lib 'types.ints.between)  (fn-of (list INT INT) NIXT)
   (q 'lib 'types.ints.u8)       NIXT
   (q 'lib 'types.ints.u16)      NIXT
   (q 'lib 'types.ints.u32)      NIXT
   (q 'lib 'types.ints.u64)      NIXT
   (q 'lib 'types.ints.s8)       NIXT
   (q 'lib 'types.ints.s16)      NIXT
   (q 'lib 'types.ints.s32)      NIXT
   (q 'lib 'types.ints.s64)      NIXT

   ;; ============================================================================
   ;; lib.attrsets.* — qualified forms (in addition to lib/X)
   ;; ============================================================================

   (q 'lib 'attrsets.attrNames)         (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF STR))
   (q 'lib 'attrsets.attrValues)        (poly-fn '(V) (list (MAP-OF STR (tv 'V))) (LIST-OF (tv 'V)))
   (q 'lib 'attrsets.hasAttr)           (poly-fn '(V) (list STR (MAP-OF STR (tv 'V))) BOOL)
   (q 'lib 'attrsets.getAttrs)          (poly-fn '(V) (list (LIST-OF STR) (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))
   (q 'lib 'attrsets.filterAttrs)       (poly-fn '(V) (list (type-fn (list STR (tv 'V)) #f BOOL) (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))
   (q 'lib 'attrsets.mapAttrs)          (poly-fn '(V W) (list (type-fn (list STR (tv 'V)) #f (tv 'W)) (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'W)))
   (q 'lib 'attrsets.mapAttrsToList)    (poly-fn '(V W) (list (type-fn (list STR (tv 'V)) #f (tv 'W)) (MAP-OF STR (tv 'V))) (LIST-OF (tv 'W)))
   (q 'lib 'attrsets.foldlAttrs)        (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'attrsets.attrByPath)        (fn-of (list (LIST-OF STR) ANY ANY) ANY)
   (q 'lib 'attrsets.hasAttrByPath)     (fn-of (list (LIST-OF STR) ANY) BOOL)
   (q 'lib 'attrsets.setAttrByPath)     (fn-of (list (LIST-OF STR) ANY) ANY)
   (q 'lib 'attrsets.recursiveUpdate)   (fn-of (list ANY ANY) ANY)
   (q 'lib 'attrsets.nameValuePair)     (poly-fn '(V) (list STR (tv 'V)) (MAP-OF STR ANY))
   (q 'lib 'attrsets.listToAttrs)       (poly-fn '(V) (list (LIST-OF (MAP-OF STR (tv 'V)))) (MAP-OF STR (tv 'V)))
   (q 'lib 'attrsets.cartesianProduct)  (fn-of (list ANY) (LIST-OF ANY))
   (q 'lib 'attrsets.zipAttrs)          (fn-of (list (LIST-OF ANY)) ANY)
   (q 'lib 'attrsets.zipAttrsWith)      (fn-of (list ANY ANY) ANY)
   (q 'lib 'attrsets.optionalAttrs)     (poly-fn '(V) (list BOOL (MAP-OF STR (tv 'V))) (MAP-OF STR (tv 'V)))
   (q 'lib 'attrsets.removeAttrs)       (poly-fn '(V) (list (MAP-OF STR (tv 'V)) (LIST-OF STR)) (MAP-OF STR (tv 'V)))

   ;; ============================================================================
   ;; lib.lists.* — qualified forms
   ;; ============================================================================

   (q 'lib 'lists.head)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   (q 'lib 'lists.tail)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.last)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   (q 'lib 'lists.init)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.length)          (poly-fn '(A) (list (LIST-OF (tv 'A))) INT)
   (q 'lib 'lists.elem)            (poly-fn '(A) (list (tv 'A) (LIST-OF (tv 'A))) BOOL)
   (q 'lib 'lists.elemAt)          (poly-fn '(A) (list (LIST-OF (tv 'A)) INT) (tv 'A))
   (q 'lib 'lists.map)             (poly-fn '(A B) (list (type-fn (list (tv 'A)) #f (tv 'B)) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))
   (q 'lib 'lists.filter)          (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.foldl)           (poly-fn '(A B) (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B)) (tv 'B) (LIST-OF (tv 'A))) (tv 'B))
   (q 'lib 'lists.foldr)           (poly-fn '(A B) (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'B)) (tv 'B) (LIST-OF (tv 'A))) (tv 'B))
   (q 'lib 'lists.any)             (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) BOOL)
   (q 'lib 'lists.all)             (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) BOOL)
   (q 'lib 'lists.count)           (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) INT)
   (q 'lib 'lists.take)            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.drop)            (poly-fn '(A) (list INT (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.reverseList)     (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.sort)            (poly-fn '(A) (list (type-fn (list (tv 'A) (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.unique)          (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.partition)       (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (LIST-OF (tv 'A))) (MAP-OF STR (LIST-OF (tv 'A))))
   (q 'lib 'lists.groupBy)         (poly-fn '(A) (list (type-fn (list (tv 'A)) #f STR) (LIST-OF (tv 'A))) (MAP-OF STR (LIST-OF (tv 'A))))
   (q 'lib 'lists.flatten)         (fn-of (list ANY) ANY)
   (q 'lib 'lists.range)           (fn-of (list INT INT) (LIST-OF INT))
   (q 'lib 'lists.zipLists)        (fn-of (list ANY ANY) ANY)
   (q 'lib 'lists.concatLists)     (poly-fn '(A) (list (LIST-OF (LIST-OF (tv 'A)))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.concatMap)       (poly-fn '(A B) (list (type-fn (list (tv 'A)) #f (LIST-OF (tv 'B))) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))
   (q 'lib 'lists.intersectLists)  (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.subtractLists)   (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   (q 'lib 'lists.findFirst)       (poly-fn '(A) (list (type-fn (list (tv 'A)) #f BOOL) (tv 'A) (LIST-OF (tv 'A))) (tv 'A))
   (q 'lib 'lists.imap0)           (poly-fn '(A B) (list (type-fn (list INT (tv 'A)) #f (tv 'B)) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))
   (q 'lib 'lists.imap1)           (poly-fn '(A B) (list (type-fn (list INT (tv 'A)) #f (tv 'B)) (LIST-OF (tv 'A))) (LIST-OF (tv 'B)))

   ;; ============================================================================
   ;; lib.strings.* — qualified
   ;; ============================================================================

   (q 'lib 'strings.concatStrings)     (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'strings.concatStringsSep)  (fn-of (list STR (LIST-OF STR)) STR)
   (q 'lib 'strings.concatMapStrings)  (poly-fn '(A) (list (type-fn (list (tv 'A)) #f STR) (LIST-OF (tv 'A))) STR)
   (q 'lib 'strings.concatLines)       (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'strings.hasPrefix)         (fn-of (list STR STR) BOOL)
   (q 'lib 'strings.hasSuffix)         (fn-of (list STR STR) BOOL)
   (q 'lib 'strings.hasInfix)          (fn-of (list STR STR) BOOL)
   (q 'lib 'strings.removePrefix)      (fn-of (list STR STR) STR)
   (q 'lib 'strings.removeSuffix)      (fn-of (list STR STR) STR)
   (q 'lib 'strings.replaceStrings)    (fn-of (list (LIST-OF STR) (LIST-OF STR) STR) STR)
   (q 'lib 'strings.splitString)       (fn-of (list STR STR) (LIST-OF STR))
   (q 'lib 'strings.stringToCharacters) (fn-of (list STR) (LIST-OF STR))
   (q 'lib 'strings.stringLength)      (fn-of (list STR) INT)
   (q 'lib 'strings.substring)         (fn-of (list INT INT STR) STR)
   (q 'lib 'strings.toLower)           (fn-of (list STR) STR)
   (q 'lib 'strings.toUpper)           (fn-of (list STR) STR)
   (q 'lib 'strings.escapeNixString)   (fn-of (list STR) STR)
   (q 'lib 'strings.escapeShellArg)    (fn-of (list STR) STR)
   (q 'lib 'strings.escapeShellArgs)   (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'strings.escapeURL)         (fn-of (list STR) STR)
   (q 'lib 'strings.escapeXML)         (fn-of (list STR) STR)
   (q 'lib 'strings.escapeRegex)       (fn-of (list STR) STR)
   (q 'lib 'strings.fixedWidthString)  (fn-of (list INT STR STR) STR)
   (q 'lib 'strings.fixedWidthNumber)  (fn-of (list INT INT) STR)
   (q 'lib 'strings.toInt)             (fn-of (list STR) INT)
   (q 'lib 'strings.toIntBase10)       (fn-of (list STR) INT)
   (q 'lib 'strings.versionAtLeast)    (fn-of (list STR STR) BOOL)
   (q 'lib 'strings.versionOlder)      (fn-of (list STR STR) BOOL)
   (q 'lib 'strings.normalizePath)     (fn-of (list STR) STR)
   (q 'lib 'strings.optionalString)    (fn-of (list BOOL STR) STR)

   ;; ============================================================================
   ;; lib.path.*
   ;; ============================================================================

   (q 'lib 'path.append)           (fn-of (list ANY STR) ANY)
   (q 'lib 'path.removePrefix)     (fn-of (list ANY ANY) ANY)
   (q 'lib 'path.hasPrefix)        (fn-of (list ANY ANY) BOOL)
   (q 'lib 'path.subpath.isValid)  (fn-of (list ANY) BOOL)
   (q 'lib 'path.subpath.normalise) (fn-of (list ANY) ANY)
   (q 'lib 'path.subpath.join)     (fn-of (list ANY) ANY)
   (q 'lib 'path.subpath.components) (fn-of (list ANY) (LIST-OF STR))

   ;; ============================================================================
   ;; lib.fileset.* (Nix 23.11+)
   ;; ============================================================================

   (q 'lib 'fileset.toSource)      (fn-of (list ANY) ANY)
   (q 'lib 'fileset.union)         (fn-of (list ANY ANY) ANY)
   (q 'lib 'fileset.unions)        (fn-of (list (LIST-OF ANY)) ANY)
   (q 'lib 'fileset.intersection)  (fn-of (list ANY ANY) ANY)
   (q 'lib 'fileset.difference)    (fn-of (list ANY ANY) ANY)
   (q 'lib 'fileset.fromSource)    (fn-of (list ANY) ANY)
   (q 'lib 'fileset.maybeMissing)  (fn-of (list ANY) ANY)
   (q 'lib 'fileset.gitTracked)    (fn-of (list ANY) ANY)
   (q 'lib 'fileset.fileFilter)    (fn-of (list ANY ANY) ANY)
   (q 'lib 'fileset.trace)         (fn-of (list ANY) ANY)
   (q 'lib 'fileset.traceVal)      (fn-of (list ANY) ANY)

   ;; ============================================================================
   ;; lib.generators.*
   ;; ============================================================================

   (q 'lib 'generators.toINI)           (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toINIWithGlobalSection) (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toGitINI)        (fn-of (list ANY) STR)
   (q 'lib 'generators.toJSON)          (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toYAML)          (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toPretty)        (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toKeyValue)      (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toPlist)         (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toLua)           (fn-of (list ANY ANY) STR)
   (q 'lib 'generators.toDhall)         (fn-of (list ANY ANY) STR)

   ;; ============================================================================
   ;; lib.modules.*
   ;; ============================================================================

   (q 'lib 'modules.evalModules)        (fn-of (list ANY) ANY)
   (q 'lib 'modules.mkOption)           (fn-of (list ANY) NIXT)
   (q 'lib 'modules.mkIf)               (poly-fn '(A) (list BOOL (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkForce)            (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkDefault)          (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkOverride)         (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkMerge)            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   (q 'lib 'modules.mkOptionDefault)    (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkBefore)           (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkAfter)            (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkOrder)            (poly-fn '(A) (list INT (tv 'A)) (tv 'A))
   (q 'lib 'modules.mkRemovedOptionModule)  (fn-of (list ANY STR) ANY)
   (q 'lib 'modules.mkRenamedOptionModule)  (fn-of (list ANY ANY) ANY)
   (q 'lib 'modules.mkChangedOptionModule)  (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'modules.mkAliasOptionModule)    (fn-of (list ANY ANY) ANY)
   (q 'lib 'modules.mkAliasOptionModuleMD)  (fn-of (list ANY ANY) ANY)
   (q 'lib 'modules.mkAliasOptionModuleWithPriority) (fn-of (list ANY ANY) ANY)
   (q 'lib 'modules.doRename)           (fn-of (list ANY) ANY)
   (q 'lib 'modules.filterOverrides)    (fn-of (list (LIST-OF ANY)) (LIST-OF ANY))

   ;; ============================================================================
   ;; lib.options.*
   ;; ============================================================================

   (q 'lib 'options.mkOption)           (fn-of (list ANY) NIXT)
   (q 'lib 'options.mkEnableOption)     (fn-of (list STR) NIXT)
   (q 'lib 'options.mkPackageOption)    (fn-of (list ANY ANY ANY) NIXT)
   (q 'lib 'options.mkSinkUndeclaredOptions) (fn-of (list ANY) ANY)
   (q 'lib 'options.literalExpression)  (fn-of (list STR) ANY)
   (q 'lib 'options.literalMD)          (fn-of (list STR) ANY)
   (q 'lib 'options.literalDocBook)     (fn-of (list STR) ANY)
   (q 'lib 'options.showOption)         (fn-of (list (LIST-OF STR)) STR)
   (q 'lib 'options.unknownModule)      ANY
   (q 'lib 'options.mergeDefaultOption) (fn-of (list ANY ANY) ANY)
   (q 'lib 'options.mergeOneOption)     (fn-of (list ANY ANY) ANY)
   (q 'lib 'options.mergeEqualOption)   (fn-of (list ANY ANY) ANY)
   (q 'lib 'options.mergeUniqueOption)  (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.customisation.*
   ;; ============================================================================

   (q 'lib 'customisation.makeOverridable)   (fn-of (list ANY ANY) ANY)
   (q 'lib 'customisation.callPackageWith)   (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'customisation.callPackagesWith)  (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'customisation.extendDerivation)  (fn-of (list ANY ANY ANY) ANY)
   (q 'lib 'customisation.hydraJob)          (fn-of (list ANY) ANY)
   (q 'lib 'customisation.makeScope)         (fn-of (list ANY ANY) ANY)
   (q 'lib 'customisation.makeScopeWithSplicing) (fn-of (list ANY ANY ANY ANY ANY) ANY)
   (q 'lib 'customisation.overrideDerivation) (fn-of (list ANY ANY) ANY)

   ;; ============================================================================
   ;; lib.debug.*
   ;; ============================================================================

   (q 'lib 'debug.traceIf)            (poly-fn '(A) (list BOOL ANY (tv 'A)) (tv 'A))
   (q 'lib 'debug.traceVal)           (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'debug.traceValFn)         (poly-fn '(A) (list (type-fn (list (tv 'A)) #f ANY) (tv 'A)) (tv 'A))
   (q 'lib 'debug.traceSeq)           (poly-fn '(A) (list ANY (tv 'A)) (tv 'A))
   (q 'lib 'debug.traceSeqN)          (poly-fn '(A) (list INT ANY (tv 'A)) (tv 'A))
   (q 'lib 'debug.traceFnSeqN)        (poly-fn '(A B) (list INT (type-fn (list (tv 'A)) #f ANY) (tv 'A) (tv 'B)) (tv 'B))
   (q 'lib 'debug.runTests)           (fn-of (list ANY) ANY)

   ;; ============================================================================
   ;; lib.cli.*
   ;; ============================================================================

   (q 'lib 'cli.toGNUCommandLine)            (fn-of (list ANY ANY) (LIST-OF STR))
   (q 'lib 'cli.toGNUCommandLineShell)       (fn-of (list ANY ANY) STR)

   ;; ============================================================================
   ;; lib.licenses.* — opaque License values
   ;; ============================================================================

   (q 'lib 'licenses.mit)         ANY
   (q 'lib 'licenses.bsd2)        ANY
   (q 'lib 'licenses.bsd3)        ANY
   (q 'lib 'licenses.gpl2)        ANY
   (q 'lib 'licenses.gpl2Only)    ANY
   (q 'lib 'licenses.gpl2Plus)    ANY
   (q 'lib 'licenses.gpl3)        ANY
   (q 'lib 'licenses.gpl3Only)    ANY
   (q 'lib 'licenses.gpl3Plus)    ANY
   (q 'lib 'licenses.lgpl2)       ANY
   (q 'lib 'licenses.lgpl2Plus)   ANY
   (q 'lib 'licenses.lgpl3)       ANY
   (q 'lib 'licenses.lgpl3Plus)   ANY
   (q 'lib 'licenses.apsl20)      ANY
   (q 'lib 'licenses.asl20)       ANY
   (q 'lib 'licenses.cc-by-30)    ANY
   (q 'lib 'licenses.cc-by-40)    ANY
   (q 'lib 'licenses.cc-by-sa-30) ANY
   (q 'lib 'licenses.cc-by-sa-40) ANY
   (q 'lib 'licenses.cc0)         ANY
   (q 'lib 'licenses.isc)         ANY
   (q 'lib 'licenses.mpl20)       ANY
   (q 'lib 'licenses.unfree)      ANY
   (q 'lib 'licenses.unfreeRedistributable) ANY
   (q 'lib 'licenses.publicDomain) ANY
   (q 'lib 'licenses.zlib)        ANY
   (q 'lib 'licenses.wtfpl)       ANY
   (q 'lib 'licenses.unlicense)   ANY

   ;; ============================================================================
   ;; lib.platforms.* — opaque platform-set values
   ;; ============================================================================

   (q 'lib 'platforms.all)         (LIST-OF STR)
   (q 'lib 'platforms.linux)       (LIST-OF STR)
   (q 'lib 'platforms.darwin)      (LIST-OF STR)
   (q 'lib 'platforms.unix)        (LIST-OF STR)
   (q 'lib 'platforms.x86_64)      (LIST-OF STR)
   (q 'lib 'platforms.aarch64)     (LIST-OF STR)
   (q 'lib 'platforms.i686)        (LIST-OF STR)
   (q 'lib 'platforms.x86)         (LIST-OF STR)
   (q 'lib 'platforms.arm)         (LIST-OF STR)
   (q 'lib 'platforms.windows)     (LIST-OF STR)
   (q 'lib 'platforms.freebsd)     (LIST-OF STR)
   (q 'lib 'platforms.openbsd)     (LIST-OF STR)
   (q 'lib 'platforms.netbsd)      (LIST-OF STR)
   (q 'lib 'platforms.cygwin)      (LIST-OF STR)
   (q 'lib 'platforms.mips)        (LIST-OF STR)
   (q 'lib 'platforms.s390x)       (LIST-OF STR)
   (q 'lib 'platforms.riscv)       (LIST-OF STR)
   (q 'lib 'platforms.riscv32)     (LIST-OF STR)
   (q 'lib 'platforms.riscv64)     (LIST-OF STR)
   (q 'lib 'platforms.power)       (LIST-OF STR)
   (q 'lib 'platforms.power64)     (LIST-OF STR)
   (q 'lib 'platforms.ppc64)       (LIST-OF STR)
   (q 'lib 'platforms.ppc64le)     (LIST-OF STR)
   (q 'lib 'platforms.wasi)        (LIST-OF STR)

   ;; ============================================================================
   ;; lib.systems.*
   ;; ============================================================================

   (q 'lib 'systems.elaborate)         (fn-of (list ANY) ANY)
   (q 'lib 'systems.parse.parseSystem) (fn-of (list STR) ANY)
   (q 'lib 'systems.parse.tripleFromSystem) (fn-of (list ANY) STR)
   (q 'lib 'systems.examples.aarch64-multiplatform) ANY
   (q 'lib 'systems.examples.gnu64)    ANY
   (q 'lib 'systems.examples.musl64)   ANY
   (q 'lib 'systems.flakeExposed)      (LIST-OF STR)
   (q 'lib 'systems.doubles.all)       (LIST-OF STR)

   ;; ============================================================================
   ;; lib.maintainers.* — opaque maintainer values (sparse; only generic shape)
   ;; ============================================================================
   ;; Don't enumerate; user can write lib/maintainers.tom etc. and they'll
   ;; type-check via the "/" qualified-call fallback as ANY.

   ;; ============================================================================
   ;; lib.* — additional top-level helpers
   ;; ============================================================================

   (q 'lib 'trivial.id)            (poly-fn '(A) (list (tv 'A)) (tv 'A))
   (q 'lib 'trivial.const)         (poly-fn '(A B) (list (tv 'A) (tv 'B)) (tv 'A))
   (q 'lib 'trivial.flip)          (poly-fn '(A B C) (list (type-fn (list (tv 'A) (tv 'B)) #f (tv 'C)) (tv 'B) (tv 'A)) (tv 'C))
   (q 'lib 'trivial.pipe)          (poly-fn '(A) (list (tv 'A) (LIST-OF ANY)) ANY)
   (q 'lib 'trivial.compose)       (fn-of (list ANY ANY) ANY)
   (q 'lib 'trivial.warn)          (poly-fn '(A) (list STR (tv 'A)) (tv 'A))
   (q 'lib 'trivial.warnIf)        (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   (q 'lib 'trivial.throwIf)       (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   (q 'lib 'trivial.throwIfNot)    (poly-fn '(A) (list BOOL STR (tv 'A)) (tv 'A))
   (q 'lib 'trivial.boolToString)  (fn-of (list BOOL) STR)
   (q 'lib 'trivial.bitAnd)        (fn-of (list INT INT) INT)
   (q 'lib 'trivial.bitOr)         (fn-of (list INT INT) INT)
   (q 'lib 'trivial.bitXor)        (fn-of (list INT INT) INT)
   (q 'lib 'trivial.min)           (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))
   (q 'lib 'trivial.max)           (poly-fn '(A) (list (tv 'A) (tv 'A)) (tv 'A))

   ;; ============================================================================
   ;; pkgs.dockerTools — image-build derivations. Attrset shapes are dockerTools-
   ;; specific and complex; typed as NixType (opaque) for now. Typed records for
   ;; the attrsets are a deferred follow-up — build them if typo-debugging on
   ;; dockerTools attrsets becomes painful in real use.
   ;; ============================================================================

   'pkgs.dockerTools.buildLayeredImage   (fn-of (list NIXT) NIXT)
   'pkgs.dockerTools.buildImage          (fn-of (list NIXT) NIXT)
   'pkgs.dockerTools.streamLayeredImage  (fn-of (list NIXT) NIXT)
   'pkgs.dockerTools.pullImage           (fn-of (list NIXT) NIXT)))

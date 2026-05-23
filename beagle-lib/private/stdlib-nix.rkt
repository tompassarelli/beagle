#lang racket/base

;; Nix-specific stdlib type declarations.
;; Maps Nix builtins and lib.* functions to Beagle types.

(require "types.rkt")

(provide STDLIB-NIX)

(define (fn-of params ret)
  (type-fn (map (lambda (p) (if (type? p) p (type-prim p))) params)
           #f
           (if (type? ret) ret (type-prim ret))))

(define (fn-of/rest params rest-t ret)
  (type-fn (map (lambda (p) (if (type? p) p (type-prim p))) params)
           (if (type? rest-t) rest-t (type-prim rest-t))
           (if (type? ret) ret (type-prim ret))))

;; Shorthands
(define ANY (type-prim 'Any))
(define STR (type-prim 'String))
(define BOOL (type-prim 'Bool))
(define INT (type-prim 'Int))
(define NIXT (type-prim 'NixType))
(define (LIST-OF t) (type-app 'List (list (if (type? t) t (type-prim t)))))
(define (VEC-OF t)  (type-app 'Vec  (list (if (type? t) t (type-prim t)))))
(define (MAP-OF k v) (type-app 'Map (list (if (type? k) k (type-prim k))
                                          (if (type? v) v (type-prim v)))))
(define (NIXT-OF t) (type-app 'NixType (list (if (type? t) t (type-prim t)))))

(define STDLIB-NIX
  (hash
   ;; --- builtins.* (list/seq) -------------------------------------------------
   'builtins/length      (fn-of (list ANY) INT)
   'builtins/head        (fn-of (list ANY) ANY)
   'builtins/tail        (fn-of (list ANY) ANY)
   'builtins/elemAt      (fn-of (list ANY INT) ANY)
   'builtins/elem        (fn-of (list ANY ANY) BOOL)
   'builtins/map         (fn-of (list ANY ANY) ANY)
   'builtins/filter      (fn-of (list ANY ANY) ANY)
   'builtins/foldl       (fn-of (list ANY ANY ANY) ANY)
   'builtins/foldl'      (fn-of (list ANY ANY ANY) ANY)
   'builtins/sort        (fn-of (list ANY ANY) ANY)
   'builtins/concatLists (fn-of (list ANY) ANY)
   'builtins/concatMap   (fn-of (list ANY ANY) ANY)
   'builtins/genList     (fn-of (list ANY INT) ANY)
   'builtins/all         (fn-of (list ANY ANY) BOOL)
   'builtins/any         (fn-of (list ANY ANY) BOOL)
   'builtins/partition   (fn-of (list ANY ANY) ANY)
   'builtins/groupBy     (fn-of (list ANY ANY) ANY)

   ;; --- builtins.* (attrset) --------------------------------------------------
   'builtins/attrNames       (fn-of (list ANY) ANY)
   'builtins/attrValues      (fn-of (list ANY) ANY)
   'builtins/hasAttr         (fn-of (list STR ANY) BOOL)
   'builtins/getAttr         (fn-of (list STR ANY) ANY)
   'builtins/removeAttrs     (fn-of (list ANY ANY) ANY)
   'builtins/intersectAttrs  (fn-of (list ANY ANY) ANY)
   'builtins/mapAttrs        (fn-of (list ANY ANY) ANY)
   'builtins/catAttrs        (fn-of (list STR ANY) ANY)
   'builtins/listToAttrs     (fn-of (list ANY) ANY)
   'builtins/zipAttrsWith    (fn-of (list ANY ANY) ANY)
   'builtins/functionArgs    (fn-of (list ANY) ANY)

   ;; --- builtins.* (type checks) ---------------------------------------------
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

   ;; --- builtins.* (string) ---------------------------------------------------
   'builtins/toString         (fn-of (list ANY) STR)
   'builtins/toJSON           (fn-of (list ANY) STR)
   'builtins/fromJSON         (fn-of (list STR) ANY)
   'builtins/toXML            (fn-of (list ANY) STR)
   'builtins/replaceStrings   (fn-of (list ANY ANY STR) STR)
   'builtins/substring        (fn-of (list INT INT STR) STR)
   'builtins/stringLength     (fn-of (list STR) INT)
   'builtins/split            (fn-of (list STR STR) ANY)
   'builtins/match            (fn-of (list STR STR) ANY)
   'builtins/concatStringsSep (fn-of (list STR ANY) STR)
   'builtins/parseDrvName     (fn-of (list STR) ANY)
   'builtins/compareVersions  (fn-of (list STR STR) INT)
   'builtins/splitVersion     (fn-of (list STR) ANY)

   ;; --- builtins.* (paths/IO) -------------------------------------------------
   'builtins/toFile         (fn-of (list STR STR) ANY)
   'builtins/readFile       (fn-of (list ANY) STR)
   'builtins/readDir        (fn-of (list ANY) ANY)
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

   ;; --- builtins.* (control) --------------------------------------------------
   'builtins/trace      (fn-of (list ANY ANY) ANY)
   'builtins/traceVerbose (fn-of (list ANY ANY) ANY)
   'builtins/tryEval    (fn-of (list ANY) ANY)
   'builtins/throw      (fn-of (list STR) ANY)
   'builtins/abort      (fn-of (list STR) ANY)
   'builtins/deepSeq    (fn-of (list ANY ANY) ANY)
   'builtins/seq        (fn-of (list ANY ANY) ANY)
   'builtins/break      (fn-of (list ANY) ANY)

   ;; --- builtins.* (arithmetic) -----------------------------------------------
   'builtins/add        (fn-of (list ANY ANY) ANY)
   'builtins/sub        (fn-of (list ANY ANY) ANY)
   'builtins/mul        (fn-of (list ANY ANY) ANY)
   'builtins/div        (fn-of (list ANY ANY) ANY)
   'builtins/bitAnd     (fn-of (list INT INT) INT)
   'builtins/bitOr      (fn-of (list INT INT) INT)
   'builtins/bitXor     (fn-of (list INT INT) INT)
   'builtins/lessThan   (fn-of (list ANY ANY) BOOL)
   'builtins/floor      (fn-of (list ANY) INT)
   'builtins/ceil       (fn-of (list ANY) INT)

   ;; --- builtins.* (system info) ----------------------------------------------
   'builtins/currentSystem (type-prim 'String)
   'builtins/currentTime   (type-prim 'Int)
   'builtins/storeDir      (type-prim 'String)
   'builtins/nixVersion    (type-prim 'String)
   'builtins/langVersion   (type-prim 'Int)
   'builtins/nixPath       ANY

   ;; --- lib.* (NixOS module system) ------------------------------------------
   'lib/mkIf            (fn-of (list BOOL ANY) ANY)
   'lib/mkMerge         (fn-of (list ANY) ANY)
   'lib/mkDefault       (fn-of (list ANY) ANY)
   'lib/mkForce         (fn-of (list ANY) ANY)
   'lib/mkOverride      (fn-of (list INT ANY) ANY)
   'lib/mkBefore        (fn-of (list ANY) ANY)
   'lib/mkAfter         (fn-of (list ANY) ANY)
   'lib/mkOrder         (fn-of (list INT ANY) ANY)
   'lib/mkEnableOption  (fn-of (list STR) NIXT)
   'lib/mkOption        (fn-of (list ANY) NIXT)
   'lib/mkPackageOption (fn-of (list ANY ANY ANY) NIXT)
   'lib/mkRenamedOptionModule (fn-of (list ANY ANY) ANY)
   'lib/mkRemovedOptionModule (fn-of (list ANY STR) ANY)
   'lib/mkAliasOptionModule   (fn-of (list ANY ANY) ANY)

   ;; --- lib.* (conditional inclusion) -----------------------------------------
   'lib/optional        (fn-of (list BOOL ANY) ANY)
   'lib/optionals       (fn-of (list BOOL ANY) ANY)
   'lib/optionalString  (fn-of (list BOOL STR) STR)
   'lib/optionalAttrs   (fn-of (list BOOL ANY) ANY)

   ;; --- lib.* (strings) -------------------------------------------------------
   'lib/concatStrings        (fn-of (list ANY) STR)
   'lib/concatStringsSep     (fn-of (list STR ANY) STR)
   'lib/concatMapStrings     (fn-of (list ANY ANY) STR)
   'lib/concatMapStringsSep  (fn-of (list STR ANY ANY) STR)
   'lib/concatLines          (fn-of (list ANY) STR)
   'lib/concatMapAttrs       (fn-of (list ANY ANY) ANY)
   'lib/splitString          (fn-of (list STR STR) ANY)
   'lib/hasPrefix            (fn-of (list STR STR) BOOL)
   'lib/hasSuffix            (fn-of (list STR STR) BOOL)
   'lib/hasInfix             (fn-of (list STR STR) BOOL)
   'lib/removePrefix         (fn-of (list STR STR) STR)
   'lib/removeSuffix         (fn-of (list STR STR) STR)
   'lib/toLower              (fn-of (list STR) STR)
   'lib/toUpper              (fn-of (list STR) STR)
   'lib/escapeShellArg       (fn-of (list STR) STR)
   'lib/escapeShellArgs      (fn-of (list ANY) STR)
   'lib/escapeNixString      (fn-of (list STR) STR)
   'lib/escapeNixIdentifier  (fn-of (list STR) STR)
   'lib/escapeXML            (fn-of (list STR) STR)
   'lib/escapeRegex          (fn-of (list STR) STR)
   'lib/stringToCharacters   (fn-of (list STR) ANY)
   'lib/replaceStrings       (fn-of (list ANY ANY STR) STR)
   'lib/fixedWidthString     (fn-of (list INT STR STR) STR)
   'lib/fixedWidthNumber     (fn-of (list INT INT) STR)
   'lib/floatToString        (fn-of (list ANY) STR)
   'lib/boolToString         (fn-of (list BOOL) STR)
   'lib/toInt                (fn-of (list STR) INT)
   'lib/toIntBase10          (fn-of (list STR) INT)

   ;; --- lib.* (versions) ------------------------------------------------------
   'lib/versionAtLeast       (fn-of (list STR STR) BOOL)
   'lib/versionOlder         (fn-of (list STR STR) BOOL)
   'lib/getName              (fn-of (list ANY) STR)
   'lib/getVersion           (fn-of (list ANY) STR)

   ;; --- lib.* (attrsets) ------------------------------------------------------
   'lib/filterAttrs            (fn-of (list ANY ANY) ANY)
   'lib/filterAttrsRecursive   (fn-of (list ANY ANY) ANY)
   'lib/mapAttrs               (fn-of (list ANY ANY) ANY)
   'lib/mapAttrs'              (fn-of (list ANY ANY) ANY)
   'lib/mapAttrsToList         (fn-of (list ANY ANY) ANY)
   'lib/mapAttrsRecursive      (fn-of (list ANY ANY) ANY)
   'lib/mapAttrsRecursiveCond  (fn-of (list ANY ANY ANY) ANY)
   'lib/concatMapAttrsToList   (fn-of (list ANY ANY) ANY)
   'lib/genAttrs               (fn-of (list ANY ANY) ANY)
   'lib/recursiveUpdate        (fn-of (list ANY ANY) ANY)
   'lib/recursiveUpdateUntil   (fn-of (list ANY ANY ANY) ANY)
   'lib/foldAttrs              (fn-of (list ANY ANY ANY) ANY)
   'lib/getAttrs               (fn-of (list ANY ANY) ANY)
   'lib/attrByPath             (fn-of (list ANY ANY ANY) ANY)
   'lib/hasAttrByPath          (fn-of (list ANY ANY) BOOL)
   'lib/setAttrByPath          (fn-of (list ANY ANY) ANY)
   'lib/getAttrFromPath        (fn-of (list ANY ANY) ANY)
   'lib/nameValuePair          (fn-of (list STR ANY) ANY)
   'lib/listToAttrs            (fn-of (list ANY) ANY)
   'lib/zipAttrs               (fn-of (list ANY) ANY)
   'lib/zipAttrsWith           (fn-of (list ANY ANY) ANY)
   'lib/unionOfDisjoint        (fn-of (list ANY ANY) ANY)
   'lib/cartesianProductOfSets (fn-of (list ANY) ANY)
   'lib/updateManyAttrsByPath  (fn-of (list ANY ANY) ANY)

   ;; --- lib.* (lists) ---------------------------------------------------------
   'lib/flatten         (fn-of (list ANY) ANY)
   'lib/unique          (fn-of (list ANY) ANY)
   'lib/intersectLists  (fn-of (list ANY ANY) ANY)
   'lib/subtractLists   (fn-of (list ANY ANY) ANY)
   'lib/reverseList     (fn-of (list ANY) ANY)
   'lib/take            (fn-of (list INT ANY) ANY)
   'lib/drop            (fn-of (list INT ANY) ANY)
   'lib/sublist         (fn-of (list INT INT ANY) ANY)
   'lib/last            (fn-of (list ANY) ANY)
   'lib/init            (fn-of (list ANY) ANY)
   'lib/range           (fn-of (list INT INT) ANY)
   'lib/imap0           (fn-of (list ANY ANY) ANY)
   'lib/imap1           (fn-of (list ANY ANY) ANY)
   'lib/zipLists        (fn-of (list ANY ANY) ANY)
   'lib/zipListsWith    (fn-of (list ANY ANY ANY) ANY)
   'lib/foldr           (fn-of (list ANY ANY ANY) ANY)
   'lib/foldl           (fn-of (list ANY ANY ANY) ANY)
   'lib/fold            (fn-of (list ANY ANY ANY) ANY)
   'lib/foldl'          (fn-of (list ANY ANY ANY) ANY)
   'lib/count           (fn-of (list ANY ANY) INT)
   'lib/any             (fn-of (list ANY ANY) BOOL)
   'lib/all             (fn-of (list ANY ANY) BOOL)
   'lib/partition       (fn-of (list ANY ANY) ANY)
   'lib/groupBy         (fn-of (list ANY ANY) ANY)
   'lib/findFirst       (fn-of (list ANY ANY ANY) ANY)
   'lib/findFirstIndex  (fn-of (list ANY ANY ANY) ANY)
   'lib/forEach         (fn-of (list ANY ANY) ANY)
   'lib/concatLists     (fn-of (list ANY) ANY)
   'lib/concatMap       (fn-of (list ANY ANY) ANY)
   'lib/crossLists      (fn-of (list ANY ANY) ANY)
   'lib/naturalSort     (fn-of (list ANY) ANY)
   'lib/sort            (fn-of (list ANY ANY) ANY)

   ;; --- lib.* (booleans / trivial) -------------------------------------------
   'lib/id        (fn-of (list ANY) ANY)
   'lib/const     (fn-of (list ANY ANY) ANY)
   'lib/flip      (fn-of (list ANY ANY ANY) ANY)
   'lib/pipe      (fn-of (list ANY ANY) ANY)
   'lib/compose   (fn-of (list ANY ANY) ANY)
   'lib/throwIf   (fn-of (list BOOL STR ANY) ANY)
   'lib/throwIfNot (fn-of (list BOOL STR ANY) ANY)
   'lib/assertMsg (fn-of (list BOOL STR) BOOL)
   'lib/warn      (fn-of (list STR ANY) ANY)
   'lib/warnIf    (fn-of (list BOOL STR ANY) ANY)
   'lib/seq       (fn-of (list ANY ANY) ANY)
   'lib/deepSeq   (fn-of (list ANY ANY) ANY)
   'lib/min       (fn-of (list ANY ANY) ANY)
   'lib/max       (fn-of (list ANY ANY) ANY)

   ;; --- lib.* (modules / overlays) -------------------------------------------
   'lib/evalModules            (fn-of (list ANY) ANY)
   'lib/composeExtensions      (fn-of (list ANY ANY) ANY)
   'lib/composeManyExtensions  (fn-of (list ANY) ANY)
   'lib/makeOverridable        (fn-of (list ANY ANY) ANY)
   'lib/callPackageWith        (fn-of (list ANY ANY ANY) ANY)
   'lib/callPackagesWith       (fn-of (list ANY ANY ANY) ANY)
   'lib/extends                (fn-of (list ANY ANY) ANY)
   'lib/fix                    (fn-of (list ANY) ANY)
   'lib/fix'                   (fn-of (list ANY) ANY)

   ;; --- lib.* (sources / paths) ----------------------------------------------
   'lib/cleanSource              (fn-of (list ANY) ANY)
   'lib/cleanSourceWith          (fn-of (list ANY) ANY)
   'lib/sourceByRegex            (fn-of (list ANY ANY) ANY)
   'lib/sourceFilesBySuffices    (fn-of (list ANY ANY) ANY)
   'lib/pathHasContext           (fn-of (list ANY) BOOL)
   'lib/getLib                   (fn-of (list ANY) ANY)
   'lib/getBin                   (fn-of (list ANY) ANY)
   'lib/getDev                   (fn-of (list ANY) ANY)
   'lib/getMan                   (fn-of (list ANY) ANY)
   'lib/getOutput                (fn-of (list STR ANY) ANY)
   'lib/makeBinPath              (fn-of (list ANY) STR)
   'lib/makeLibraryPath          (fn-of (list ANY) STR)
   'lib/makeSearchPath           (fn-of (list STR ANY) STR)
   'lib/makeSearchPathOutput     (fn-of (list STR STR ANY) STR)

   ;; --- lib.types.* -----------------------------------------------------------
   ;; Type values used as the :type field of mkOption. Tagged with NixType so
   ;; the checker rejects passing a Bool literal (or any non-NixType) here.
   'lib/types.bool         NIXT
   'lib/types.str          NIXT
   'lib/types.nonEmptyStr  NIXT
   'lib/types.singleLineStr NIXT
   'lib/types.strMatching  (fn-of (list STR) NIXT)
   'lib/types.int          NIXT
   'lib/types.float        NIXT
   'lib/types.number       NIXT
   'lib/types.path         NIXT
   'lib/types.package      NIXT
   'lib/types.port         NIXT
   'lib/types.anything     NIXT
   'lib/types.unspecified  NIXT
   'lib/types.raw          NIXT
   'lib/types.attrs        NIXT
   'lib/types.lines        NIXT
   'lib/types.commas       NIXT
   'lib/types.envVar       NIXT
   'lib/types.shellPackage NIXT
   'lib/types.listOf       (fn-of (list NIXT) NIXT)
   'lib/types.attrsOf      (fn-of (list NIXT) NIXT)
   'lib/types.lazyAttrsOf  (fn-of (list NIXT) NIXT)
   'lib/types.nullOr       (fn-of (list NIXT) NIXT)
   'lib/types.uniq         (fn-of (list NIXT) NIXT)
   'lib/types.unique       (fn-of (list ANY NIXT) NIXT)
   'lib/types.enum         (fn-of (list ANY) NIXT)
   'lib/types.submodule    (fn-of (list ANY) NIXT)
   'lib/types.submoduleWith (fn-of (list ANY) NIXT)
   'lib/types.deferredModule NIXT
   'lib/types.either       (fn-of (list NIXT NIXT) NIXT)
   'lib/types.oneOf        (fn-of (list ANY) NIXT)
   'lib/types.coercedTo    (fn-of (list NIXT ANY NIXT) NIXT)
   'lib/types.functionTo   (fn-of (list NIXT) NIXT)
   'lib/types.addCheck     (fn-of (list NIXT ANY) NIXT)
   'lib/types.ints.unsigned  NIXT
   'lib/types.ints.positive  NIXT
   'lib/types.ints.between   (fn-of (list INT INT) NIXT)
   'lib/types.ints.u8        NIXT
   'lib/types.ints.u16       NIXT
   'lib/types.ints.u32       NIXT
   'lib/types.ints.u64       NIXT
   'lib/types.ints.s8        NIXT
   'lib/types.ints.s16       NIXT
   'lib/types.ints.s32       NIXT
   'lib/types.ints.s64       NIXT))

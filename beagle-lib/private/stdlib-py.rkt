#lang racket/base

;; Python-specific stdlib type declarations.
;; Maps Python builtins and standard library functions to Beagle types.

(require "types.rkt"
         "stdlib-helpers.rkt")

(provide STDLIB-PY)

(define STDLIB-PY
  (hash
   ;; --- builtins (functions) ---------------------------------------------------
   'len            (fn-of '(Any) 'Int)
   'print          (fn-of '() 'Nil #:rest 'Any)
   'input          (fn-of '(String) 'String)
   'type           (fn-of '(Any) 'Any)
   'isinstance     (fn-of '(Any Any) 'Bool)
   'issubclass     (fn-of '(Any Any) 'Bool)
   'id             (fn-of '(Any) 'Int)
   'hash           (fn-of '(Any) 'Int)
   'repr           (fn-of '(Any) 'String)
   'abs            (fn-of '(Any) 'Any)
   'round          (fn-of '(Any) 'Any #:rest 'Int)
   'min            (fn-of '(Any) 'Any #:rest 'Any)
   'max            (fn-of '(Any) 'Any #:rest 'Any)
   'sum            (fn-of '(Any) 'Any)
   'sorted         (fn-of '(Any) 'Any #:rest 'Any)
   'reversed       (fn-of '(Any) 'Any)
   'enumerate      (fn-of '(Any) 'Any #:rest 'Int)
   'zip            (fn-of '(Any) 'Any #:rest 'Any)
   'map            (fn-of '(Any Any) 'Any)
   'filter         (fn-of '(Any Any) 'Any)
   'range          (fn-of '(Int) 'Any #:rest 'Int)
   'iter           (fn-of '(Any) 'Any)
   'next           (fn-of '(Any) 'Any #:rest 'Any)
   'all            (fn-of '(Any) 'Bool)
   'any            (fn-of '(Any) 'Bool)
   'callable       (fn-of '(Any) 'Bool)
   'hasattr        (fn-of '(Any String) 'Bool)
   'getattr        (fn-of '(Any String) 'Any #:rest 'Any)
   'setattr        (fn-of '(Any String Any) 'Nil)
   'delattr        (fn-of '(Any String) 'Nil)
   'vars           (fn-of '() 'Any #:rest 'Any)
   'dir            (fn-of '() 'Any #:rest 'Any)
   'open           (fn-of '(String) 'Any #:rest 'Any)
   'chr            (fn-of '(Int) 'String)
   'ord            (fn-of '(String) 'Int)
   'hex            (fn-of '(Int) 'String)
   'oct            (fn-of '(Int) 'String)
   'bin            (fn-of '(Int) 'String)
   'format         (fn-of '(Any String) 'String)
   'pow            (fn-of '(Any Any) 'Any #:rest 'Any)
   'divmod         (fn-of '(Any Any) 'Any)
   'super          (fn-of '() 'Any #:rest 'Any)
   'property       (fn-of '(Any) 'Any #:rest 'Any)
   'staticmethod   (fn-of '(Any) 'Any)
   'classmethod    (fn-of '(Any) 'Any)

   ;; --- builtins (type constructors) ------------------------------------------
   'int            (fn-of '() 'Int #:rest 'Any)
   'float          (fn-of '() 'Float #:rest 'Any)
   'str            (fn-of '() 'String #:rest 'Any)
   'bool           (fn-of '() 'Bool #:rest 'Any)
   'list           (fn-of '() 'Any #:rest 'Any)
   'dict           (fn-of '() 'Any #:rest 'Any)
   'set            (fn-of '() 'Any #:rest 'Any)
   'tuple          (fn-of '() 'Any #:rest 'Any)
   'frozenset      (fn-of '() 'Any #:rest 'Any)
   'bytes          (fn-of '() 'Any #:rest 'Any)
   'bytearray      (fn-of '() 'Any #:rest 'Any)

   ;; --- builtins (exceptions) -------------------------------------------------
   'Exception      (fn-of '() 'Any #:rest 'Any)
   'ValueError     (fn-of '() 'Any #:rest 'Any)
   'TypeError      (fn-of '() 'Any #:rest 'Any)
   'KeyError       (fn-of '() 'Any #:rest 'Any)
   'IndexError     (fn-of '() 'Any #:rest 'Any)
   'AttributeError (fn-of '() 'Any #:rest 'Any)
   'RuntimeError   (fn-of '() 'Any #:rest 'Any)
   'StopIteration  (fn-of '() 'Any #:rest 'Any)
   'FileNotFoundError (fn-of '() 'Any #:rest 'Any)
   'IOError        (fn-of '() 'Any #:rest 'Any)
   'OSError        (fn-of '() 'Any #:rest 'Any)
   'NotImplementedError (fn-of '() 'Any #:rest 'Any)

   ;; --- os.path ---------------------------------------------------------------
   'os.path/join      (fn-of '(String) 'String #:rest 'String)
   'os.path/exists    (fn-of '(String) 'Bool)
   'os.path/isfile    (fn-of '(String) 'Bool)
   'os.path/isdir     (fn-of '(String) 'Bool)
   'os.path/basename  (fn-of '(String) 'String)
   'os.path/dirname   (fn-of '(String) 'String)
   'os.path/abspath   (fn-of '(String) 'String)
   'os.path/splitext  (fn-of '(String) 'Any)

   ;; --- json ------------------------------------------------------------------
   'json/dumps     (fn-of '(Any) 'String #:rest 'Any)
   'json/loads     (fn-of '(String) 'Any)

   ;; --- math ------------------------------------------------------------------
   'math/floor     (fn-of '(Any) 'Int)
   'math/ceil      (fn-of '(Any) 'Int)
   'math/sqrt      (fn-of '(Any) 'Float)
   'math/log       (fn-of '(Any) 'Float #:rest 'Any)
   'math/sin       (fn-of '(Any) 'Float)
   'math/cos       (fn-of '(Any) 'Float)
   'math/pi        (p 'Float)
   'math/e         (p 'Float)
   'math/inf       (p 'Float)

   ;; --- re (regex) ------------------------------------------------------------
   're/compile     (fn-of '(String) 'Any #:rest 'Any)
   're/match       (fn-of '(String String) 'Any #:rest 'Any)
   're/search      (fn-of '(String String) 'Any #:rest 'Any)
   're/findall     (fn-of '(String String) 'Any #:rest 'Any)
   're/sub         (fn-of '(String String String) 'String #:rest 'Any)
   're/split       (fn-of '(String String) 'Any #:rest 'Any)

   ;; --- functools -------------------------------------------------------------
   'functools/reduce   (fn-of '(Any Any) 'Any #:rest 'Any)
   'functools/partial  (fn-of '(Any) 'Any #:rest 'Any)
   'functools/lru_cache (fn-of '() 'Any #:rest 'Any)

   ;; --- itertools -------------------------------------------------------------
   'itertools/chain      (fn-of '() 'Any #:rest 'Any)
   'itertools/islice     (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/groupby    (fn-of '(Any) 'Any #:rest 'Any)
   'itertools/product    (fn-of '() 'Any #:rest 'Any)
   'itertools/permutations (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/combinations (fn-of '(Any Int) 'Any)
   'itertools/starmap    (fn-of '(Any Any) 'Any)
   'itertools/count      (fn-of '() 'Any #:rest 'Any)
   'itertools/repeat     (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/cycle      (fn-of '(Any) 'Any)

   ;; --- collections ----------------------------------------------------------
   'collections/defaultdict   (fn-of '() 'Any #:rest 'Any)
   'collections/OrderedDict   (fn-of '() 'Any #:rest 'Any)
   'collections/Counter       (fn-of '() 'Any #:rest 'Any)
   'collections/deque         (fn-of '() 'Any #:rest 'Any)
   'collections/namedtuple    (fn-of '(String Any) 'Any)

   ;; --- dataclasses -----------------------------------------------------------
   'dataclasses/dataclass     (fn-of '(Any) 'Any #:rest 'Any)
   'dataclasses/field         (fn-of '() 'Any #:rest 'Any)
   'dataclasses/replace       (fn-of '(Any) 'Any #:rest 'Any)
   'dataclasses/asdict        (fn-of '(Any) 'Any)
   'dataclasses/astuple       (fn-of '(Any) 'Any)

   ;; --- typing ----------------------------------------------------------------
   'typing/cast    (fn-of '(Any Any) 'Any)

   ;; --- sys -------------------------------------------------------------------
   'sys/exit        (fn-of '() 'Nil #:rest 'Any)
   'sys/argv        (p 'Any)
   'sys/stdin       (p 'Any)
   'sys/stdout      (p 'Any)
   'sys/stderr      (p 'Any)

   ;; --- datetime --------------------------------------------------------------
   'datetime/datetime   (fn-of '(Int Int Int) 'Any #:rest 'Any)
   'datetime/date       (fn-of '(Int Int Int) 'Any)
   'datetime/timedelta  (fn-of '() 'Any #:rest 'Any)

   ;; --- pathlib ---------------------------------------------------------------
   'pathlib/Path   (fn-of '(String) 'Any #:rest 'Any)

   ;; --- copy ------------------------------------------------------------------
   'copy/copy      (fn-of '(Any) 'Any)
   'copy/deepcopy  (fn-of '(Any) 'Any)

   ;; --- builtins (constants) --------------------------------------------------
   'None           (p 'Nil)
   'True           (p 'Bool)
   'False          (p 'Bool)
   ))

#lang racket/base

;; Python-specific stdlib type declarations.
;; Maps Python builtins and standard library functions to Beagle types.
;;
;; Higher-order combinators use `poly-fn` with forall vars (A, B, K, V).
;; Functions whose return type genuinely depends on dynamic shape (or where
;; modeling would mislead) stay at Any — Python's dynamic standard library is
;; loose in places.

(require "../types.rkt"
         "../stdlib-helpers.rkt")

(provide STDLIB-PY)

;; Type shorthands (mirror stdlib-nix style)
(define ANY  (type-prim 'Any))
(define STR  (type-prim 'String))
(define BOOL (type-prim 'Bool))
(define INT  (type-prim 'Int))
(define FLT  (type-prim 'Float))
(define NIL  (type-prim 'Nil))
(define (LIST-OF t) (type-app 'List (list (if (type? t) t (type-prim t)))))
(define (MAP-OF k v) (type-app 'Map (list (if (type? k) k (type-prim k))
                                          (if (type? v) v (type-prim v)))))
(define (VEC-OF t) (type-app 'Vec (list (if (type? t) t (type-prim t)))))
(define (SET-OF t) (type-app 'Set (list (if (type? t) t (type-prim t)))))

(define STDLIB-PY
  (hash
   ;; ============================================================================
   ;; builtins — functions
   ;; ============================================================================

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
   'sum            (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'sorted         (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A))
                            #:rest ANY)
   'reversed       (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))
   'enumerate      (fn-of '(Any) 'Any #:rest 'Int)
   'zip            (fn-of '(Any) 'Any #:rest 'Any)
   'map            (poly-fn '(A B)
                            (list (type-fn (list (tv 'A)) #f (tv 'B))
                                  (LIST-OF (tv 'A)))
                            (LIST-OF (tv 'B)))
   'filter         (poly-fn '(A)
                            (list (type-fn (list (tv 'A)) #f BOOL)
                                  (LIST-OF (tv 'A)))
                            (LIST-OF (tv 'A)))
   'range          (fn-of '(Int) 'Any #:rest 'Int)
   'iter           (fn-of '(Any) 'Any)
   'next           (fn-of '(Any) 'Any #:rest 'Any)
   'all            (poly-fn '(A) (list (LIST-OF (tv 'A))) BOOL)
   'any            (poly-fn '(A) (list (LIST-OF (tv 'A))) BOOL)
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
   'globals        (fn-of '() 'Any)
   'locals         (fn-of '() 'Any)
   'eval           (fn-of '(String) 'Any #:rest 'Any)
   'exec           (fn-of '(String) 'Nil #:rest 'Any)
   'compile        (fn-of '(String String String) 'Any)
   'help           (fn-of '() 'Nil #:rest 'Any)

   ;; ============================================================================
   ;; builtins — type constructors
   ;; ============================================================================

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
   'complex        (fn-of '() 'Any #:rest 'Any)
   'memoryview     (fn-of '(Any) 'Any)
   'slice          (fn-of '(Int) 'Any #:rest 'Int)

   ;; ============================================================================
   ;; builtins — exception classes
   ;; ============================================================================

   'Exception           (fn-of '() 'Any #:rest 'Any)
   'BaseException       (fn-of '() 'Any #:rest 'Any)
   'ValueError          (fn-of '() 'Any #:rest 'Any)
   'TypeError           (fn-of '() 'Any #:rest 'Any)
   'KeyError            (fn-of '() 'Any #:rest 'Any)
   'IndexError          (fn-of '() 'Any #:rest 'Any)
   'AttributeError      (fn-of '() 'Any #:rest 'Any)
   'RuntimeError        (fn-of '() 'Any #:rest 'Any)
   'StopIteration       (fn-of '() 'Any #:rest 'Any)
   'StopAsyncIteration  (fn-of '() 'Any #:rest 'Any)
   'FileNotFoundError   (fn-of '() 'Any #:rest 'Any)
   'FileExistsError     (fn-of '() 'Any #:rest 'Any)
   'PermissionError     (fn-of '() 'Any #:rest 'Any)
   'IOError             (fn-of '() 'Any #:rest 'Any)
   'OSError             (fn-of '() 'Any #:rest 'Any)
   'NotImplementedError (fn-of '() 'Any #:rest 'Any)
   'ZeroDivisionError   (fn-of '() 'Any #:rest 'Any)
   'ArithmeticError     (fn-of '() 'Any #:rest 'Any)
   'OverflowError       (fn-of '() 'Any #:rest 'Any)
   'AssertionError      (fn-of '() 'Any #:rest 'Any)
   'ImportError         (fn-of '() 'Any #:rest 'Any)
   'ModuleNotFoundError (fn-of '() 'Any #:rest 'Any)
   'NameError           (fn-of '() 'Any #:rest 'Any)
   'UnicodeError        (fn-of '() 'Any #:rest 'Any)
   'TimeoutError        (fn-of '() 'Any #:rest 'Any)

   ;; ============================================================================
   ;; builtins — constants
   ;; ============================================================================

   'None           (p 'Nil)
   'True           (p 'Bool)
   'False          (p 'Bool)
   'NotImplemented (p 'Any)
   'Ellipsis       (p 'Any)

   ;; ============================================================================
   ;; str methods (dotted name form for method-call syntax `(.upper s)`)
   ;; ============================================================================

   'str/upper       (fn-of '(String) 'String)
   'str/lower       (fn-of '(String) 'String)
   'str/strip       (fn-of '(String) 'String #:rest 'String)
   'str/lstrip      (fn-of '(String) 'String #:rest 'String)
   'str/rstrip      (fn-of '(String) 'String #:rest 'String)
   'str/split       (fn-of '(String) 'Any #:rest 'Any)
   'str/rsplit      (fn-of '(String) 'Any #:rest 'Any)
   'str/splitlines  (fn-of '(String) 'Any #:rest 'Bool)
   'str/join        (fn-of '(String Any) 'String)
   'str/replace     (fn-of '(String String String) 'String #:rest 'Int)
   'str/startswith  (fn-of '(String String) 'Bool)
   'str/endswith    (fn-of '(String String) 'Bool)
   'str/find        (fn-of '(String String) 'Int)
   'str/rfind       (fn-of '(String String) 'Int)
   'str/index       (fn-of '(String String) 'Int)
   'str/count       (fn-of '(String String) 'Int)
   'str/capitalize  (fn-of '(String) 'String)
   'str/title       (fn-of '(String) 'String)
   'str/swapcase    (fn-of '(String) 'String)
   'str/format      (fn-of '(String) 'String #:rest 'Any)
   'str/encode      (fn-of '(String) 'Any #:rest 'String)
   'str/isdigit     (fn-of '(String) 'Bool)
   'str/isalpha     (fn-of '(String) 'Bool)
   'str/isalnum     (fn-of '(String) 'Bool)
   'str/isspace     (fn-of '(String) 'Bool)
   'str/isupper     (fn-of '(String) 'Bool)
   'str/islower     (fn-of '(String) 'Bool)
   'str/zfill       (fn-of '(String Int) 'String)
   'str/ljust       (fn-of '(String Int) 'String #:rest 'String)
   'str/rjust       (fn-of '(String Int) 'String #:rest 'String)
   'str/center      (fn-of '(String Int) 'String #:rest 'String)
   'str/maketrans   (fn-of '(String String) 'Any)
   'str/translate   (fn-of '(String Any) 'String)

   ;; ============================================================================
   ;; list methods
   ;; ============================================================================

   'list/append     (poly-fn '(A) (list (LIST-OF (tv 'A)) (tv 'A)) NIL)
   'list/extend     (poly-fn '(A) (list (LIST-OF (tv 'A)) (LIST-OF (tv 'A))) NIL)
   'list/pop        (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A) #:rest INT)
   'list/insert     (poly-fn '(A) (list (LIST-OF (tv 'A)) INT (tv 'A)) NIL)
   'list/remove     (poly-fn '(A) (list (LIST-OF (tv 'A)) (tv 'A)) NIL)
   'list/sort       (poly-fn '(A) (list (LIST-OF (tv 'A))) NIL #:rest ANY)
   'list/reverse    (poly-fn '(A) (list (LIST-OF (tv 'A))) NIL)
   'list/index      (poly-fn '(A) (list (LIST-OF (tv 'A)) (tv 'A)) INT)
   'list/count      (poly-fn '(A) (list (LIST-OF (tv 'A)) (tv 'A)) INT)
   'list/clear      (poly-fn '(A) (list (LIST-OF (tv 'A))) NIL)
   'list/copy       (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A)))

   ;; ============================================================================
   ;; dict methods
   ;; ============================================================================

   'dict/get        (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V)) (tv 'K)) (tv 'V)
                             #:rest ANY)
   'dict/keys       (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V))) (LIST-OF (tv 'K)))
   'dict/values     (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V))) (LIST-OF (tv 'V)))
   'dict/items      (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V))) ANY)
   'dict/pop        (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V)) (tv 'K)) (tv 'V)
                             #:rest ANY)
   'dict/popitem    (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V))) ANY)
   'dict/update     (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V)) (MAP-OF (tv 'K) (tv 'V))) NIL)
   'dict/setdefault (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V)) (tv 'K) (tv 'V)) (tv 'V))
   'dict/clear      (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V))) NIL)
   'dict/copy       (poly-fn '(K V) (list (MAP-OF (tv 'K) (tv 'V)))
                             (MAP-OF (tv 'K) (tv 'V)))
   'dict/fromkeys   (poly-fn '(K) (list (LIST-OF (tv 'K))) (MAP-OF (tv 'K) ANY)
                             #:rest ANY)

   ;; ============================================================================
   ;; set methods
   ;; ============================================================================

   'set/add         (poly-fn '(A) (list (SET-OF (tv 'A)) (tv 'A)) NIL)
   'set/remove      (poly-fn '(A) (list (SET-OF (tv 'A)) (tv 'A)) NIL)
   'set/discard     (poly-fn '(A) (list (SET-OF (tv 'A)) (tv 'A)) NIL)
   'set/pop         (poly-fn '(A) (list (SET-OF (tv 'A))) (tv 'A))
   'set/clear       (poly-fn '(A) (list (SET-OF (tv 'A))) NIL)
   'set/union       (poly-fn '(A) (list (SET-OF (tv 'A))) (SET-OF (tv 'A)) #:rest ANY)
   'set/intersection (poly-fn '(A) (list (SET-OF (tv 'A))) (SET-OF (tv 'A)) #:rest ANY)
   'set/difference  (poly-fn '(A) (list (SET-OF (tv 'A))) (SET-OF (tv 'A)) #:rest ANY)
   'set/issubset    (poly-fn '(A) (list (SET-OF (tv 'A)) (SET-OF (tv 'A))) BOOL)
   'set/issuperset  (poly-fn '(A) (list (SET-OF (tv 'A)) (SET-OF (tv 'A))) BOOL)
   'set/copy        (poly-fn '(A) (list (SET-OF (tv 'A))) (SET-OF (tv 'A)))

   ;; ============================================================================
   ;; os
   ;; ============================================================================

   'os/getcwd       (fn-of '() 'String)
   'os/chdir        (fn-of '(String) 'Nil)
   'os/listdir      (fn-of '() 'Any #:rest 'String)
   'os/mkdir        (fn-of '(String) 'Nil #:rest 'Int)
   'os/makedirs     (fn-of '(String) 'Nil #:rest 'Any)
   'os/rmdir        (fn-of '(String) 'Nil)
   'os/remove       (fn-of '(String) 'Nil)
   'os/rename       (fn-of '(String String) 'Nil)
   'os/environ      (p 'Any)
   'os/getenv       (fn-of '(String) 'Any #:rest 'String)
   'os/sep          (p 'String)
   'os/linesep      (p 'String)
   'os/name         (p 'String)
   'os/walk         (fn-of '(String) 'Any #:rest 'Any)

   ;; ============================================================================
   ;; os.path
   ;; ============================================================================

   'os.path/join      (fn-of '(String) 'String #:rest 'String)
   'os.path/exists    (fn-of '(String) 'Bool)
   'os.path/isfile    (fn-of '(String) 'Bool)
   'os.path/isdir     (fn-of '(String) 'Bool)
   'os.path/islink    (fn-of '(String) 'Bool)
   'os.path/basename  (fn-of '(String) 'String)
   'os.path/dirname   (fn-of '(String) 'String)
   'os.path/abspath   (fn-of '(String) 'String)
   'os.path/relpath   (fn-of '(String) 'String #:rest 'String)
   'os.path/normpath  (fn-of '(String) 'String)
   'os.path/splitext  (fn-of '(String) 'Any)
   'os.path/split     (fn-of '(String) 'Any)
   'os.path/getsize   (fn-of '(String) 'Int)
   'os.path/getmtime  (fn-of '(String) 'Float)
   'os.path/expanduser (fn-of '(String) 'String)
   'os.path/expandvars (fn-of '(String) 'String)
   'os.path/realpath  (fn-of '(String) 'String)

   ;; ============================================================================
   ;; json
   ;; ============================================================================

   'json/dumps     (fn-of '(Any) 'String #:rest 'Any)
   'json/loads     (fn-of '(String) 'Any)
   'json/dump      (fn-of '(Any Any) 'Nil #:rest 'Any)
   'json/load      (fn-of '(Any) 'Any)

   ;; ============================================================================
   ;; math
   ;; ============================================================================

   'math/floor     (fn-of '(Any) 'Int)
   'math/ceil      (fn-of '(Any) 'Int)
   'math/trunc     (fn-of '(Any) 'Int)
   'math/sqrt      (fn-of '(Any) 'Float)
   'math/log       (fn-of '(Any) 'Float #:rest 'Any)
   'math/log2      (fn-of '(Any) 'Float)
   'math/log10     (fn-of '(Any) 'Float)
   'math/exp       (fn-of '(Any) 'Float)
   'math/pow       (fn-of '(Any Any) 'Float)
   'math/sin       (fn-of '(Any) 'Float)
   'math/cos       (fn-of '(Any) 'Float)
   'math/tan       (fn-of '(Any) 'Float)
   'math/asin      (fn-of '(Any) 'Float)
   'math/acos      (fn-of '(Any) 'Float)
   'math/atan      (fn-of '(Any) 'Float)
   'math/atan2     (fn-of '(Any Any) 'Float)
   'math/degrees   (fn-of '(Any) 'Float)
   'math/radians   (fn-of '(Any) 'Float)
   'math/gcd       (fn-of '(Int Int) 'Int)
   'math/factorial (fn-of '(Int) 'Int)
   'math/isnan     (fn-of '(Float) 'Bool)
   'math/isinf     (fn-of '(Float) 'Bool)
   'math/isfinite  (fn-of '(Float) 'Bool)
   'math/pi        (p 'Float)
   'math/e         (p 'Float)
   'math/tau       (p 'Float)
   'math/inf       (p 'Float)
   'math/nan       (p 'Float)

   ;; ============================================================================
   ;; re (regex)
   ;; ============================================================================

   're/compile     (fn-of '(String) 'Any #:rest 'Any)
   're/match       (fn-of '(String String) 'Any #:rest 'Any)
   're/fullmatch   (fn-of '(String String) 'Any #:rest 'Any)
   're/search      (fn-of '(String String) 'Any #:rest 'Any)
   're/findall     (fn-of '(String String) 'Any #:rest 'Any)
   're/finditer    (fn-of '(String String) 'Any #:rest 'Any)
   're/sub         (fn-of '(String String String) 'String #:rest 'Any)
   're/subn        (fn-of '(String String String) 'Any #:rest 'Any)
   're/split       (fn-of '(String String) 'Any #:rest 'Any)
   're/escape      (fn-of '(String) 'String)

   ;; ============================================================================
   ;; functools
   ;; ============================================================================

   'functools/reduce    (poly-fn '(A B)
                                 (list (type-fn (list (tv 'B) (tv 'A)) #f (tv 'B))
                                       (LIST-OF (tv 'A))
                                       (tv 'B))
                                 (tv 'B))
   'functools/partial   (fn-of '(Any) 'Any #:rest 'Any)
   'functools/lru_cache (fn-of '() 'Any #:rest 'Any)
   'functools/cache     (fn-of '(Any) 'Any)
   'functools/wraps     (fn-of '(Any) 'Any)
   'functools/cmp_to_key (fn-of '(Any) 'Any)

   ;; ============================================================================
   ;; itertools
   ;; ============================================================================

   'itertools/chain        (fn-of '() 'Any #:rest 'Any)
   'itertools/islice       (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/groupby      (fn-of '(Any) 'Any #:rest 'Any)
   'itertools/product      (fn-of '() 'Any #:rest 'Any)
   'itertools/permutations (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/combinations (fn-of '(Any Int) 'Any)
   'itertools/starmap      (fn-of '(Any Any) 'Any)
   'itertools/count        (fn-of '() 'Any #:rest 'Any)
   'itertools/repeat       (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/cycle        (fn-of '(Any) 'Any)
   'itertools/dropwhile    (fn-of '(Any Any) 'Any)
   'itertools/takewhile    (fn-of '(Any Any) 'Any)
   'itertools/accumulate   (fn-of '(Any) 'Any #:rest 'Any)
   'itertools/tee          (fn-of '(Any) 'Any #:rest 'Int)
   'itertools/zip_longest  (fn-of '() 'Any #:rest 'Any)

   ;; ============================================================================
   ;; collections
   ;; ============================================================================

   'collections/defaultdict   (fn-of '() 'Any #:rest 'Any)
   'collections/OrderedDict   (fn-of '() 'Any #:rest 'Any)
   'collections/Counter       (fn-of '() 'Any #:rest 'Any)
   'collections/deque         (fn-of '() 'Any #:rest 'Any)
   'collections/namedtuple    (fn-of '(String Any) 'Any)
   'collections/ChainMap      (fn-of '() 'Any #:rest 'Any)

   ;; ============================================================================
   ;; dataclasses
   ;; ============================================================================

   'dataclasses/dataclass     (fn-of '(Any) 'Any #:rest 'Any)
   'dataclasses/field         (fn-of '() 'Any #:rest 'Any)
   'dataclasses/replace       (fn-of '(Any) 'Any #:rest 'Any)
   'dataclasses/asdict        (fn-of '(Any) 'Any)
   'dataclasses/astuple       (fn-of '(Any) 'Any)
   'dataclasses/fields        (fn-of '(Any) 'Any)
   'dataclasses/is_dataclass  (fn-of '(Any) 'Bool)

   ;; ============================================================================
   ;; typing
   ;; ============================================================================

   'typing/cast        (fn-of '(Any Any) 'Any)
   'typing/List        (p 'Any)
   'typing/Dict        (p 'Any)
   'typing/Set         (p 'Any)
   'typing/Tuple       (p 'Any)
   'typing/Optional    (p 'Any)
   'typing/Union       (p 'Any)
   'typing/Callable    (p 'Any)
   'typing/Any         (p 'Any)
   'typing/Iterator    (p 'Any)
   'typing/Iterable    (p 'Any)
   'typing/Generator   (p 'Any)
   'typing/TypeVar     (fn-of '(String) 'Any #:rest 'Any)
   'typing/Generic     (p 'Any)
   'typing/Protocol    (p 'Any)
   'typing/Type        (p 'Any)
   'typing/Final       (p 'Any)
   'typing/Literal     (p 'Any)
   'typing/Annotated   (p 'Any)
   'typing/TYPE_CHECKING (p 'Bool)
   'typing/runtime_checkable (fn-of '(Any) 'Any)

   ;; ============================================================================
   ;; sys
   ;; ============================================================================

   'sys/exit        (fn-of '() 'Nil #:rest 'Any)
   'sys/argv        (p 'Any)
   'sys/stdin       (p 'Any)
   'sys/stdout      (p 'Any)
   'sys/stderr      (p 'Any)
   'sys/version     (p 'String)
   'sys/version_info (p 'Any)
   'sys/platform    (p 'String)
   'sys/path        (p 'Any)
   'sys/modules     (p 'Any)
   'sys/maxsize     (p 'Int)
   'sys/getsizeof   (fn-of '(Any) 'Int)

   ;; ============================================================================
   ;; datetime
   ;; ============================================================================

   'datetime/datetime   (fn-of '(Int Int Int) 'Any #:rest 'Any)
   'datetime/date       (fn-of '(Int Int Int) 'Any)
   'datetime/time       (fn-of '() 'Any #:rest 'Any)
   'datetime/timedelta  (fn-of '() 'Any #:rest 'Any)
   'datetime/timezone   (fn-of '(Any) 'Any #:rest 'Any)
   'datetime.datetime/now      (fn-of '() 'Any #:rest 'Any)
   'datetime.datetime/utcnow   (fn-of '() 'Any)
   'datetime.datetime/today    (fn-of '() 'Any)
   'datetime.datetime/strptime (fn-of '(String String) 'Any)
   'datetime.datetime/fromtimestamp (fn-of '(Float) 'Any #:rest 'Any)
   'datetime.datetime/fromisoformat (fn-of '(String) 'Any)

   ;; ============================================================================
   ;; pathlib
   ;; ============================================================================

   'pathlib/Path        (fn-of '(String) 'Any #:rest 'Any)
   'pathlib/PurePath    (fn-of '(String) 'Any #:rest 'Any)
   'pathlib/PosixPath   (fn-of '(String) 'Any #:rest 'Any)
   'pathlib/WindowsPath (fn-of '(String) 'Any #:rest 'Any)

   ;; ============================================================================
   ;; copy
   ;; ============================================================================

   'copy/copy      (poly-fn '(A) (list (tv 'A)) (tv 'A))
   'copy/deepcopy  (poly-fn '(A) (list (tv 'A)) (tv 'A))

   ;; ============================================================================
   ;; io
   ;; ============================================================================

   'io/StringIO    (fn-of '() 'Any #:rest 'String)
   'io/BytesIO     (fn-of '() 'Any #:rest 'Any)
   'io/open        (fn-of '(String) 'Any #:rest 'Any)

   ;; ============================================================================
   ;; time
   ;; ============================================================================

   'time/time       (fn-of '() 'Float)
   'time/sleep      (fn-of '(Float) 'Nil)
   'time/perf_counter (fn-of '() 'Float)
   'time/monotonic  (fn-of '() 'Float)
   'time/strftime   (fn-of '(String) 'String #:rest 'Any)
   'time/strptime   (fn-of '(String String) 'Any)

   ;; ============================================================================
   ;; random
   ;; ============================================================================

   'random/random      (fn-of '() 'Float)
   'random/randint     (fn-of '(Int Int) 'Int)
   'random/uniform     (fn-of '(Float Float) 'Float)
   'random/choice      (poly-fn '(A) (list (LIST-OF (tv 'A))) (tv 'A))
   'random/choices     (poly-fn '(A) (list (LIST-OF (tv 'A))) (LIST-OF (tv 'A))
                                #:rest ANY)
   'random/sample      (poly-fn '(A) (list (LIST-OF (tv 'A)) INT) (LIST-OF (tv 'A)))
   'random/shuffle     (poly-fn '(A) (list (LIST-OF (tv 'A))) NIL)
   'random/seed        (fn-of '() 'Nil #:rest 'Any)

   ;; ============================================================================
   ;; hashlib
   ;; ============================================================================

   'hashlib/md5     (fn-of '() 'Any #:rest 'Any)
   'hashlib/sha1    (fn-of '() 'Any #:rest 'Any)
   'hashlib/sha256  (fn-of '() 'Any #:rest 'Any)
   'hashlib/sha512  (fn-of '() 'Any #:rest 'Any)

   ;; ============================================================================
   ;; asyncio
   ;; ============================================================================

   'asyncio/run            (fn-of '(Any) 'Any)
   'asyncio/sleep          (fn-of '(Float) 'Any)
   'asyncio/gather         (fn-of '() 'Any #:rest 'Any)
   'asyncio/wait           (fn-of '(Any) 'Any #:rest 'Any)
   'asyncio/wait_for       (fn-of '(Any Float) 'Any)
   'asyncio/create_task    (fn-of '(Any) 'Any)
   'asyncio/get_event_loop (fn-of '() 'Any)
   'asyncio/Queue          (fn-of '() 'Any #:rest 'Any)
   'asyncio/Lock           (fn-of '() 'Any)
   ))

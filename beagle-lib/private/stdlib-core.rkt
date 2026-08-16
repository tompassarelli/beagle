#lang racket/base

;; Native Core-only source bindings. Their qualified names keep target-specific
;; concepts out of the portable Clojure-shaped namespace.

(require "types.rkt"
         "stdlib-helpers.rkt")

(define STDLIB-CORE
  (hash
   ;; Native Core's dense mutable F64 storage uses Clojure's primitive-array
   ;; vocabulary. The type stays distinct from persistent Vec, and the first
   ;; admitted slice is deliberately one-argument zero-filled double-array.
   'double-array
   (type-fn
    (list (p 'Int))
    #f
    (type-app 'Buffer (list (p 'Float))))
   'alength
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))))
    #f
    (p 'Int))
   'aget
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))) (p 'Int))
    #f
    (p 'Float))
   'aset-double!
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))) (p 'Int) (p 'Float))
    #f
    (p 'Float))
   ;; Bulk-synchronous Native Core surface. The policy operands are literals at
   ;; lowering time; the function type keeps the statically named tile kernel
   ;; exact at source checking too.
   'native/tiled-step!
   (type-fn
    (list (type-app 'Buffer (list (p 'Float)))
          (type-app 'Buffer (list (p 'Float)))
          (p 'Int) (p 'Int) (p 'Int) (p 'Keyword)
          (type-fn
           (list (type-app 'Buffer (list (p 'Float)))
                 (type-app 'Buffer (list (p 'Float)))
                 (p 'Int) (p 'Int) (p 'Int))
           #f
           (p 'Nil)))
    #f
    (p 'Bool))
   'native/f64-buffer-sum
   (type-fn
    (list (type-app 'Buffer (list (p 'Float))) (p 'Int))
    #f
    (p 'Float))
   'native.bytes/from-ints-bounded
   (type-fn
    (list (type-app 'Vec (list (p 'Int))) (p 'Int))
    #f
    (p 'NativeBytes))
   'parse-long
   (type-fn
    (list (p 'String))
    #f
    (type-union (list (p 'Int) (p 'Nil))))
   'host.fs/path-kind
   (type-fn
    (list (p 'String))
    #f
    (p 'host.fs/PathKindResult))
   'host.fs/read-text-bounded
   (type-fn
    (list (p 'String) (p 'Int))
    #f
    (p 'host.fs/ReadTextBoundedResult))
   'host.fs/list-directory-bounded
   (type-fn
    (list (p 'String) (p 'Int))
    #f
    (p 'host.fs/ListDirectoryBoundedResult))
   'host.fs/write-text-atomic
   (type-fn
    (list (p 'String) (p 'String))
    #f
    (p 'host.fs/WriteTextAtomicResult))
   'host.fs/make-parent-directories
   (type-fn
    (list (p 'String))
    #f
    (p 'host.fs/MakeParentDirectoriesResult))
   'host.fs/append-text
   (type-fn
    (list (p 'String) (p 'String))
    #f
    (p 'host.fs/AppendTextResult))
   ;; lock-exclusive transfers one descriptor holding a non-blocking exclusive
   ;; lease on the path's open file description; unlock consumes it. The kernel
   ;; releases the lease on close or on process death. Contention is EAGAIN.
   'host.fs/lock-exclusive
   (type-fn
    (list (p 'String))
    #f
    (p 'host.fs/LockExclusiveResult))
   'host.fs/unlock
   (type-fn
    (list (p 'Int))
    #f
    (p 'host.fs/UnlockResult))
   'host.clock/wall-nanoseconds
   (type-fn '() #f (p 'Int))
   'host.clock/format-iso8601
   (type-fn
    (list (p 'Int))
    #f
    (p 'host.clock/FormatIso8601Result))
   'host.time/sleep-milliseconds
   (type-fn
    (list (p 'Int))
    #f
    (p 'Int))
   'host.system/hostname
   (type-fn '() #f (p 'host.system/HostnameResult))
   'host.system/platform
   (type-fn '() #f (p 'String))
   'host.terminal/stdout-tty?
   (type-fn '() #f (p 'Bool))
   ;; Native process execution takes an already-tokenized argv vector. The
   ;; result encodes exit 0..255, signal 256+signal, or spawn/wait -errno.
   'host.process/run-inherit
   (type-fn
    (list (type-app 'Vec (list (p 'String))))
    #f
    (p 'Int))
   'host.process/exec-replace
   (type-fn
    (list (type-app 'Vec (list (p 'String))))
    #f
    (p 'Int))
   'host.process/run-capture
   (type-fn
    (list (type-app 'Vec (list (p 'String)))
          (p 'String)
          (p 'Int))
    #f
    (p 'host.process/CaptureResult))
   ;; spawn-stdout transfers one child and one stdout descriptor to the
   ;; caller. wait consumes the child relationship; close consumes the
   ;; descriptor. read-line-bounded borrows the descriptor and bounds one
   ;; decoded UTF-8 line in bytes.
   'host.process/spawn-stdout
   (type-fn
    (list (type-app 'Vec (list (p 'String))))
    #f
    (p 'host.process/SpawnStdoutResult))
   'host.process/read-line-bounded
   (type-fn
    (list (p 'Int) (p 'Int))
    #f
    (p 'host.process/ReadLineResult))
   'host.process/read-line-deadline
   (type-fn
    (list (p 'Int) (p 'Int) (p 'Int))
    #f
    (p 'host.process/ReadLineResult))
   'host.process/fifo-create
   (type-fn
    (list (p 'String))
    #f
    (p 'Int))
   'host.process/fifo-open-read
   (type-fn
    (list (p 'String))
    #f
    (p 'Int))
   'host.process/fifo-write-deadline
   (type-fn
    (list (p 'String) (p 'String) (p 'Int))
    #f
    (p 'Int))
   'host.process/poll-readable
   (type-fn
    (list (type-app 'Vec (list (p 'Int))) (p 'Int))
    #f
    (p 'Int))
   'host.process/current-pid
   (type-fn '() #f (p 'Int))
   'host.process/alive?
   (type-fn
    (list (p 'Int))
    #f
    (p 'Bool))
   'host.process/signal
   (type-fn
    (list (p 'Int) (p 'Int))
    #f
    (p 'Int))
   'host.process/wait-not-alive
   (type-fn
    (list (p 'Int) (p 'Int))
    #f
    (p 'Int))
   'host.process/wait
   (type-fn
    (list (p 'Int))
    #f
    (p 'Int))
   'host.process/close
   (type-fn
    (list (p 'Int))
    #f
    (p 'Int))))

(define CORE-RESULT-UNIONS
  (list
   (list
    'host.fs/PathKindResult
    (list
     (list 'host.fs/PathKindOk
           (list (cons ':kind (p 'Int))))
     (list 'host.fs/PathKindError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/ReadTextBoundedResult
    (list
     (list 'host.fs/ReadTextBoundedOk
           (list (cons ':text (p 'String))))
     (list 'host.fs/ReadTextBoundedError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/ListDirectoryBoundedResult
    (list
     (list 'host.fs/ListDirectoryBoundedOk
           (list (cons ':paths (type-app 'Vec (list (p 'String))))))
     (list 'host.fs/ListDirectoryBoundedError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/WriteTextAtomicResult
    (list
     (list 'host.fs/WriteTextAtomicOk '())
     (list 'host.fs/WriteTextAtomicError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/MakeParentDirectoriesResult
    (list
     (list 'host.fs/MakeParentDirectoriesOk '())
     (list 'host.fs/MakeParentDirectoriesError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/AppendTextResult
    (list
     (list 'host.fs/AppendTextOk '())
     (list 'host.fs/AppendTextError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/LockExclusiveResult
    (list
     (list 'host.fs/LockExclusiveOk
           (list (cons ':descriptor (p 'Int))))
     (list 'host.fs/LockExclusiveError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.fs/UnlockResult
    (list
     (list 'host.fs/UnlockOk '())
     (list 'host.fs/UnlockError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.clock/FormatIso8601Result
    (list
     (list 'host.clock/FormatIso8601Ok
           (list (cons ':text (p 'String))))
     (list 'host.clock/FormatIso8601Error
           (list (cons ':errno (p 'Int))))))
   (list
    'host.system/HostnameResult
    (list
     (list 'host.system/HostnameOk
           (list (cons ':hostname (p 'String))))
     (list 'host.system/HostnameError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.process/CaptureResult
    (list
     (list 'host.process/CaptureOk
           (list (cons ':status (p 'Int))
                 (cons ':stdout (p 'String))
                 (cons ':stderr (p 'String))))
     (list 'host.process/CaptureError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.process/SpawnStdoutResult
    (list
     (list 'host.process/SpawnStdoutOk
           (list (cons ':pid (p 'Int))
                 (cons ':stdout-fd (p 'Int))))
     (list 'host.process/SpawnStdoutError
           (list (cons ':errno (p 'Int))))))
   (list
    'host.process/ReadLineResult
    (list
     (list 'host.process/ReadLineOk
           (list (cons ':line (p 'String))
                 (cons ':eof (p 'Bool))))
     (list 'host.process/ReadLineError
           (list (cons ':errno (p 'Int))))))))

(provide STDLIB-CORE CORE-RESULT-UNIONS)

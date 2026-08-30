#lang racket/base

;; JVM CLASS-SIGNATURE TABLE — typed host-class interop for the clj target.
;;
;; A committed, FQCN-keyed table loaded as pure Racket data at expand-time
;; (sibling to stdlib-bb.rkt). Unlike the flat stdlib-clj.rkt method table
;; (one global `.write` for every class, receiver = Any), every method here is
;; RECEIVER-TYPED: its first param is the OWNING class nominal. The checker
;; resolves `(.method recv args)` / `(Class. args)` / `Class/static` against
;; THIS table keyed by the receiver's class, so unknown method, wrong-receiver
;; method, arg-mismatch, and unknown class all become compile errors instead of
;; bailing to Any.
;;
;; Seed = store's daemon interop inventory (cnf_coord_daemon.clj + rt.clj), per
;; .scratch/p1-manifest-seed.md. Hand-curated; deliberate-Any positions (byte[]
;; and the generic-array construction sites) are gap-listed as (Arr Any), not a
;; silent bail. Expand by hand or via the offline reflection generator (later).

(require "types.rkt")

;; A class entry: constructor overloads, instance methods, static methods.
;;   ctors   : (listof type-fn)                     — RETURN = the class nominal
;;   methods : hasheq< sym -> (listof type-fn) >     — overload set per name;
;;             every type-fn's FIRST param = the owning class nominal
;;   statics : hasheq< sym -> (listof type-fn) >
(struct class-entry (ctors methods statics) #:transparent)

;; --- tiny builders --------------------------------------------------------
(define (C n) (type-prim n))                  ; class / primitive nominal
(define ANY  (type-prim 'Any))
(define NIL  (type-prim 'Nil))
(define BOOL (type-prim 'Bool))
(define INT  (type-prim 'Int))
(define STR  (type-prim 'String))
(define (ARR e) (type-app 'Arr (list e)))     ; JVM array T[]
(define (U . alternatives) (type-union alternatives))
(define (FN args ret) (type-fn args #f ret))

;; group (cons name type-fn) pairs into hasheq name -> (listof type-fn) overloads
(define (group pairs)
  (for/fold ([h (hasheq)]) ([pr (in-list pairs)])
    (hash-update h (car pr) (lambda (l) (cons (cdr pr) l)) '())))

;; M: an instance method — receiver (owning class nominal) is the first param.
(define (M recv name args ret) (cons name (FN (cons recv args) ret)))
;; S: a static method — no receiver.
(define (S name args ret) (cons name (FN args ret)))

(define (mk fqcn ctors methods statics)
  (class-entry ctors (group methods) (group statics)))

;; Class nominals reused across signatures.
(define FOS  'java.io.FileOutputStream)
(define FIS  'java.io.FileInputStream)
(define FILE 'java.io.File)
(define OS   'java.io.OutputStream)
(define IS   'java.io.InputStream)
(define FCH  'java.nio.channels.FileChannel)
(define RAF  'java.io.RandomAccessFile)
(define BB   'java.nio.ByteBuffer)
(define MBB  'java.nio.MappedByteBuffer)
(define SOCK 'java.net.Socket)
(define SSOCK 'java.net.ServerSocket)
(define ISA  'java.net.InetSocketAddress)
(define IA   'java.net.InetAddress)
(define KS   'java.security.KeyStore)
(define SSLC 'javax.net.ssl.SSLContext)
(define KMF  'javax.net.ssl.KeyManagerFactory)
(define TMF  'javax.net.ssl.TrustManagerFactory)
(define SSF  'javax.net.ssl.SSLServerSocketFactory)
(define SF   'javax.net.ssl.SSLSocketFactory)
(define KM   'javax.net.ssl.KeyManager)
(define TM   'javax.net.ssl.TrustManager)
(define SSSOCK 'javax.net.ssl.SSLServerSocket)
(define SSLSOCK 'javax.net.ssl.SSLSocket)
(define THREAD 'java.lang.Thread)
(define SB   'java.lang.StringBuilder)
(define SYSTEM 'System)

(define CLASS-TABLE
  (hasheq
   ;; --- the fsync durability chain ----------------------------------------
   FOS
   (mk FOS
       (list (FN (list STR BOOL) (C FOS)) (FN (list STR) (C FOS)))
       (list (M (C FOS) 'write     (list (ARR ANY)) NIL)   ; byte[] gap-listed
             (M (C FOS) 'flush     '() NIL)
             (M (C FOS) 'getChannel '() (C FCH))
             (M (C FOS) 'close     '() NIL))
       '())
   FCH
   (mk FCH '()
       (list (M (C FCH) 'force (list BOOL) NIL)
             (M (C FCH) 'read (list (U (C BB) (C MBB))) INT)
             (M (C FCH) 'read (list (U (C BB) (C MBB)) INT) INT)
             (M (C FCH) 'write (list (U (C BB) (C MBB))) INT)
             (M (C FCH) 'write (list (U (C BB) (C MBB)) INT) INT)
             (M (C FCH) 'map (list ANY INT INT) (C MBB))
             (M (C FCH) 'position '() INT)
             (M (C FCH) 'position (list INT) (C FCH))
             (M (C FCH) 'size '() INT)
             (M (C FCH) 'truncate (list INT) (C FCH))
             (M (C FCH) 'isOpen '() BOOL)
             (M (C FCH) 'close '() NIL))
       (list (S 'open (list ANY ANY) (C FCH))))
   OS
   (mk OS '()
       (list (M (C OS) 'write (list (ARR ANY)) NIL)
             (M (C OS) 'flush '() NIL)
             (M (C OS) 'close '() NIL))
       '())
   IS
   (mk IS '()
       (list (M (C IS) 'read '() INT)
             (M (C IS) 'close '() NIL))
       '())

   ;; --- files -------------------------------------------------------------
   FILE
   (mk FILE
       (list (FN (list STR) (C FILE))
             (FN (list STR STR) (C FILE))
             (FN (list (C FILE) STR) (C FILE)))
       (list (M (C FILE) 'exists       '() BOOL)
             (M (C FILE) 'length       '() INT)
             (M (C FILE) 'lastModified '() INT)
             (M (C FILE) 'isDirectory  '() BOOL)
             (M (C FILE) 'isFile       '() BOOL)
             (M (C FILE) 'isAbsolute   '() BOOL)
             (M (C FILE) 'mkdirs       '() BOOL)
             (M (C FILE) 'delete       '() BOOL)
             (M (C FILE) 'getName      '() STR)
             (M (C FILE) 'getPath      '() STR)
             (M (C FILE) 'getCanonicalPath '() STR)
             (M (C FILE) 'getCanonicalFile '() (C FILE))
             (M (C FILE) 'getParentFile '() (U NIL (C FILE)))
             (M (C FILE) 'listFiles    '() (ARR (C FILE)))
             (M (C FILE) 'toPath       '() ANY)
             (M (C FILE) 'toString     '() STR))
       '())
   FIS
   (mk FIS
       (list (FN (list STR) (C FIS)) (FN (list (C FILE)) (C FIS)))
       (list (M (C FIS) 'read '() INT) (M (C FIS) 'close '() NIL))
       '())
   RAF
   (mk RAF
       (list (FN (list STR STR) (C RAF))
             (FN (list (C FILE) STR) (C RAF)))
       (list (M (C RAF) 'getChannel '() (C FCH))
             (M (C RAF) 'length '() INT)
             (M (C RAF) 'setLength (list INT) NIL)
             (M (C RAF) 'seek (list INT) NIL)
             (M (C RAF) 'getFilePointer '() INT)
             (M (C RAF) 'readInt '() INT)
             (M (C RAF) 'read (list (ARR (C 'I8))) INT)
             (M (C RAF) 'read (list (ARR (C 'I8)) INT INT) INT)
             (M (C RAF) 'readFully (list (ARR (C 'I8))) NIL)
             (M (C RAF) 'readFully (list (ARR (C 'I8)) INT INT) NIL)
             (M (C RAF) 'write (list (ARR (C 'I8))) NIL)
             (M (C RAF) 'write (list (ARR (C 'I8)) INT INT) NIL)
             (M (C RAF) 'close '() NIL))
       '())

   ;; --- packed-store byte buffers ----------------------------------------
   BB
   (mk BB '()
       (list (M (C BB) 'order (list ANY) (C BB))
             (M (C BB) 'duplicate '() (C BB))
             (M (C BB) 'slice '() (C BB))
             (M (C BB) 'position '() INT)
             (M (C BB) 'position (list INT) (C BB))
             (M (C BB) 'limit '() INT)
             (M (C BB) 'limit (list INT) (C BB))
             (M (C BB) 'remaining '() INT)
             (M (C BB) 'hasRemaining '() BOOL)
             (M (C BB) 'get '() (C 'I8))
             (M (C BB) 'get (list INT) (C 'I8))
             (M (C BB) 'get (list (ARR (C 'I8))) (C BB))
             (M (C BB) 'get (list (ARR (C 'I8)) INT INT) (C BB))
             (M (C BB) 'getShort '() INT)
             (M (C BB) 'getShort (list INT) INT)
             (M (C BB) 'getInt '() INT)
             (M (C BB) 'getInt (list INT) INT)
             (M (C BB) 'getLong '() INT)
             (M (C BB) 'getLong (list INT) INT)
             (M (C BB) 'put (list (C 'I8)) (C BB))
             (M (C BB) 'put (list INT (C 'I8)) (C BB))
             (M (C BB) 'put (list (ARR (C 'I8))) (C BB))
             (M (C BB) 'put (list (ARR (C 'I8)) INT INT) (C BB))
             (M (C BB) 'put (list (C BB)) (C BB))
             (M (C BB) 'putInt (list INT) (C BB))
             (M (C BB) 'putInt (list INT INT) (C BB))
             (M (C BB) 'putLong (list INT) (C BB))
             (M (C BB) 'putLong (list INT INT) (C BB))
             (M (C BB) 'flip '() (C BB))
             (M (C BB) 'clear '() (C BB))
             (M (C BB) 'rewind '() (C BB)))
       (list (S 'allocate (list INT) (C BB))
             (S 'allocateDirect (list INT) (C BB))
             (S 'wrap (list (ARR (C 'I8))) (C BB))
             (S 'wrap (list (ARR (C 'I8)) INT INT) (C BB))))
   MBB
   (mk MBB '()
       (list (M (C MBB) 'order (list ANY) (C BB))
             (M (C MBB) 'duplicate '() (C BB))
             (M (C MBB) 'slice '() (C BB))
             (M (C MBB) 'position '() INT)
             (M (C MBB) 'position (list INT) (C BB))
             (M (C MBB) 'limit '() INT)
             (M (C MBB) 'limit (list INT) (C BB))
             (M (C MBB) 'remaining '() INT)
             (M (C MBB) 'hasRemaining '() BOOL)
             (M (C MBB) 'get '() (C 'I8))
             (M (C MBB) 'get (list INT) (C 'I8))
             (M (C MBB) 'get (list (ARR (C 'I8))) (C BB))
             (M (C MBB) 'getShort '() INT)
             (M (C MBB) 'getShort (list INT) INT)
             (M (C MBB) 'getInt '() INT)
             (M (C MBB) 'getInt (list INT) INT)
             (M (C MBB) 'getLong '() INT)
             (M (C MBB) 'getLong (list INT) INT)
             (M (C MBB) 'force '() (C MBB))
             (M (C MBB) 'load '() (C MBB))
             (M (C MBB) 'isLoaded '() BOOL))
       '())

   ;; --- sockets -----------------------------------------------------------
   SOCK
   (mk SOCK
       (list (FN '() (C SOCK))
             (FN (list STR INT) (C SOCK)))
       (list (M (C SOCK) 'getOutputStream '() (C OS))
             (M (C SOCK) 'getInputStream  '() (C IS))
             (M (C SOCK) 'setSoTimeout    (list INT) NIL)
             (M (C SOCK) 'connect         (list ANY) NIL)   ; SocketAddress
             (M (C SOCK) 'connect         (list ANY INT) NIL) ; SocketAddress, timeout
             (M (C SOCK) 'close           '() NIL))
       '())
   SSOCK
   (mk SSOCK
       (list (FN '() (C SSOCK))
             (FN (list INT) (C SSOCK)))
       (list (M (C SSOCK) 'bind            (list (C ISA)) NIL)
             (M (C SSOCK) 'getLocalPort    '() INT)
             (M (C SSOCK) 'setReuseAddress (list BOOL) NIL)
             (M (C SSOCK) 'setSoTimeout    (list INT) NIL)
             (M (C SSOCK) 'accept          '() (C SOCK))
             (M (C SSOCK) 'close           '() NIL))
       '())
   ISA
   (mk ISA
       (list (FN (list (C IA) INT) (C ISA)) (FN (list STR INT) (C ISA)))
       '() '())
   IA
   (mk IA '() '()
       (list (S 'getLoopbackAddress '() (C IA))
             (S 'getByName (list STR) (C IA))))

   ;; --- mTLS --------------------------------------------------------------
   KS
   (mk KS '()
       (list (M (C KS) 'load (list (C IS) (ARR ANY)) NIL))   ; char[] gap-listed
       (list (S 'getInstance (list STR) (C KS))))
   KMF
   (mk KMF '()
       (list (M (C KMF) 'init           (list (C KS) (ARR ANY)) NIL)  ; char[] password (gap)
             (M (C KMF) 'getKeyManagers '() (ARR (C KM))))            ; KeyManager[] — typed container
       (list (S 'getInstance (list STR) (C KMF))
             (S 'getDefaultAlgorithm '() STR)))
   TMF
   (mk TMF '()
       (list (M (C TMF) 'init             (list (C KS)) NIL)
             (M (C TMF) 'getTrustManagers '() (ARR (C TM))))          ; TrustManager[] — typed container
       (list (S 'getInstance (list STR) (C TMF))
             (S 'getDefaultAlgorithm '() STR)))
   SSLC
   (mk SSLC '()
       ;; init(KeyManager[], TrustManager[], SecureRandom) — array containers typed;
       ;; the arrays flow in from getKeyManagers/getTrustManagers (themselves typed).
       (list (M (C SSLC) 'init (list (ARR (C KM)) (ARR (C TM)) ANY) NIL)
             (M (C SSLC) 'getServerSocketFactory '() (C SSF))
             (M (C SSLC) 'getSocketFactory '() (C SF)))
       (list (S 'getInstance (list STR) (C SSLC))))
   SSF
   (mk SSF '()
       (list (M (C SSF) 'createServerSocket '() (C SSSOCK)))
       '())
   SF
   (mk SF '()
       (list (M (C SF) 'createSocket '() (C SSLSOCK)))
       '())
   SSSOCK
   ;; SSLServerSocket arrives via SSLContext.getServerSocketFactory().createServerSocket()
   (mk SSSOCK '()
       (list (M (C SSSOCK) 'setEnabledProtocols (list (ARR STR)) NIL) ; String[] — typed container
             (M (C SSSOCK) 'setNeedClientAuth   (list BOOL) NIL)
             (M (C SSSOCK) 'setReuseAddress     (list BOOL) NIL)
             (M (C SSSOCK) 'setSoTimeout        (list INT) NIL)
             (M (C SSSOCK) 'bind                (list (C ISA)) NIL)
             (M (C SSSOCK) 'accept              '() (C SOCK)))
       '())
   SSLSOCK
   (mk SSLSOCK '()
       (list (M (C SSLSOCK) 'startHandshake '() NIL)
             (M (C SSLSOCK) 'getOutputStream '() (C OS))
             (M (C SSLSOCK) 'getInputStream  '() (C IS)))
       '())

   ;; --- threads + misc ----------------------------------------------------
   THREAD
   (mk THREAD
       (list (FN (list ANY STR) (C THREAD)) (FN (list ANY) (C THREAD))) ; Runnable Any
       (list (M (C THREAD) 'setDaemon (list BOOL) NIL)
             (M (C THREAD) 'start '() NIL))
       (list (S 'sleep (list INT) NIL)))
   SB
   (mk SB
       (list (FN '() (C SB)))
       (list (M (C SB) 'append   (list ANY) (C SB))
             (M (C SB) 'charAt   (list INT) ANY)
             (M (C SB) 'toString '() STR)
             (M (C SB) 'length   '() INT))
       '())
   SYSTEM
   (mk SYSTEM '() '()
       (list (S 'getenv '() (type-app 'Map (list STR STR)))
             (S 'getenv (list STR) (U STR NIL))))))

(provide (struct-out class-entry) CLASS-TABLE)

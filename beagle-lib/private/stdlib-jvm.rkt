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
;; Seed = fram's daemon interop inventory (cnf_coord_daemon.clj + rt.clj), per
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
(define SSSOCK 'javax.net.ssl.SSLServerSocket)
(define SSLSOCK 'javax.net.ssl.SSLSocket)
(define THREAD 'java.lang.Thread)
(define SB   'java.lang.StringBuilder)

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
             (M (C FCH) 'close '() NIL))
       '())
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
       (list (FN (list STR) (C FILE)))
       (list (M (C FILE) 'exists       '() BOOL)
             (M (C FILE) 'length       '() INT)
             (M (C FILE) 'lastModified '() INT)
             (M (C FILE) 'isDirectory  '() BOOL)
             (M (C FILE) 'mkdirs       '() BOOL)
             (M (C FILE) 'delete       '() BOOL)
             (M (C FILE) 'getName      '() STR)
             (M (C FILE) 'listFiles    '() (ARR (C FILE)))
             (M (C FILE) 'toPath       '() ANY)
             (M (C FILE) 'toString     '() STR))
       '())
   FIS
   (mk FIS
       (list (FN (list STR) (C FIS)) (FN (list (C FILE)) (C FIS)))
       (list (M (C FIS) 'read '() INT) (M (C FIS) 'close '() NIL))
       '())

   ;; --- sockets -----------------------------------------------------------
   SOCK
   (mk SOCK
       (list (FN '() (C SOCK)))
       (list (M (C SOCK) 'getOutputStream '() (C OS))
             (M (C SOCK) 'getInputStream  '() (C IS))
             (M (C SOCK) 'setSoTimeout    (list INT) NIL)
             (M (C SOCK) 'connect         (list ANY) NIL)   ; SocketAddress
             (M (C SOCK) 'close           '() NIL))
       '())
   SSOCK
   (mk SSOCK
       (list (FN '() (C SSOCK)))
       (list (M (C SSOCK) 'bind            (list (C ISA)) NIL)
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
       (list (M (C KMF) 'init           (list (C KS) (ARR ANY)) NIL)
             (M (C KMF) 'getKeyManagers '() (ARR ANY)))       ; KeyManager[] gap
       (list (S 'getInstance (list STR) (C KMF))
             (S 'getDefaultAlgorithm '() STR)))
   TMF
   (mk TMF '()
       (list (M (C TMF) 'init             (list (C KS)) NIL)
             (M (C TMF) 'getTrustManagers '() (ARR ANY)))     ; TrustManager[] gap
       (list (S 'getInstance (list STR) (C TMF))
             (S 'getDefaultAlgorithm '() STR)))
   SSLC
   (mk SSLC '()
       (list (M (C SSLC) 'init (list (ARR ANY) (ARR ANY) ANY) NIL) ; KM[]/TM[] gap, SecureRandom Any
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
       (list (M (C SSSOCK) 'setEnabledProtocols (list (ARR ANY)) NIL) ; String[] gap
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
       '())))

(provide (struct-out class-entry) CLASS-TABLE)

#lang racket/base

;; JS capability sets and operator tables.
;; Single source of truth for: which symbols emit-js knows how to translate,
;; how infix/unary operators map to JS source, which symbols need the runtime.

(require racket/set)

;; --- operator translation tables -------------------------------------------
;; Hash from symbol → JS operator string. Used by emit-js to render infix
;; calls. The keys also serve as the membership test for `js-infix?`/`js-unary?`.

(define JS-INFIX-OPS
  (hash '+ "+" '- "-" '* "*" '/ "/"
        '< "<" '> ">" '<= "<=" '>= ">="
        '= "===" 'not= "!==" '== "==="
        'mod "%" 'identical? "==="))

(define JS-UNARY-OPS
  (hash 'not "!"))

;; Symbol-only sets for set-union into JS-TRANSLATED.
(define JS-INFIX-OP-SYMS (list->set (hash-keys JS-INFIX-OPS)))
(define JS-UNARY-OP-SYMS (list->set (hash-keys JS-UNARY-OPS)))

(define JS-CORE-CALL
  (set 'str 'println 'print 'pr 'prn
       'nil? 'some? 'true? 'false? 'zero? 'pos? 'neg? 'even? 'odd?
       'count 'empty? 'first 'second 'last 'rest 'nth
       'conj 'cons 'assoc 'inc 'dec 'abs 'max 'min 'rand 'rand-int
       'vec 'set 'contains? 'keys 'vals
       'map 'filter 'reduce 'reverse 'sort 'into 'concat
       'apply 'identity 'boolean
       'string? 'number? 'keyword? 'symbol? 'fn? 'integer? 'boolean? 'any? 'list? 'infinite?
       'and 'or
       'throw 'ex-info 'ex-message 'ex-data
       'name 'keyword 'subs 're-find 're-pattern 're-matches 're-seq 're-groups
       'atom 'deref 'reset! 'swap! 'add-watch 'remove-watch 'compare-and-set!
       'mapv 'filterv 'get 'update 'merge 'dissoc
       'subvec 'pop 'peek 'take 'drop
       'some 'distinct 'flatten 'not-empty 'sort-by
       'partition 'interleave 'frequencies 'group-by
       'comp 'partial 'constantly 'complement 'juxt
       'vector? 'map? 'set? 'sequential? 'seq? 'coll?
       'take-last 'drop-last
       'pr-str 'to-array 'aget 'aset 'array-seq 'clj->js 'js->clj
       'not= 'seq
       ;; batch 2
       'butlast 'nfirst 'nnext 'fnext 'ffirst 'nthrest 'nthnext
       'rand-nth 'shuffle 'quot 'rem 'compare
       'not-any? 'not-every? 'distinct?
       'run! 'find 'key 'val 'next 'empty
       'vector 'list 'hash-map 'hash-set
       'repeat 'repeatedly 'split-at 'newline 'printf
       'gensym 'random-uuid 'parse-long 'parse-double 'parse-boolean
       ;; bitwise
       'bit-and 'bit-or 'bit-xor 'bit-not
       'bit-shift-left 'bit-shift-right 'unsigned-bit-shift-right
       'bit-test 'bit-set 'bit-clear 'bit-flip 'bit-and-not))

(define JS-RUNTIME-HELPERS
  (set 'range 'remove 'mapcat 'every? 'keep 'map-indexed
       'assoc-in 'update-in 'select-keys 'merge-with
       'take-while 'drop-while
       ;; batch 2
       'memoize 'fnil 'some-fn 'every-pred
       'rename-keys 'map-keys 'map-vals 'update-keys 'update-vals
       'disj 'reduce-kv 'dedupe 'interpose
       'partition-all 'partition-by 'split-with 'zipmap
       'format 'hash
       'get-in 'take-nth 'keep-indexed 'reductions 'replace
       'max-key 'min-key))

(define JS-TRANSLATED
  (set-union JS-INFIX-OP-SYMS JS-UNARY-OP-SYMS JS-CORE-CALL JS-RUNTIME-HELPERS))

(define JS-VALUE-WRAPPERS
  (hash
   'inc       "((_x) => (_x + 1))"
   'dec       "((_x) => (_x - 1))"
   '+         "((_a, _b) => _a + _b)"
   '-         "((_a, _b) => _a - _b)"
   '*         "((_a, _b) => _a * _b)"
   '/         "((_a, _b) => _a / _b)"
   'mod       "((_a, _b) => _a % _b)"
   'str       "((..._xs) => \"\".concat(..._xs))"
   'identity  "((_x) => _x)"
   'nil?      "((_x) => _x == null)"
   'some?     "((_x) => _x != null)"
   'true?     "((_x) => _x === true)"
   'false?    "((_x) => _x === false)"
   'zero?     "((_x) => _x === 0)"
   'pos?      "((_x) => _x > 0)"
   'neg?      "((_x) => _x < 0)"
   'even?     "((_x) => _x % 2 === 0)"
   'odd?      "((_x) => _x % 2 !== 0)"
   'not       "((_x) => !_x)"
   'string?   "((_x) => typeof _x === 'string')"
   'number?   "((_x) => typeof _x === 'number')"
   'keyword?  "((_x) => typeof _x === 'string')"
   'fn?       "((_x) => typeof _x === 'function')"
   'integer?  "((_x) => Number.isInteger(_x))"
   'vector?   "((_x) => Array.isArray(_x))"
   'sequential? "((_x) => Array.isArray(_x))"
   'seq?      "((_x) => Array.isArray(_x))"
   'empty?    "((_x) => _x.length === 0)"
   'count     "((_x) => _x.length)"
   'first     "((_x) => _x[0])"
   'second    "((_x) => _x[1])"
   'last      "((_x) => _x[_x.length - 1])"
   'rest      "((_x) => _x.slice(1))"
   'abs       "((_x) => Math.abs(_x))"
   'boolean   "((_x) => Boolean(_x))"
   'name      "((_x) => String(_x))"
   'cons      "((_x, _xs) => [_x, ..._xs])"
   'butlast   "((_xs) => _xs.slice(0, -1))"
   'boolean?  "((_x) => typeof _x === 'boolean')"
   'symbol?   "((_x) => typeof _x === 'symbol')"
   'list?     "((_x) => Array.isArray(_x))"
   'any?      "((_x) => true)"
   'quot      "((_a, _b) => Math.trunc(_a / _b))"
   'rem       "((_a, _b) => _a % _b)"
   'run!      "((_f, _c) => (_c.forEach(_f), null))"
   ))

(provide JS-TRANSLATED
         JS-INFIX-OPS JS-UNARY-OPS
         JS-INFIX-OP-SYMS JS-UNARY-OP-SYMS
         JS-CORE-CALL JS-RUNTIME-HELPERS JS-VALUE-WRAPPERS)

#lang racket/base

(require racket/set)

(define JS-INFIX-OPS
  (set '+ '- '* '/ '< '> '<= '>= '= '== 'not= 'mod 'identical?))

(define JS-UNARY-OPS
  (set 'not))

(define JS-CORE-CALL
  (set 'str 'println 'print 'pr 'prn
       'nil? 'some? 'true? 'false? 'zero? 'pos? 'neg? 'even? 'odd?
       'count 'empty? 'first 'second 'last 'rest 'nth
       'conj 'assoc 'inc 'dec 'abs 'max 'min 'rand 'rand-int
       'vec 'set 'contains? 'keys 'vals
       'map 'filter 'reduce 'reverse 'sort 'into 'concat
       'apply 'identity 'boolean
       'string? 'number? 'keyword? 'fn? 'integer?
       'and 'or
       'throw 'ex-info 'ex-message 'ex-data
       'name 'keyword 'subs 're-find
       'atom 'deref 'reset! 'swap! 'add-watch 'remove-watch
       'mapv 'filterv 'get 'update 'merge 'dissoc
       'subvec 'pop 'peek 'take 'drop
       'some 'distinct 'flatten 'not-empty 'sort-by
       'partition 'interleave 'frequencies 'group-by
       'comp 'partial 'constantly 'complement 'juxt
       'vector? 'map? 'set? 'sequential? 'seq? 'coll?
       'take-last 'drop-last
       'pr-str 'to-array 'aget 'aset 'array-seq 'clj->js 'js->clj
       'not= 'seq))

(define JS-RUNTIME-HELPERS
  (set 'range 'remove 'mapcat 'every? 'keep 'map-indexed
       'assoc-in 'update-in 'select-keys 'merge-with
       'take-while 'drop-while))

(define JS-TRANSLATED
  (set-union JS-INFIX-OPS JS-UNARY-OPS JS-CORE-CALL JS-RUNTIME-HELPERS))

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
   ))

(provide JS-TRANSLATED JS-INFIX-OPS JS-UNARY-OPS JS-CORE-CALL
         JS-RUNTIME-HELPERS JS-VALUE-WRAPPERS)

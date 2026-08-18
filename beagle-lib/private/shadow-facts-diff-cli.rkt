#lang racket/base

(require racket/list
         "shadow-facts-v1.rkt")

(define args (vector->list (current-command-line-arguments)))
(unless (= (length args) 2)
  (eprintf "usage: beagle-shadow-diff BEFORE.graph AFTER.graph\n")
  (exit 2))

(define differences
  (shadow-fact-graph-v1-diff
   (shadow-fact-graph-v1-read (car args))
   (shadow-fact-graph-v1-read (cadr args))))

(for ([difference (in-list differences)])
  (printf "~a source=~a key=~a ~a before=~s after=~s justified-by=~s\n"
          (if (null? (shadow-divergence-v1-justified-by difference))
              "FINDING"
              "DIVERGENCE")
          (shadow-divergence-v1-source difference)
          (shadow-divergence-v1-key difference)
          (shadow-divergence-v1-reason difference)
          (shadow-divergence-v1-before difference)
          (shadow-divergence-v1-after difference)
          (shadow-divergence-v1-justified-by difference)))

(exit (if (null? differences) 0 1))

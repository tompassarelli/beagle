(ns store.rpc-limits)

(def term-codec-v1-max-depth 256)

(def rpc-v2-list-envelope-depth 6)

(def rpc-v2-unpaged-response-wrapper-depth 8)

(def rpc-v2-mutation-response-wrapper-depth 9)

(def rpc-v2-max-list-values (- term-codec-v1-max-depth rpc-v2-list-envelope-depth))

(def rpc-v2-max-unpaged-rows (- term-codec-v1-max-depth rpc-v2-unpaged-response-wrapper-depth))

(def rpc-v2-max-batch-actions (- term-codec-v1-max-depth rpc-v2-mutation-response-wrapper-depth))

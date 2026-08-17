(ns store.kernel-host)

(defn getenv [name]
  (System/getenv name))

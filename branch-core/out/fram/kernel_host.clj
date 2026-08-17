(ns fram.kernel-host)

(defn getenv [name]
  (System/getenv name))

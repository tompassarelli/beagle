(ns selfhost.emit-cljs
  (:require [clojure.string :as str]
            [selfhost.emit-clj :as ec]))

(defn ^String emit-program! [prog]
  (ec/emit-program! prog))

(def passes (atom []))

(def failures (atom []))

(defn expect! [^String label ^Boolean result]
  (if result (do
  (swap! passes conj true)
  nil) (do
  (swap! failures conj label)
  nil))
  nil)

(defn run-tests! []
  (reset! passes [])
  (reset! failures [])
  (expect! "cljs: gen-class suppressed in ns form" (let [prog {"namespace" "test.gc" "target" "cljs" "gen-class" true "requires" [] "forms" []}]
  (not (str/includes? (ec/emit-program! prog) ":gen-class"))))
  (expect! "cljs: try/catch uses :default, not type" (let [prog {"namespace" "t.tc" "target" "cljs" "gen-class" false "requires" [] "forms" [{"node" "def" "name" "safe" "type" nil "value" {"node" "try" "body" [{"node" "literal" "kind" "int" "value" 1}] "catches" [{"type" "Exception" "name" "e" "body" [{"node" "literal" "kind" "int" "value" 0}]}] "finally" false}}]}]
  (str/includes? (ec/emit-program! prog) "(catch :default")))
  (expect! "clj: try/catch uses type name, not :default" (let [prog {"namespace" "t.tc2" "target" "clj" "gen-class" false "requires" [] "forms" [{"node" "def" "name" "safe" "type" nil "value" {"node" "try" "body" [{"node" "literal" "kind" "int" "value" 1}] "catches" [{"type" "Exception" "name" "e" "body" [{"node" "literal" "kind" "int" "value" 0}]}] "finally" false}}]}]
  (str/includes? (ec/emit-program! prog) "(catch Exception")))
  (doseq [f (deref failures)]
  (println (str "  FAIL: " f)))
  (println (str "  EMIT-CLJS: " (count (deref passes)) " passed, " (count (deref failures)) " failed"))
  (count (deref failures)))

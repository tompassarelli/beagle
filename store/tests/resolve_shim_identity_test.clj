#!/usr/bin/env bb

(def names
  '[*capture-only?* *corpus-cache* *corpus-scope* *reject!*
    *resolve-walk?* *view* ACC CTOR FIXED KIND QUAL REFERS Vp ctx
    file->ents file-accessors file-modframe file-typeframe
    global-accessor-exports global-exports global-type-exports srcs tx])

(def expected
  [:capture-only :corpus-cache :corpus-scope :reject :resolve-walk :view
   :acc :ctor :fixed :kind :qual :refers :vp :ctx :file-ents
   :file-accessors :file-modframe :file-typeframe :global-accessor-exports
   :global-exports :global-type-exports :srcs :tx])

(def failures (atom 0))

(defn check! [label ok]
  (println (if ok "PASS" "FAIL") label)
  (when-not ok (swap! failures inc)))

(load-file "out/resolve.clj")
(def before (into {} (map (fn [name] [name (ns-resolve 'resolve name)]) names)))
(require 'resolve :reload)
(def after (into {} (map (fn [name] [name (ns-resolve 'resolve name)]) names)))

(check! "all 23 shim Vars exist and remain dynamic"
        (every? (fn [name]
                  (let [v (get after name)]
                    (and (var? v) (:dynamic (meta v)))))
                names))

(check! "requiring the generated resolve namespace preserves exact Var identity"
        (every? (fn [name] (identical? (get before name) (get after name))) names))

(check! "every externally-bound Var reads its exact binding"
        (binding [resolve/*capture-only?* :capture-only
                  resolve/*corpus-cache* :corpus-cache
                  resolve/*corpus-scope* :corpus-scope
                  resolve/*reject!* :reject
                  resolve/*resolve-walk?* :resolve-walk
                  resolve/*view* :view
                  resolve/ACC :acc
                  resolve/CTOR :ctor
                  resolve/FIXED :fixed
                  resolve/KIND :kind
                  resolve/QUAL :qual
                  resolve/REFERS :refers
                  resolve/Vp :vp
                  resolve/ctx :ctx
                  resolve/file->ents :file-ents
                  resolve/file-accessors :file-accessors
                  resolve/file-modframe :file-modframe
                  resolve/file-typeframe :file-typeframe
                  resolve/global-accessor-exports :global-accessor-exports
                  resolve/global-exports :global-exports
                  resolve/global-type-exports :global-type-exports
                  resolve/srcs :srcs
                  resolve/tx :tx]
          (= expected
             (mapv (fn [name] (deref (ns-resolve 'resolve name))) names))))

(println "resolve shim identity:" (- 3 @failures) "/ 3 PASS")
(when (pos? @failures) (System/exit 1))

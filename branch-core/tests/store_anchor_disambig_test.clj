#!/usr/bin/env bb
;; ============================================================================
;; store_anchor_disambig_test.clj — replace-in-body ANCHOR AUTO-DISAMBIGUATION
;; (thread 019f22bd-137d). Verb-level proof over the REAL 10.7k-node make-vim!
;; mega-def (duel D08 corpus, module chrome.bjs.tabs.vim). Zero model calls, zero
;; daemon. Proves the 4 acceptance cases:
;;   1. ambiguous :old REJECTS with a :candidates payload (parent-chain breadcrumbs
;;      + a copy-pastable :within suggestion per site); total match-count correct.
;;   2. the SAME edit retried with :within LANDS + renders byte-identical to the
;;      equivalent COARSE whole-enclosing-form replace (surgical == coarse).
;;   3. a unique :old (no :within) lands on the unchanged fast path (1 edge swap).
;;   4. :within that is ambiguous OR non-matching REJECTS (fail-closed every level).
;;   bb -cp out tests/store_anchor_disambig_test.clj   (from repo root)
;; ============================================================================
(require '[fram.store :as c] '[clojure.edn :as edn]
         '[clojure.walk :as walk] '[clojure.java.io :as io] '[clojure.string :as str]
         '[babashka.process :refer [sh]])
;; resolve.clj + its Beagle-compiled parts are bare-ns files at the repo ROOT
;; (build.sh), off the `bb -cp out` classpath — load them the way the daemon
;; does (server.clj), then alias.
(load-file "out/resolve.clj")
(alias 'r 'resolve)

(def VIM (or (System/getenv "VIM_BJS") "/home/tom/code/gjoa/src/gjoa/chrome/bjs/tabs/vim.bjs"))
(def work (str (System/getProperty "java.io.tmpdir") "/anchor-disambig-" (System/nanoTime)))
(.mkdirs (io/file work))
(def beagle-home (or (System/getenv "BEAGLE_HOME") (System/getenv "BEAGLE")
                     (str (System/getenv "HOME") "/code/beagle")))
(def beagle-bin (or (System/getenv "FRAM_BEAGLE") (str beagle-home "/bin/beagle")))
(doseq [p [beagle-bin VIM]] (when-not (.exists (io/file p)) (println "SKIP — missing" p) (System/exit 0)))
(def edn-path (str work "/vim.edn"))
(let [rr (sh {:out (io/file edn-path) :err :string}
             beagle-bin "facts-roundtrip" "--emit-edn" VIM)]
  (when-not (zero? (:exit rr)) (println "emit-edn failed:" (:err rr)) (System/exit 1)))

(def pass (atom 0)) (def fail (atom 0))
(defn check [nm ok?] (if ok? (do (swap! pass inc) (println "  [PASS]" nm))
                       (do (swap! fail inc) (println "  [FAIL]" nm))))

;; run a verb thunk; -> {:ok true} OR {:reject <code> :detail <disambig-map>}
(defn run-verb [thunk]
  (binding [r/*reject!* (fn [code & [detail]] (throw (ex-info "REJECT" {:code code :detail detail})))]
    (try (thunk) {:ok true}
         (catch clojure.lang.ExceptionInfo e (let [d (ex-data e)] {:reject (:code d) :detail (:detail d)})))))

;; render the (edited, resolved) bound module -> .bjs text.
(defn render-module [src]
  (let [ep (str work "/render-" (System/nanoTime) ".edn")]
    (r/extract-file! src ep)
    (let [rr (sh {:out :string :err :string}
                 beagle-bin "facts-roundtrip" "--render" ep)]
      (when-not (zero? (:exit rr)) (println "  render failed:" (:err rr)))
      (:out rr))))

(def NEW '(do (scheduleSave) (markSaved)))          ; the extension we splice in

(println "================ replace-in-body anchor auto-disambiguation ================")

;; ---- CASE 3 — unique :old, no :within: unchanged fast path ------------------
(r/resolve-edn!
 [edn-path]
 (fn []
   (binding [r/*capture-only?* true]
     (let [sup0 (count (:superseded @r/ctx))
           res  (run-verb #(r/verb-replace-in-body! "make-vim!" "vim"
                                                    '(create-logger! "tabs/vim") '(create-logger! "tabs/vim/v2")))]
       (check "CASE3 unique :old (no :within) lands" (:ok res))
       (check "CASE3 unique :old superseded exactly 1 fN edge" (= 1 (- (count (:superseded @r/ctx)) sup0)))))))

;; ---- CASE 1 — ambiguous :old REJECTS with a candidates payload --------------
(def payload (atom nil))
(r/resolve-edn!
 [edn-path]
 (fn []
   (binding [r/*capture-only?* true]
     (let [res (run-verb #(r/verb-replace-in-body! "make-vim!" "vim" '(scheduleSave) NEW))
           d   (:detail res)]
       (reset! payload d)
       (check "CASE1 ambiguous :old rejects (code 5)" (= 5 (:reject res)))
       (check "CASE1 reject carries :reason :ambiguous-old" (= :ambiguous-old (:reason d)))
       (check "CASE1 total match count == 13" (= 13 (:total d)))
       (check "CASE1 candidates bounded (cap 8) + total reported"
              (and (= 8 (count (:candidates d))) (= 8 (:shown d)) (= 13 (:total d))))
       (check "CASE1 every candidate carries a parent-chain breadcrumb"
              (every? #(and (vector? (:breadcrumb %)) (seq (:breadcrumb %))) (:candidates d)))
       (check "CASE1 breadcrumbs are rooted at the def (make-vim!/js-export)"
              (every? #(#{"make-vim!" "js/export" "defn"} (first (:breadcrumb %))) (:candidates d)))
       (check "CASE1 >=1 candidate offers a copy-pastable :within suggestion"
              (some :within (:candidates d)))
       (println "  --- reject :message (as surfaced to the model) ---")
       (println (str "  " (str/replace (:message d) "\n" "\n  ")))))))

;; ---- CASE 4a — :within non-matching REJECTS --------------------------------
(r/resolve-edn!
 [edn-path]
 (fn []
   (binding [r/*capture-only?* true]
     (let [res (run-verb #(r/verb-replace-in-body! "make-vim!" "vim"
                                                   '(scheduleSave) NEW '(no-such-enclosing-form-zzz 1 2 3)))]
       (check "CASE4a non-matching :within rejects (code 5, :no-within)"
              (and (= 5 (:reject res)) (= :no-within (:reason (:detail res)))))))))

;; ---- CASE 4b — :within ambiguous REJECTS -----------------------------------
(r/resolve-edn!
 [edn-path]
 (fn []
   (binding [r/*capture-only?* true]
     (let [res (run-verb #(r/verb-replace-in-body! "make-vim!" "vim"
                                                   '(markSaved) '(x) '(scheduleSave)))]  ; within matches 13x
       (check "CASE4b ambiguous :within rejects (code 5, :ambiguous-within)"
              (and (= 5 (:reject res)) (= :ambiguous-within (:reason (:detail res)))))
       (check "CASE4b ambiguous :within reports total match count (13)"
              (= 13 (:total (:detail res))))))))

;; ---- CASE 2 — :within LANDS + byte-identical to the coarse whole-form edit --
;; Drive the remedy END-TO-END: lift a :within suggestion straight out of CASE1's
;; reject payload and retry. Compare the surgical (:within, swap-one-leaf) render to
;; the equivalent COARSE render (replace the WHOLE enclosing form W with W-swapped) —
;; must be byte-identical. (A candidate whose W carries interior comments legitimately
;; differs — that is replace-in-body's comment-preservation win — so we accept the
;; FIRST byte-equal candidate as the proof and require >=1 exists.)
(def cands (vec (keep :within (:candidates @payload))))
(def R0 (atom nil))
(r/resolve-edn! [edn-path] (fn [] (binding [r/*capture-only?* false] (reset! R0 (render-module (first r/srcs))))))
(def byte-equal-hit (atom nil))
(doseq [within-str cands :while (nil? @byte-equal-hit)]
  (let [W (edn/read-string within-str)
        W-swapped (walk/postwalk (fn [x] (if (= x '(scheduleSave)) NEW x)) W)
        R-within (atom nil) R-coarse (atom nil)]
    (r/resolve-edn! [edn-path] (fn [] (binding [r/*capture-only?* false]
                                        (r/verb-replace-in-body! "make-vim!" "vim" '(scheduleSave) NEW W)
                                        (reset! R-within (render-module (first r/srcs))))))
    (r/resolve-edn! [edn-path] (fn [] (binding [r/*capture-only?* false]
                                        (r/verb-replace-in-body! "make-vim!" "vim" W W-swapped)
                                        (reset! R-coarse (render-module (first r/srcs))))))
    (when (and @R-within @R-coarse (= @R-within @R-coarse) (not= @R-within @R0))
      (reset! byte-equal-hit {:within within-str :r @R-within}))))
(check "CASE2 :within edit LANDS + is byte-identical to the equivalent coarse whole-form edit"
       (some? @byte-equal-hit))
(check "CASE2 the :within edit actually changed the module (localized, edit took)"
       (and @byte-equal-hit @R0 (not= (:r @byte-equal-hit) @R0)))
(when @byte-equal-hit
  (println (str "  proof :within = " (subs (:within @byte-equal-hit) 0 (min 120 (count (:within @byte-equal-hit))))
                (when (> (count (:within @byte-equal-hit)) 120) " ..."))))

(sh {} "rm" "-rf" work)
(println (str "\nanchor-disambiguation: " @pass " / " (+ @pass @fail) " PASS"))
(when (pos? @fail) (System/exit 1))

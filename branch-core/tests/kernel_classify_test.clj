;; Every assertion is lifted from the site fram.kernel-classify replaces, so
;; drift in EITHER direction fails.
(require '[fram.kernel-classify :as kc])

(def failures (atom 0))
(def total (atom 0))
;; The fold key separator, spelled as a code point so it cannot be lost to an
;; editor or a copy that eats an invisible byte.
(def SEP (str (char 1)))

(defn check [label pred]
  (swap! total inc)
  (println (if pred "PASS" "FAIL") label)
  (when-not pred (swap! failures inc)))

;; --- strip-at (kernel.bgl:261) ----------------------------------------------
(check "strip-at drops one leading @" (= "depends_on" (kc/strip-at "@depends_on")))
(check "strip-at leaves a bare name alone" (= "depends_on" (kc/strip-at "depends_on")))
(check "strip-at drops ONLY the first @" (= "@a" (kc/strip-at "@@a")))
(check "strip-at of a bare @ is empty" (= "" (kc/strip-at "@")))
(check "strip-at of empty is empty" (= "" (kc/strip-at "")))

;; --- ref-shape? (server.clj:1821) -------------------------------------
(check "ref-shape? accepts @id" (true? (kc/ref-shape? "@2026-07-30-thing")))
(check "ref-shape? rejects a bare @ (length > 1)" (false? (kc/ref-shape? "@")))
(check "ref-shape? rejects the empty string" (false? (kc/ref-shape? "")))
(check "ref-shape? rejects an unprefixed id" (false? (kc/ref-shape? "thing")))
(check "ref-shape? rejects an embedded space" (false? (kc/ref-shape? "@two words")))
(check "ref-shape? rejects an embedded tab" (false? (kc/ref-shape? "@two\twords")))
(check "ref-shape? rejects a trailing newline" (false? (kc/ref-shape? "@thing\n")))

;; --- has-whitespace? --------------------------------------------------------
(check "has-whitespace? is false for a clean ref" (false? (kc/has-whitespace? "@a-b_c")))
(check "has-whitespace? sees a space" (true? (kc/has-whitespace? "a b")))
(check "has-whitespace? sees a newline" (true? (kc/has-whitespace? "a\nb")))
;; Whitespace is the six ASCII bytes {9,10,11,12,13,32}, the set server's #"\s"
;; already recognized. VT/FF spell as \uNNNN in the lowerable subset, the same
;; form key-sep uses.
(doseq [[label code] [["TAB" 9] ["LF" 10] ["VT" 11] ["FF" 12] ["CR" 13] ["space" 32]]]
  (check (str "has-whitespace? sees " label)
         (true? (kc/has-whitespace? (str "a" (char code) "b")))))
(check "has-whitespace? ignores a non-whitespace control byte"
       (false? (kc/has-whitespace? (str "a" (char 0) "b"))))

;; --- emoji-single? (kernel.bgl:120) -----------------------------------------
(check "emoji-single? on the emoji_ prefix" (true? (kc/emoji-single? "emoji_blocked")))
(check "emoji-single? off a non-emoji pred" (false? (kc/emoji-single? "title")))
(check "emoji-single? needs the underscore" (false? (kc/emoji-single? "emoji")))

;; --- fallback-single (kernel.bgl:23-26, verbatim order) ---------------------
(check "fallback-single has the 23 transitional preds" (= 23 (count kc/fallback-single)))
(check "fallback-single starts at title" (= "title" (first kc/fallback-single)))
(check "fallback-single ends at clockify_id" (= "clockify_id" (last kc/fallback-single)))
(check "fallback-single order is the kernel literal"
       (= ["title" "owner" "lead" "driver" "source" "part_of"
           "do_on" "valid_until" "estimate_hours" "created_at" "updated_at" "name" "body"
           "created_by" "committed" "outcome" "abandoned" "superseded_by" "merged_into"
           "session_of" "start_time" "end_time" "clockify_id"]
          kc/fallback-single))

;; --- configured-single? -----------------------------------------------------
(check "configured-single? finds a member" (true? (kc/configured-single? ["a" "b"] "b")))
(check "configured-single? misses a non-member" (false? (kc/configured-single? ["a" "b"] "c")))
(check "configured-single? on an empty config" (false? (kc/configured-single? [] "a")))

;; --- meta-single-seed? (fold.bclj:81-83) ------------------------------------
(doseq [p ["cardinality" "value_kind" "name" "acyclic" "predicate_name"]]
  (check (str "meta-single-seed? seeds " p) (true? (kc/meta-single-seed? p))))
;; The prototype divergence this module deliberately drops: `lease` was never in
;; fold.bclj's seed, and seeding it would silently make @lease:<res> single-valued
;; without a declaring fact.
(check "meta-single-seed? does NOT seed lease" (false? (kc/meta-single-seed? "lease")))
(check "meta-single-seed? does not seed a domain pred" (false? (kc/meta-single-seed? "title")))

;; --- single-eff? precedence: fact > configured > fallback -------------------
;; (kernel.bgl:131 single-eff?, kernel.bgl:304 single-eff-reg?)
(check "declaration beats an absent config and absent fallback"
       (true? (kc/single-eff? true true false "wholly_unknown")))
(check "a NEGATIVE declaration beats configured"
       (false? (kc/single-eff? true false true "title")))
(check "a NEGATIVE declaration beats the fallback list"
       (false? (kc/single-eff? true false false "title")))
(check "a negative declaration removes ONLY its own predicate"
       (true? (kc/single-eff? false false false "owner")))
(check "configured beats the fallback list's silence"
       (true? (kc/single-eff? false false true "wholly_unknown")))
(check "fallback answers when nothing is declared or configured"
       (true? (kc/single-eff? false false false "title")))
(check "the emoji_ prefix rule survives into the fallback rung"
       (true? (kc/single-eff? false false false "emoji_blocked")))
(check "an unknown pred with no declaration or config is multi"
       (false? (kc/single-eff? false false false "wholly_unknown")))

;; --- fold key bytes (fold.bclj:122-126) -------------------------------------
;; U+0001 separator: l/p and multi-valued r's are clean refs that never contain it.
(check "key-of-group is l SEP p"
       (= (str "@thing" SEP "title") (kc/key-of-group "@thing" "title")))
(check "key-of-triple is l SEP p SEP r"
       (= (str "@thing" SEP "depends_on" SEP "@other")
          (kc/key-of-triple "@thing" "depends_on" "@other")))
(check "the separator byte is U+0001"
       (= 1 (int (nth (kc/key-of-group "a" "b") 1))))
(check "group and triple keys never collide for the same (l,p)"
       (not= (kc/key-of-group "@a" "p") (kc/key-of-triple "@a" "p" "@r")))
(check "a group key is a strict prefix of its triple key"
       (clojure.string/starts-with? (kc/key-of-triple "@a" "p" "@r")
                                    (kc/key-of-group "@a" "p")))

;; --- normalize-ref-value (server.clj:1875-1882) -----------------------
(check "ref-kind promotes a bare id" (= "@thing" (kc/normalize-ref-value "ref" "thing")))
(check "ref-kind leaves an already-@ value alone" (= "@thing" (kc/normalize-ref-value "ref" "@thing")))
(check "literal-kind never promotes" (= "thing" (kc/normalize-ref-value "literal" "thing")))
(check "an unknown value_kind never promotes" (= "thing" (kc/normalize-ref-value "" "thing")))
(check "ref-kind never promotes a value with whitespace"
       (= "two words" (kc/normalize-ref-value "ref" "two words")))
(check "ref-kind never promotes a blank value" (= "" (kc/normalize-ref-value "ref" "")))
(check "ref-kind never promotes an all-whitespace value"
       (= "   " (kc/normalize-ref-value "ref" "   ")))

;; --- lease codec (database.clj:841-847, server.clj:749-751) --------------
(check "lease-subject is the @lease:<res> entity"
       (= "@lease:corpus" (kc/lease-subject "corpus")))
(check "lease-encode is holder|exp|epoch"
       (= "agent-7|1785419000000|42" (kc/lease-encode "agent-7" 1785419000000 42)))
(let [d (kc/lease-decode (kc/lease-encode "agent-7" 1785419000000 42))]
  (check "lease round-trip holder" (= "agent-7" (:holder d)))
  (check "lease round-trip exp" (= 1785419000000 (:exp d)))
  (check "lease round-trip epoch" (= 42 (:epoch d)))
  (check "lease round-trip is valid" (true? (:valid d))))
(doseq [[label v] [["no separators" "agent-7"]
                   ["only two parts" "agent-7|1785419000000"]
                   ["four parts" "agent-7|1|2|3"]
                   ["trailing empty part" "agent-7|1|"]
                   ["non-numeric exp" "agent-7|soon|42"]
                   ["empty string" ""]]]
  (check (str "lease-decode rejects " label) (false? (:valid (kc/lease-decode v)))))
(check "an empty holder still decodes (database.clj splits to 3 parts)"
       (true? (:valid (kc/lease-decode "|1|2"))))

;; --- lease schema seed lines (server.clj:749-751) ---------------------
(check "exactly two lease schema seed lines" (= 2 (count kc/lease-schema-lines)))
(check "the lease cardinality seed line"
       (= "@lease cardinality single" (first kc/lease-schema-lines)))
(check "the lease value_kind seed line"
       (= "@lease value_kind literal" (second kc/lease-schema-lines)))

;; --- delivery-trigger? (server.clj:2066) ------------------------------
(check "to is a delivery trigger" (true? (kc/delivery-trigger? "to")))
(check "target is a delivery trigger" (true? (kc/delivery-trigger? "target")))
(check "an ordinary pred is not a delivery trigger" (false? (kc/delivery-trigger? "title")))
(check "a near-miss pred is not a delivery trigger" (false? (kc/delivery-trigger? "targets")))

(println "kernel_classify:" (- @total @failures) "/" @total "PASS")
(System/exit (if (zero? @failures) 0 1))

(ns semantic-contract.collections-layout)

(defn keyword-map-count []
  (let [values {:alpha 1 :beagle/beta 2}]
  (count values)))

(defn ^Boolean keyword-map-absent []
  (let [values {:alpha 1}]
  (not (contains? values :missing))))

(defn ^Boolean compound-map-present []
  (let [needle [1 2]
   values {[1 2] "pair"}]
  (contains? values needle)))

(defn set-dedup-count []
  (let [values #{[1 2] [1 2] [2 3]}]
  (count values)))

(defn ^Boolean set-present []
  (let [needle [1 2]
   values #{[1 2] [2 3]}]
  (contains? values needle)))

(defn ^Boolean compound-equal []
  (let [left [[1 2] [3]]
   right [[1 2] [3]]]
  (= left right)))

(defn ^Boolean compound-hash-consistent []
  (let [left [[1 2] [3]]
   right [[1 2] [3]]]
  (= (hash left) (hash right))))

(defn ^Boolean keyword-distinct-from-string []
  (not= :alpha "alpha"))

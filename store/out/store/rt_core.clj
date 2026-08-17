(ns store.rt-core
  (:require [clojure.string :as str]))

(def COMMA-RE (re-pattern ","))

(def SPLIT-KV-RE (re-pattern "^(\\S+)\\s+(.*)$"))

(def SLUG-NONWORD-RE (re-pattern "[^a-z0-9]+"))

(def SLUG-LEADING-RE (re-pattern "^_+"))

(def SLUG-TRAILING-RE (re-pattern "_+$"))

(def DIGITS-ONLY-RE (re-pattern "[^0-9]"))

(def ISO19-RE (re-pattern "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}"))

(def ISO16-RE (re-pattern "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}"))

(defn str-index-of [^String s ^String sub]
  (str/index-of s sub))

(defn split-comma [^String s]
  (vec (remove str/blank? (map str/trim (str/split s COMMA-RE)))))

(defn ^Boolean str-lt? [^String a ^String b]
  (neg? (compare a b)))

(defn split-kv [^String line]
  (let [t (str/trim line)
   m (re-find SPLIT-KV-RE t)]
  (if (some? m) (let [parts [(nth m 1) (nth m 2)]]
  parts) (let [parts [t ""]]
  parts))))

(defn ^String fmt-id [^String n]
  (let [s (str n)]
  (str (subs s 0 4) "-" (subs s 4 6) "-" (subs s 6 8) "-" (subs s 8 14))))

(defn ^String slugify [^String title]
  (let [base (str/replace (str/replace (str/replace (str/lower-case (str title)) SLUG-NONWORD-RE "_") SLUG-LEADING-RE "") SLUG-TRAILING-RE "")
   capped (if (> (count base) 60) (subs base 0 60) base)
   clean (str/replace capped SLUG-TRAILING-RE "")]
  (if (str/blank? clean) "untitled" clean)))

(defn ^String filter-digits [^String s]
  (str/replace s DIGITS-ONLY-RE ""))

(defn ^Boolean is-iso-datetime-19 [^String s]
  (boolean (and (= 19 (count s)) (re-matches ISO19-RE s))))

(defn ^Boolean is-iso-datetime-16 [^String s]
  (boolean (and (= 16 (count s)) (re-matches ISO16-RE s))))

(defn ^String repeat-str [^String s n]
  (apply str (repeat (max 0 (long n)) s)))

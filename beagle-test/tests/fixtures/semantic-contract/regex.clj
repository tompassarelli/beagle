(ns semantic-contract.regex
  (:require [clojure.string :as str]))

(def NO-CAPTURE (re-pattern "c.t"))

(def OPTIONAL-CAPTURE (re-pattern "^(a)?b$"))

(def MULTIPLE-CAPTURES (re-pattern "^([a-z]+)-([0-9]+)$"))

(def ESCAPED-GROUP (re-pattern "^\\(x\\)$"))

(def REPLACE-RUN (re-pattern "[^a-z0-9]+"))

(def SPLIT-RUN (re-pattern "[,;]+"))

(defn find-no-capture [^String s]
  (re-find NO-CAPTURE s))

(defn match-optional-capture [^String s]
  (re-matches OPTIONAL-CAPTURE s))

(defn match-multiple-captures [^String s]
  (re-matches MULTIPLE-CAPTURES s))

(defn match-escaped-group [^String s]
  (re-matches ESCAPED-GROUP s))

(defn ^String replace-runs [^String s]
  (str/replace s REPLACE-RUN "_"))

(defn split-runs [^String s]
  (str/split s SPLIT-RUN))

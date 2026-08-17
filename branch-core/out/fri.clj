(ns fri
  (:require [fri-port :as fp]))

(def ^String MAGIC fp/MAGIC)

(def FMT fp/FMT)

(defn source-binding [^String space-id ^String fingerprint valid-bytes]
  (fp/source-binding space-id fingerprint valid-bytes))

(defn write-fri! [dump ^String path source]
  (fp/write-fri! dump path source))

(defn open-fri! [^String path source]
  (fp/open-fri! path source))

(defn close-fri! [image]
  (fp/close-fri! image))

(defn restore-store! [image target]
  (fp/restore-store! image target))

(defn ^String space-id [image]
  (fp/space-id image))

(defn ^String source-fingerprint [image]
  (fp/source-fingerprint image))

(defn source-position [image]
  (fp/source-position image))

(defn transaction-count [image]
  (fp/transaction-count image))

(defn operation-count [image]
  (fp/operation-count image))

(defn occurrences [image]
  (fp/occurrences image))

(defn withdrawals [image]
  (fp/withdrawals image))

(defn live-occurrences [image]
  (fp/live-occurrences image))

(defn live-propositions [image]
  (fp/live-propositions image))

(defn by-t1 [image term]
  (fp/by-t1 image term))

(defn by-t2 [image term]
  (fp/by-t2 image term))

(defn by-t3 [image term]
  (fp/by-t3 image term))

(defn by-t12 [image t1 t2]
  (fp/by-t12 image t1 t2))

(defn by-t23 [image t2 t3]
  (fp/by-t23 image t2 t3))

(defn by-t13 [image t1 t3]
  (fp/by-t13 image t1 t3))

(defn live-occurrences-as-of [image sequence]
  (fp/live-occurrences-as-of image sequence))

(defn live-propositions-as-of [image sequence]
  (fp/live-propositions-as-of image sequence))

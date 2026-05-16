#lang beagle

(ns shapes)

(defrecord Circle [(radius : Long)])
(defrecord Rect [(width : Long) (height : Long)])

(defn circle-area [(c : Circle)] : Long
  (* (circle-radius c) (circle-radius c)))

(defn rect-area [(r : Rect)] : Long
  (* (rect-width r) (rect-height r)))

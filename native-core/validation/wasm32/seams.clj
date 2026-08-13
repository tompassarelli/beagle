#!/usr/bin/env bb
;; Reads the wasm binary directly: no wasm inspection tool is a dependency here.
;; usage: bb seams.clj MODULE.wasm

(def kind-names ["func" "table" "memory" "global"])

(defn read-bytes [path]
  (java.nio.file.Files/readAllBytes
   (java.nio.file.Path/of path (into-array String []))))

(defn ubyte [^bytes data index]
  (bit-and (int (aget data index)) 0xff))

;; LEB128 unsigned: returns [value next-index].
(defn uleb [^bytes data index]
  (loop [i index value 0 shift 0]
    (let [b (ubyte data i)
          value (bit-or value (bit-shift-left (bit-and b 0x7f) shift))]
      (if (zero? (bit-and b 0x80))
        [value (inc i)]
        (recur (inc i) value (+ shift 7))))))

(defn read-name [^bytes data index]
  (let [[length after] (uleb data index)]
    [(String. data after length "UTF-8") (+ after length)]))

(defn utf8-hex [text]
  (apply str
         (map #(format "%02x" (bit-and (int %) 0xff))
              (.getBytes ^String text "UTF-8"))))

;; A limits field is a flag byte plus one or two LEB128 counts.
(defn skip-limits [^bytes data index]
  (let [flags (ubyte data index)
        [_ after-min] (uleb data (inc index))]
    (if (zero? (bit-and flags 0x01)) after-min (second (uleb data after-min)))))

(defn read-import-desc [^bytes data index]
  (let [kind (ubyte data index)
        after (inc index)]
    [kind (case kind
            0 (second (uleb data after))
            1 (skip-limits data (inc after))
            2 (skip-limits data after)
            3 (+ after 2))]))

(defn section-entries [^bytes data section-id index count-index]
  (let [[n start] (uleb data count-index)]
    (loop [i start remaining n out []]
      (if (zero? remaining)
        out
        (if (= section-id 2)
          (let [[module after-module] (read-name data i)
                [field after-field] (read-name data after-module)
                [kind after-desc] (read-import-desc data after-field)]
            (recur after-desc (dec remaining)
                   (conj out (format "import %s %s %s"
                                     (kind-names kind)
                                     (utf8-hex module)
                                     (utf8-hex field)))))
          (let [[field after-field] (read-name data i)
                kind (ubyte data after-field)
                [_ after-index] (uleb data (inc after-field))]
            (recur after-index (dec remaining)
                   (conj out (format "export %s %s"
                                     (kind-names kind) (utf8-hex field))))))))))

(defn seams [^bytes data]
  (loop [i 8 out []]
    (if (>= i (alength data))
      (sort out)
      (let [section-id (ubyte data i)
            [size after-size] (uleb data (inc i))
            end (+ after-size size)]
        (recur end
               (if (contains? #{2 7} section-id)
                 (into out (section-entries data section-id i after-size))
                 out))))))

(let [[path] *command-line-args*]
  (when (nil? path)
    (binding [*out* *err*] (println "usage: seams.clj MODULE.wasm"))
    (System/exit 2))
  (let [^bytes data (read-bytes path)]
    (when-not (= (seq (take 4 data)) (seq (byte-array [0 0x61 0x73 0x6d])))
      (binding [*out* *err*] (println "seams.clj: not a wasm module:" path))
      (System/exit 1))
    (doseq [line (seams data)]
      (println line))))

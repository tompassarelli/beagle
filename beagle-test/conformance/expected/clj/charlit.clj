(ns conformance.charlit)

^{:line 7 :file "beagle-test/conformance/corpus/charlit.bclj"} (defn named-chars []
  ^{:line 8 :file "beagle-test/conformance/corpus/charlit.bclj"} [\tab \space \newline \return \backspace \formfeed])

^{:line 10 :file "beagle-test/conformance/corpus/charlit.bclj"} (defn plain-chars []
  ^{:line 11 :file "beagle-test/conformance/corpus/charlit.bclj"} [\z \0 \!])

^{:line 13 :file "beagle-test/conformance/corpus/charlit.bclj"} (defn ^Boolean char-in-let []
  ^{:line 14 :file "beagle-test/conformance/corpus/charlit.bclj"} (let [c \a]
  ^{:line 14 :file "beagle-test/conformance/corpus/charlit.bclj"} (char? c)))

^{:line 16 :file "beagle-test/conformance/corpus/charlit.bclj"} (defn ^Boolean char-predicate []
  ^{:line 17 :file "beagle-test/conformance/corpus/charlit.bclj"} (char? \z))

^{:line 19 :file "beagle-test/conformance/corpus/charlit.bclj"} (defn ^String char-unicode-escape []
  ^{:line 20 :file "beagle-test/conformance/corpus/charlit.bclj"} (str \u00e9 \u0007))

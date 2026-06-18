(ns rf)

^{:line 3 :file "/tmp/fsweep/rf.bclj"} (defprotocol Showable
  (show [self]))

^{:line 4 :file "/tmp/fsweep/rf.bclj"} (def r ^{:line 4 :file "/tmp/fsweep/rf.bclj"} (reify Showable ^{:line 4 :file "/tmp/fsweep/rf.bclj"} (show ^{:line 4 :file "/tmp/fsweep/rf.bclj"} [^{:line 4 :file "/tmp/fsweep/rf.bclj"} (self :- String)] self)))

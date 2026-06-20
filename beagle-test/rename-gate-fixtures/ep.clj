(ns ep)

^{:line 3 :file "/tmp/fsweep/ep.bclj"} (defprotocol Showable
  (show [self]))

^{:line 4 :file "/tmp/fsweep/ep.bclj"} (extend-protocol Showable String ^{:line 4 :file "/tmp/fsweep/ep.bclj"} (show ^{:line 4 :file "/tmp/fsweep/ep.bclj"} [^{:line 4 :file "/tmp/fsweep/ep.bclj"} (self :- String)] self))

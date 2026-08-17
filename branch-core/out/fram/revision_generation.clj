(ns fram.revision-generation)

^{:line 7 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defrecord RevisionSet [source program state])

(defn revisionset-source [r] (:source r))

(defn revisionset-program [r] (:program r))

(defn revisionset-state [r] (:state r))

^{:line 9 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defrecord RevisionGeneration [revisions state-bytes])

(defn revisiongeneration-revisions [r] (:revisions r))

(defn revisiongeneration-state-bytes [r] (:state-bytes r))

^{:line 11 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn ^RevisionSet revision-set [^String source ^String program ^String state]
  ^{:line 12 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (->RevisionSet source program state))

^{:line 14 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn ^Boolean revisions-match? [^RevisionSet expected ^RevisionSet actual]
  ^{:line 15 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (and ^{:line 15 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (= ^{:line 15 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-source expected) ^{:line 15 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-source actual)) ^{:line 16 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (= ^{:line 16 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-program expected) ^{:line 16 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-program actual)) ^{:line 17 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (= ^{:line 17 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-state expected) ^{:line 17 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-state actual))))

^{:line 22 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn hydrate-generation [^RevisionSet expected ^RevisionSet actual ^String state-bytes]
  ^{:line 27 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (let [candidate ^{:line 28 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (->RevisionGeneration actual ^{:line 28 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (str state-bytes ""))]
  ^{:line 29 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (if ^{:line 29 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisions-match? expected actual) candidate nil)))

^{:line 33 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn ^String generation-source-revision [^RevisionGeneration generation]
  ^{:line 34 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-source ^{:line 34 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisiongeneration-revisions generation)))

^{:line 36 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn ^String generation-program-revision [^RevisionGeneration generation]
  ^{:line 37 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-program ^{:line 37 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisiongeneration-revisions generation)))

^{:line 39 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn ^String generation-state-revision [^RevisionGeneration generation]
  ^{:line 40 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisionset-state ^{:line 40 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisiongeneration-revisions generation)))

^{:line 42 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn ^String generation-state-bytes [^RevisionGeneration generation]
  ^{:line 43 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisiongeneration-state-bytes generation))

^{:line 45 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (defn generation-byte-count [^RevisionGeneration generation]
  ^{:line 46 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (count ^{:line 46 :file "/home/tom/code/beagle/worktrees/stage3/branch-core/src/fram/revision_generation.bgl"} (revisiongeneration-state-bytes generation)))

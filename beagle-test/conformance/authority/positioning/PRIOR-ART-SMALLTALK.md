+++
id = "beagle-prior-art-smalltalk"
title = "Pharo/Smalltalk image prior-art and failure autopsy"
shape = "resource"
life = "complete"
updated_at = "2026-08-17T16:40:00+08:00"
owners = ["codex:/root"]
depends_on = []
conversation_ids = []
coordination = []
+++

# PRIOR-ART STEAL SHEET: PHARO/SMALLTALK

## License and source boundary

This is original analysis for Beagle. It does not copy source expressions.
The checked Pharo image source is `resources:pharo` at
`4f3de66285c017105f469b32cc5a2de7ac79183c`; its `LICENSE` says MIT with
parts under Apache, plus separately licensed assets. Iceberg was checked at
`pharo-vcs/iceberg` commit `15397097a2b9043dac879ff1b8311343c5b685af`; its
repository license is MIT. The VM-side corroboration was checked at
`pharo-project/pharo-vm` commit `a8d39a4a95d263e15f789bebee3a55a1200c0be9`,
also MIT. Preserve the applicable notices if any code or substantial source
expression is ever reused; this note only uses ideas, behavior, and citations.

## Position

Smalltalk's image was the original store-as-heap thesis: language objects,
classes, processes, tools, and application state all lived in one live object
graph, and the VM could persist that graph. It got the human experience right
in ways file-based languages still mostly cannot: the program stayed alive
while being changed, every object could be inspected in context, and identity
could be rewritten with `become:` rather than simulated by rebuilding every
reference.

It lost as a default collaboration and distribution model because the thing it
made durable was the wrong unit for a shared repository. A binary image is an
excellent continuation checkpoint and a poor merge base, review surface,
reproducible build input, or cross-tool interchange format. Iceberg is the
important repair attempt: it puts Git inside the image and exports packages as
Tonel/Filetree source, but that bridge proves the central lesson rather than
invalidating it. Git can version the source projection; it cannot merge or
reproduce an arbitrary live heap.

Beagle's bet is narrower and more defensible: make the typed-triple store the
durable semantic heap, keep Git-committed source as a first-class external
artifact, and bind both to exact source bytes and revision provenance. Reclaim
the image's liveness and inspectability without making an opaque, ambient image
the authority.

## How the image actually works

### Object memory is a graph, not a serialization of values

The VM represents objects as heap records addressed by object pointers (oops),
with pointer fields leading to more objects. Classes are themselves objects;
the VM's Spur memory manager uses a class table and object headers carrying a
class index, identity hash, format, mark/pin/remember bits, and slot count. The
checked VM design describes a 64-bit header, indirect class references, class
table tracing, segmented old space, young/new space, and a full GC/compaction
model. SmallIntegers are immediate tagged values, not heap objects. The image
source exposes this boundary directly: `ProtoObject >> become:` and
`becomeForward:` are VM primitives, while `SmallInteger` is declared an
`immediate` class.

The consequence is liveness: a class, method dictionary, compiled method,
global association, process, suspended context, UI model, cache, and domain
object can all be reachable in the same graph. There is no mandatory
serialize/deserialize boundary between “the language” and “the application.”
The same identity continues to be referenced by tools, processes, and code.

Garbage collection is part of this model, not an afterthought. Spur scavenges
new space, traces old-space roots, compacts, updates pointers, and removes
forwarders. The VM explicitly runs a full GC before writing an image because
the snapshot cannot contain new space or unresolved forwarding pointers. This
is a real heap with moving-object costs, not a database metaphor.

### Snapshot/resume is a continuation checkpoint

The image-level `snapshotPrimitive` is VM primitive 97. Its contract is to
write the current object memory to an image file and later resume at the exact
state; it returns a boolean distinguishing a fresh image start from resumption.
`SessionManager` runs the snapshot in a high-priority process, stops the active
session, performs shutdown handlers, saves, and starts the next session.

On the VM side, snapshot does more than dump bytes:

1. It converts active machine stack frames into heap `Context` objects because
   the image file stores objects, not native stack frames.
2. It stores the active context in the active process.
3. It flushes new space, full-GCs, prepares heap segments, and writes the image
   header plus non-empty heap segments.
4. The saved image resumes from the primitive boundary with the “image starting”
   result, while the still-running process returns with the other result.

This is why saving feels like a process fork. The running image continues; the
saved image restarts from a captured continuation. The illusion is powerful,
but it is also a precise dependency on the VM, image format, process model,
external resources, and startup protocol.

The session layer acknowledges that boundary. Startup handlers receive a flag
that says whether this is a fresh image or a resumed snapshot. For example,
external objects are cleared on a fresh start, while `Delay` and its scheduler
contain explicit logic so an in-progress delay appears not to have elapsed
across a snapshot. FFI handles, file descriptors, sockets, UI backends, clocks,
and OS resources therefore need policies at resume; they are not magically
portable heap values.

### `become:` is identity surgery

`a become: b` swaps the identities of two non-immediate objects: every pointer
that used to point at `a` points at `b`, and vice versa. `a becomeForward: b`
forwards all references from `a` to `b`, optionally preserving the identity
hash. In ordinary application code this is already more expressive than a
file-based language's usual “replace the value and find all references” story.

Spur implements the forward form lazily. The old object becomes a forwarder
whose first slot points to the target; inline-cache and primitive failure paths
follow the forwarding pointer, and GC later removes forwarders. This keeps a
global heap scan out of the common `become:` operation, but it requires partial
read barriers, JIT cooperation, class-table handling, stack handling, and
careful retry rules. Pharo's own comments call `become:` slow in some
thread-safety-sensitive uses. The feature is a direct consequence of making
identity a VM-level property.

## What the image got right

### Liveness

The unit of work is a living world, not a process that repeatedly reconstructs
itself from files. A debugger can stop a running process, change a method or
object, and continue. Long-lived workspaces, inspectors, caches, and domain
objects retain continuity. This is the part file-based languages never fully
recovered: hot reload usually preserves selected framework state, not the
whole semantic neighborhood of an object and its suspended computations.

### Inspectability

The image makes runtime state the thing the development tools see. An inspector
can navigate object slots, class behavior, process stacks, method dictionaries,
and references without a bespoke export format. A debugger can expose the
interrupted context because it is itself represented as an inspectable object.
That shortens the distance between “what the program is” and “what happened.”

### Identity replacement

`become:` makes migrations, proxies, weak/strong wrapper transitions, class
replacement, and certain live refactorings possible without invalidating every
external reference. It is a first-class answer to the question “what remains
the same when representation changes?” File systems normally answer with a new
path, a new serialized record, or an application-specific ID convention.

The caution is equally important: `become:` is powerful because it rewrites
identity globally and implicitly. A durable store should reclaim the semantic
capability—stable identity with explicit replacement—not the hidden pointer
mutation and its debugging hazards.

## Failure autopsy: why the image lost

This is not a claim that Smalltalk stopped being useful. It is a claim about
why the image did not become the dominant shared artifact of software work.

### 1. VCS incompatibility was structural

Git wants small, named, textual, independently mergeable objects with stable
diffs. An image is a large binary heap snapshot. Two developers changing two
methods or two live objects can produce two images whose bytes differ
throughout the heap because of object allocation, identity hashes, process
state, caches, compaction, timestamps, and unrelated live objects. There is no
general three-way merge for that graph.

The Pharo project therefore exports source in Tonel format: packages are
directories and each class is in its own file. That is a source projection for
VCS, not the image's complete authority. The Pharo repository also keeps the
VM in a separate project, another visible split between image state and the
runtime needed to execute it.

Evidence in the checked source is unusually direct: Pharo's README says the
repository contains image sources, that the VM is separate, and that the
source repository is Tonel. The image snapshot primitive still writes object
memory, not Tonel. The two representations solve different jobs.

### 2. Reproducibility was the opposite of continuation

Resuming an image is intentionally not a clean rebuild. It resumes a captured
process with captured object identity, heap layout history, caches, open
session context, and VM/image-format assumptions. That is perfect for “continue
this world” and poor for “derive the same world from a commit on another
machine.” Fresh startup handlers must recompute architecture-dependent values;
external objects are cleared; timers and FFI resources need special treatment.

An image can be shipped as a pinned runtime artifact, but then the VM, image,
plugins, platform, and external files become part of the opaque closure. A
source checkout plus a declared toolchain is much easier to review, rebuild,
bisect, cache, and run in CI. This is why reproducible-build practice settled
on files and build inputs even when live systems remained better development
environments.

### 3. Tooling was isolated inside the world

The image's best tools—browser, inspector, debugger, refactoring engine—were
inside the image. That made the environment coherent and immediate, but it
isolated the project from the surrounding file/VCS/CI ecosystem. External tools
could see a binary image, not the live object graph's semantic changes. A
reviewer without the matching image and VM could not inspect the real change.

The operational cost is recorded by Iceberg itself. Its README calls the tool
experimental and documents image freezes during clone because progress feedback
was missing, credential/HTTPS problems, platform-specific SSH limitations, and
Windows path-length failures through libgit2. These are not evidence that the
architecture was foolish; they are evidence that putting repository operations
inside a live image inherits every GUI, FFI, credential, path, and blocking-I/O
failure mode of the image.

### 4. The image and source had split-brain authority

Once source export is introduced, a class or method exists in at least two
forms: the live object and the file projection. The image may contain changes
not yet exported; the checkout may change outside the image; loaded packages
may come from different commits. The bridge must detect and reconcile this
state. That is a permanent protocol, not a solved serialization detail.

## Iceberg: the repair attempt and its limit

Iceberg is the honest repair: Git operations are exposed directly from the
image, with a design that leaves room for other VCS backends. Its current
architecture has distinct layers:

- `IceRepository` models HEAD, branches, remotes, commits, and the working copy.
- `IceWorkingCopy` models loaded packages, reference commits, dirty packages,
  diffs, checkout, merge, and commit.
- `IceLibgitRepository` owns the libgit2-backed repository and its external
  checkout. It explicitly wraps libgit calls to translate native errors.
- Tonel and Filetree writers turn image/package snapshots into ordinary files.
  The Git index then stages those files and libgit creates the commit.
- `IceMemoryRepository` provides an in-memory repository for tests and model
  behavior; it is not a persisted image heap.

The commit path makes the boundary unmistakable: validate that HEAD is a
branch and that the image working-copy reference commit equals repository HEAD;
calculate an image diff; write the changed package snapshot to disk; update the
Git index; commit; then advance the image's reference commit. The reader does
the inverse by reading a commit's source tree and importing package snapshots
into the image.

That is a good bridge. It is not a resurrection of image-as-repository:

- the unit of VCS is a package/source tree, not an arbitrary object graph;
- a live process, debugger context, UI session, cache, object identity, or
  external handle is not represented in a Git commit;
- merge is a source/package operation, followed by loading code into an image;
- the image still has a separate HEAD/reference-commit relationship to manage;
- libgit2, filesystem paths, credentials, progress, and platform behavior remain
  seams where the “single world” breaks.

Iceberg repaired the collaboration surface by accepting that files are the
interchange boundary. That is precisely the prior-art result Beagle should
keep: use a live semantic store for liveness, but make the durable boundary
explicit, inspectable, content-addressed, and reproducible from outside the
live process.

## What Beagle must reclaim—and how

### Reclaim liveness as durable semantic state

branch-core already defines recursive `Term := Atom | Triple`, separates
proposition identity from assertion occurrence identity, and keeps physical
handles/rows private. The store-as-heap version of this idea is:

- a branch root and revision are explicit durable roots, not an accidental host
  pointer;
- reopening the store hydrates the same logical terms and live assertion
  occurrences from FRAMLOG/snapshot state;
- reachability, retention, and reclamation are queryable facts and explicit
  operations;
- transient native addresses remain materialization details and never become
  durable identity.

This recovers Smalltalk's continuity without requiring one process, one VM, or
one opaque image to remain alive.

### Reclaim inspectability as a public query surface

An inspector for Beagle should navigate terms, triples, occurrences, branch
revisions, source facts, and provenance using the same model that execution
uses. “What is live?” and “why is this here?” should answer through ordinary
queries over durable state, not through a VM heap debugger. The current
branch-core distinction between semantic terms and private integer handles is
the right constraint: inspect the semantic term and its evidence, never expose
the storage address as identity.

### Reclaim `become:` as explicit identity evolution

Provide the semantic equivalent as an explicit alias/rebind/migration fact:

1. retain the old identity and its historical assertions;
2. assert a replacement or canonical successor identity;
3. make reads at the current branch root follow the explicit relation;
4. make the operation atomic, revisioned, queryable, and reversible by a new
   fact rather than by hidden pointer surgery.

This gives live clients continuity while preserving auditability and mergeability.
It must never silently rewrite old assertion coordinates or erase provenance.

### Make source and runtime state one provenanced generation

The source projection, compiled program, and hydrated durable state need a
single generation identity. Beagle's current revision-generation model already
names source, program, and state revisions and refuses a mismatch before
promoting a candidate generation. Keep that discipline:

- commit exact source bytes and their source hash;
- retain the exact source-to-facts projection and program digest;
- bind the store revision/state digest to that source/program generation;
- reject stale or mixed hydration rather than “helpfully” loading it;
- make the source projection byte-stable where exact provenance promises it.

The result is the image's liveness with files' reproducibility: a running world
can be inspected and evolved, but another machine can reconstruct the same
world from named, hashed inputs.

## Three experiments

### 1. Restartable liveness experiment

Create a branch with a small nested triple graph, two equal propositions with
distinct assertion occurrences, and a named root. Mutate it, inspect it, write
the durable log/snapshot, terminate the process, and hydrate a fresh process.
Verify that the root resolves to the same structural terms, occurrence
multiplicity and coordinates survive, and a query can distinguish live from
withdrawn state. Run one interruption before and one after snapshot publication
to test the recovery boundary.

Success means the durable store—not a process-local pointer graph—is enough to
continue the semantic world. Failure means the “store is the heap” claim is
still only an allocation slogan.

### 2. Explicit `become:` experiment

Create a stable logical identity with references from several triples. Perform a
schema or representation migration by asserting an explicit successor/alias
relation in one revision. Query through the current root and confirm that all
intended reads follow the new identity, while historical assertions, old
coordinates, and provenance remain inspectable. Retract or supersede the alias
and prove the old view can be recovered without rewriting unrelated facts.

Success is Smalltalk-like continuity with database-like history. A hidden
in-place rewrite, ambiguous alias resolution, or lost occurrence history is a
stop-the-line design failure.

### 3. Iceberg-shaped Git/reproducibility experiment

Use two clean clones/branches. In clone A, edit source through the graph/store
path, publish exact source bytes, facts, program digest, and durable state
revision, then commit the source projection. In clone B, fetch the commit and
hydrate only when all three revisions match. Compare the regenerated source,
facts, and compiled program; then make independent edits on both branches and
exercise the normal Git merge path.

Success requires: external Git tools can review the change; source bytes and
provenance are exact; a clean clone reproduces the same program/state; and a
merge conflict is a named source/fact conflict rather than a binary image
conflict. This is the decisive proof that Beagle kept the image virtues without
making the image the repository.

## Evidence ledger

- Pharo license and source format: `resources:pharo/LICENSE`,
  `resources:pharo/README.md`.
- Image snapshot contract: `pharo:src/System-SessionManager/SnapshotOperation.class.st:172-203`,
  `pharo:src/System-SessionManager/SessionManager.class.st:84-90,387-409`.
- Identity rewriting: `pharo:src/Kernel/ProtoObject.class.st:41-66`.
- VM object representation, lazy become, GC, and snapshot preparation:
  `pharo-vm:smalltalksrc/VMMaker/SpurMemoryManager.class.st:258-323,6141-6150,6566-6572`;
  continuation/context handling:
  `pharo-vm:smalltalksrc/VMMaker/StackInterpreter.class.st:14434-14517`.
- Iceberg repository/working-copy model and commit preconditions:
  `iceberg:Iceberg/IceRepository.class.st:1-132,374-382,979-987`;
  `iceberg:Iceberg/IceWorkingCopy.class.st:1-88,232-273`.
- Iceberg's libgit/file bridge: `iceberg:Iceberg-Libgit/IceGitIndex.class.st:119-145`,
  `iceberg:Iceberg-Libgit/IceLibgitRepository.class.st:1-14,539-544,719-728`;
  Tonel export: `iceberg:Iceberg-Libgit-Tonel/IceLibgitTonelWriter.class.st:1-12,98-108`.
- External Iceberg design summary and documented operational seams:
  <https://github.com/pharo-vcs/iceberg#readme>.
- Beagle's store-as-heap and revision-generation context:
  `beagle:docs/ALLOCATION.md:1-40,253-283`,
  `beagle:branch-core/README.md:1-25,174-190`,
  `beagle:branch-core/src/fram/revision_generation.bgl:1-42`.

## Outcome

The prior-art ruling is complete: image liveness, inspectability, and explicit
identity evolution are worth stealing; binary image authority, implicit heap
identity, and image-only tooling are not. The three experiments above are the
next falsifiable gates for Beagle's store-as-heap positioning.

PRIOR-PHARO-DONE

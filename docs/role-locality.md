# Role Locality: A Design Argument for Head-Tagged Syntax and Fenced Data in a Typed Lisp

## Abstract

This paper isolates **one** design bug in conventional Lisp surface syntax and argues for its fix. The bug: **a form's syntactic role is determined by its enclosing context rather than by the form itself.** In Common Lisp the *same container shape* `(...)` is a function call in one position and a non-call form (a `let` binding pair, a lambda list, a `cond` clause) in another, decided by *where it appears*. We call the missing property **role locality**: a form's syntactic role should be readable from the form itself.

To be precise about layers: the Common Lisp *reader* is not the culprit — it reads `(a b)` as a list every time. The context-dependence lives one layer up, at *role interpretation*, where a special form or macro assigns the list a role by position. The defect is not "the reader reads a delimiter two ways"; it is "the same shape is assigned different roles by context."

Role locality is the firm floor, and it is satisfied by many designs, including multi-container ones, *provided each container's role is fixed and local.* A *second*, separate argument — single-axis structural dispatch, favoring metaprogramming and AI-authored transformation — leads the language we describe (working name: Beagle) to a *further* choice: put all syntactic roles in the head-tagged `(...)` container and reserve other containers for inert *data*. We keep these distinct: role locality is the floor; dispatch is the more contestable preference that selects one local design among many.

Conventional Lisp has many other defects (no static types, among them); they are out of scope. The whole design reduces to one law: **syntactic roles are head-tagged; data types may be delimiter-tagged; the two channels never overlap.** We are looking for a critical reading of the argument actually made here.

---

## 1. The bug: context-dependent role assignment

The defining property of Lisp is homoiconicity: code is represented in ordinary data structures, so the operations that manipulate data also manipulate code. This is what makes macros natural.

The bug we isolate concerns neither homoiconicity nor the reader. The Common Lisp reader reads `(a b)` as a list every time; it is uniform. The defect lives one layer up, at **role interpretation** — the same container *shape* is assigned a different *syntactic role* by position:

```lisp
(defun add (a b) (+ a b))      ; (a b) is a lambda list — a parameter-binding form
(+ a b)                        ; (+ a b) is a function call
(let ((x 1) (y 2)) ...)        ; (x 1) is a binding pair, not a call
```

Each is the same shape — a parenthesized list, which the reader produces uniformly — yet each is *interpreted* in a different role. Nothing in `(x 1)` marks it as a binding pair; it is one only because it sits in `let`'s binding position. To know a form's role, you must know where it is.

This is the bug: **role assignment is non-local.** The missing property is **role locality** — you can tell what kind of syntactic form something is by looking at it, without knowing its surroundings. It is foundational because role locality is upstream of nearly every mechanical operation on the surface: a tool that walks code to find, rewrite, or generate forms must otherwise carry the entire context-to-role mapping in its head.

A word on "bug," since it could sound metaphysical: we mean it *relative to a goal* — a metaprogramming-first surface where mechanical tools should identify a form's role locally. A language optimizing for human authoring may reasonably accept context-sensitive subgrammars and pay no price it cares about. We isolate a defect *for this target*; everything downstream is conditional on it.

---

## 2. The principle: role locality

> **A form's syntactic role is determined by the form itself, never by enclosing context. You can tell what kind of syntactic form something is by looking at it.**

This rules out the bug directly. A list may not be a call in one place and a binding pair in another *by virtue of its position*. If a form is a binding, the form must say so.

Crucially, the principle does **not** say "there may be only one container," nor "all roles must be head-tagged." It permits multiple containers, *provided each carries a fixed, local role.* A language could legitimately have:

- `(...)` always a call,
- `[...]` always a binding region with its own internal grammar,
- `{...}` always an associative literal,

and satisfy role locality completely — because in such a design, seeing `[...]` tells you "binding region" *without* knowing the surroundings. The role is local to the delimiter. What violates role locality is a single shape whose role is decided by where it sits.

This reframes the comparison to existing Lisps as a gradient, not a verdict:

- **Common Lisp violates role locality at the universal container.** Its `(...)` is a call, a lambda list, a binding pair, or a clause depending on context. The most-overloaded shape in the language carries no local role at all.
- **Clojure repairs *data-type* stability but still violates role locality.** Clojure's reader is consistent — `[]` always produces a vector, `{}` always a map. But it then lets a *data* container acquire a *syntactic role* by position: a `let` binding "vector" is, as a form, just a vector; its binding role comes from sitting in `let`. The precise way to put it: Clojure's `[x 1 y 2]` has local **data-type identity** (it is unmistakably a vector) but lacks local **syntactic-role identity** (nothing in it marks it as a binding form — only its position in `let` does). A defender who answers "the vector's local role *is* vector; `let` merely interprets its operands" is conceding exactly this: the binding role is supplied by `let`, not by the form. That is the non-locality. So `[x 1 y 2]` standing alone is not self-evidently a binding form. Clojure has stable data-type reading but not role locality.
- **Beagle requires both.** Reader/data-type reading is stable *and* every syntactic role is local: the role is carried in the form (its head), and data containers never acquire roles at all.

So the principle is not "parens good, brackets bad," and it is not "Clojure is deviant." Brackets with a single fixed role are perfectly role-local. The defect both CL and Clojure share — in different places and to different degrees — is letting context, rather than the form, decide a form's role.

---

## 3. A second, separate argument: single-axis structural dispatch

The role-locality principle (§2) is the firm floor. But it is satisfied by *many* designs, including multi-container ones. Something further is needed to choose among them. That something is a distinct argument, and we keep it separate precisely because it is more contestable and should not be smuggled in under the banner of the floor.

The further argument: **for a metaprogramming-first, AI-authored language, prefer collapsing all *syntactic roles* into a single head-tagged container, so that structural dispatch happens on one axis (read the head) rather than several (read the head, or the container type, or both).**

The primary author and manipulator of this language's code is not a human typing application logic. It is a toolchain: compiler passes, macro expansion, type-repair loops, code generation, AI agents performing rewrites. For that consumer, the relevant property is that *every syntactic role is recognized by one uniform operation.*

If all roles live in `(...)` and are distinguished by their head operator, then a code-walker reads every structural form the same way: read the head, walk the tail. There is one structural shape. A migration pass, a blame/repair compiler, a generator, or an agent sees that one shape throughout.

If roles are instead spread across multiple containers — even *consistent* ones (`[...]` always binding, `{...}` always something else) — then a code-walker must dispatch on container type as well as head. That is still consistent by §2, but it is a second dispatch axis.

### 3.1 The real advantage: extensibility without touching the substrate

"Read the head, walk the tail" is not by itself decisive — a multi-container walker is also uniform; it dispatches on container constructor. The non-symmetric advantage is **extensibility of syntactic roles without extending the reader or the substrate:**

> In head-tagging, introducing a new structural role requires only a new head — a value-layer addition (a new operative). In multi-container designs, a genuinely new role eventually requires a new container type — a reader/substrate-layer addition — or an overload of an existing container, which risks the §2 bug.

This matters most for language-oriented programming, where defining new structural forms is routine. In Beagle, a new binding-like form, a new declaration form, a new pattern form is just another operative in head position; the reader never changes, the traversal never changes, the host substrate never changes. The space of syntactic roles stays open at the value layer.

This is why Beagle makes the further choice it does: not because multi-container designs violate consistency (they need not), but because single-axis dispatch keeps roles extensible without ever touching the reader.

---

## 4. Beagle's design: roles in `(...)`, data in its own containers

Combining the floor (§2) and the preference (§3), Beagle adopts:

> **Every form encoding a *syntactic role* is a head-tagged list `(operator operands...)`, whose role is given by its head. Inert *data* values use their own containers (`[...]` vectors, `{...}` maps), each with a fixed data type. No form's role is ever assigned by its context.**

Three kinds of operator occupy head position in the structural container:

1. **A real code operator** — `+`, `if`, `defn`, a constructor. The list is a call.
2. **`'` (the data operator)** — heads an inert *list*: `(' a b c)` is the frozen list `(a b c)`. (See §6 — this is for code-as-data, which is list-shaped.)
3. **`<-` (the binding operator)** — heads a binding list: `(<- x 1 y 2)` binds names to evaluated values, paired flat by position.

Worked examples:

```
(defn add (params a b) (+ a b))           ; params: a declaration form, head-tagged
(let (<- x 1 y 2) (+ x y))                ; binding list, headed by <-
(defrecord Point (fields x y))            ; field declarations, head-tagged
(-> Int Int Int)                          ; function type: flat, last operand is return
(at cfg (' :services :http :port))        ; key path: inert list data
(cond (< n 0) "neg" :else "pos")          ; clauses flat, paired by adjacency
(claim add :type (-> Int Int Int))        ; typing relation as a keyword
(<- xs [1 2 3])                            ; [1 2 3] is a data container, not structure
```

One evaluator rule: look up the head, apply it to the raw operands plus the environment. Identical for `let`, `if`, `+`, `'`, `<-` — everything. The head decides evaluation behavior (these are semantically primitive operatives; see §4.1), but there is **no context-sensitive role table** — a form's role is never assigned by its position. Every syntactic role is entered through an explicit head.

Stated formally:

> A Beagle surface form is an atom, a data container, or a head-tagged list. Every form encoding a *syntactic role* is a head-tagged list; for every such list `L`, `head(L)` alone determines its role, and structural traversal never consults enclosing context to decide what kind of form `L` is. Data containers (`[...]`, `{...}`) have single stable readings, are never syntactic roles, and are not descended into by syntax-role dispatch (data-specific passes may still inspect them as values).

### 4.1 Syntactically ordinary, semantically primitive

`'` and `<-` are **syntactically ordinary**: they occupy head position like any operator and are read by the same rule. They are **semantically primitive**: `<-` introduces names, scopes, and validates pair structure; `'` suppresses evaluation. Unifying the *surface shape* does not flatten the *semantic classes*, and we do not claim it does. The same is true of `if`, `defn`, type arrows.

---

## 5. Data containers and the structure/data boundary

The boundary that makes this design coherent is between **structure** and **data**, and it is what lets Beagle keep brackets without reintroducing the bug.

The role-locality principle (§2) and the dispatch argument (§3) both concern *syntactic roles*. Neither has anything to say about inert data values, because data literals are not syntactic roles and are never traversed as syntactic positions. To *syntax-role dispatch*, a vector literal `[1 2 3]` is a leaf — exactly like `42` or `"foo"` — never a form to descend into to determine a syntactic role. (Data-specific passes — a serializer, a constant-folder, a refactor that rewrites keywords inside a literal map — may of course inspect data literals as values. The claim is only that *structural role* determination never descends into them.)

Therefore data may have its own containers at zero cost to either argument:

- **`(...)` — structure.** Operator-operand, head-tagged, one rule everywhere. Calls, bindings, parameter lists, declarations, patterns.
- **`[...]`, `{...}` — data.** Inert values, each with a single stable reading, never a syntactic role.
- **atoms** — `42`, `"foo"`, `:kw`, symbols. Leaves.

Each container carries a fixed role (§2 satisfied): `(...)` is structure, `[...]`/`{...}` are data, none assigned by context. Structural dispatch reads the head within `(...)` and does not descend into data containers (§3 satisfied). The two never collide because a data container never carries a syntactic role.

The single law that captures the whole design:

> **Syntactic roles are head-tagged. Data types may be delimiter-tagged. The two channels never overlap.**

**Data literals are self-evaluating constants.** Their contents are data, not expression positions: `[a b]` is a vector of the *symbols* `a` and `b`, not their values — exactly as `(' a b)` is a list of those symbols. A data literal never contains an evaluated expression slot, which is precisely what lets structural dispatch treat it as a leaf. Computed compound values are built with headed constructors — `(vector x y)`, `(hash-map :a x)` — which are calls in the structure channel, not literals in the data channel. This seals the tier boundary: if `[x y]` evaluated its contents the way Clojure's vector syntax does, the literal would contain expression positions and could no longer be a leaf. It does not, so it is.

**This settles nested forms.** Inside a data container, contents are read as data all the way down — including parentheses. `[1 2 (+ 1 2)]` denotes a vector containing `1`, `2`, and the inert list `(+ 1 2)` — *not* the result of adding. `{:handler (fn (params x) (+ x 1))}` is a map whose value is the inert list `(fn (params x) (+ x 1))`, not a live function. To compute, leave the data tier and use a headed constructor: `(vector 1 2 (+ 1 2))`, `(hash-map :handler (fn (params x) (+ x 1)))`.

A reader may object that this makes `(...)` mean "structure" at top level but "list data" inside `[...]` — isn't *that* context-dependence, the very thing §1 condemns? No, and the distinction is the crux. Two locality mechanisms are at work, and both are local and universal:

- **Channel** (active vs inert) is declared by the nearest enclosing delimiter — `(...)` is structure/active, `[...]`/`{...}`/`'` are data/inert — and it scopes downward. This is exactly how quote behaves in every Lisp: `(+ 1 2)` is active, `'(+ 1 2)` is inert, and no one calls that a bug, because the `'` is a *locally visible, universal* marker that freezes everything below it. `[...]` is the same kind of marker.
- **Role** within the structural channel is declared by the head.

The §1 bug is neither of these. It is a *third* mechanism: assigning a syntactic role by an **operator's positional grammar** — you must know that `let` treats its first argument as bindings, that `defun` treats its second as a lambda list. That requires knowing each operator's private rules. Channel-by-visible-delimiter and role-by-head both require knowing only fixed, universal conventions, readable from the form's own surface. Role-by-operator-position requires knowing the operator. That is the difference between local and non-local, and it is why a downward-scoping data delimiter is fine while a positional binding grammar is not.

This is why Beagle *keeps* brackets rather than banning them. Restating the gradient from §2 in channel terms: Common Lisp lets its one container `(...)` take a role by context; Clojure keeps data types stable but lets a data container (`[]`) take a syntactic role by position — a data delimiter moonlighting as syntax; Beagle forbids the overlap, so a form's role is always carried in the form (its head) and a data delimiter never does syntax's job. The delimiter tells you, locally, which channel you are in: `(` is structure, `[`/`{` is data, and neither ever does the other's job.

### 5.1 Why data containers cost nothing *to role dispatch*

Forcing inert data through head-tagged construction — `(vector 1 2 3)` for a literal sequence — pays for a head (`vector`) that carries no dispatch information, because a literal performs no dispatch. It also makes a *literal* look like an *operation*: data dressed as a call. The data container `[1 2 3]` deletes the contentless head. Data looks like data; structure looks like structure; each form says what it is.

To be precise about "cost nothing": data containers are not free in every sense. They add a second surface grammar, give literal semantics that differ from Clojure's (contents are inert, §5), and impose data-traversal rules on tooling. What they cost *nothing* is the property this paper is built on — **role dispatch**: because a data literal is a leaf to structural dispatch, adding the data channel does not add a dispatch axis, does not weaken role locality, and does not extend the structural traversal. The compression is free *to the dispatch argument*; it is a small, deliberate cost elsewhere, and we judge it worth paying.

### 5.2 The remaining real cost: flat binding grouping

The honest cost is not in the data tier; it is in flat binding lists. `(<- x 1 y 2)` is clean at small scale, but as real features arrive — destructuring, type annotations, defaults — the operand stream grows a local grammar:

```
(<- x 1
    y 2
    user-id (:id user)
    (seq a b) pair
    (fields name :name age :age) person)
```

(Destructuring *targets* are syntactic roles, so they are head-tagged pattern forms — `(seq a b)` a sequential pattern, `(fields name :name age :age)` a record pattern (head names illustrative). A pattern is **not** inert data: `a` and `b` are names being *introduced*, not symbols being denoted. Using `'` here would overload it — `(' a b)` would mean inert data in one place and a name-introducing pattern in another, which is exactly the context-dependent reading §1 forbids. A pattern that binds and a literal that denotes are different roles and take different heads; neither uses `'`.)

A multi-container design gives the eye a pre-attentively distinct binding zone (`[...]`). Head-tagging pushes that grouping cue out of delimiter shape and into operator-local operand grammar. The honest statement:

> The invariant does not eliminate local grammars; it requires every local grammar to be entered through an explicit head. The compiler gains a uniform shape; the human loses a pre-attentive grouping cue for binding regions.

This is the strongest practical objection and we do not minimize it.

---

## 6. Quote stays a head, because code-as-data is list-shaped

A natural question: if data gets its own containers, why is `'` (quote) a *head* rather than a *container* — why not `⟦...⟧` for frozen code?

Because frozen code is **list-shaped.** A quoted program fragment is structurally identical to live code: a head-tagged list. The only difference between frozen and live code is whether it is evaluated; the *shape* is the same.

Would a quote *container* — `⟦+ 1 2⟧` — be illegal? No, and it is important to be precise here, because the easy answer overclaims. A `⟦...⟧` quote container with one fixed role everywhere would **not** violate role locality (§2): it carries a consistent role, readable locally. So it does not re-create the §1 bug; the floor permits it.

What it violates is the *dispatch preference* (§3). Frozen code is **list-shaped** — a quoted program fragment is structurally a head-tagged list, identical in shape to live code; the only difference is whether it is evaluated. Putting it in its own container creates a *second structural representation for list-shaped code*: now a code-walker must handle both `(...)` code and `⟦...⟧` code, which is exactly the second dispatch axis §3 argues against. So Beagle keeps frozen code in the one structure channel and uses a head operator (`'`) to suspend evaluation: `(' + 1 2)` is still a `(...)` list, walked by the same traversal as everything else; `'` is simply the operator whose job is "do not evaluate my operands."

The general test: **does the thing have the same shape as a call?** If yes (frozen code — a head-tagged list), keep it in `(...)` and suspend evaluation with a head operator, rather than splitting list-shaped code across two structural representations. If no (a vector value — not a head-tagged list), it may have its own container, because there is no second representation of the same shape. Inert *code* is a head (`'`); inert *values* are containers (`[]`, `{}`).

### 6.1 Relationship to Common Lisp's quote

Common Lisp already does this, under a layer of reader machinery. `'x` is a reader abbreviation that expands to `(quote x)` — a head operator named `quote`, in parens, read by the normal rule. So CL's quote *is* the head-operator approach; the apostrophe is a prefix convenience that expands to it.

Beagle's difference is to make `'` a *real head operator* directly — `(' x)` — with no expansion step and no reader special-casing. The mechanism is the same as CL's underlying `(quote ...)`, minus the reader macro.

We optionally permit a prefix convenience `'x` that expands to the canonical `(' x)`. We deliberately do **not** call this "sugar" — it is a syntax convenience, a fixed one-to-one abbreviation, not a separate idiom. Because the expansion is unambiguous and context-independent (`'x` always expands to `(' x)`, everywhere), it does not violate role locality: it is not a form whose role varies by position, but a single prefix that always produces one canonical form. Whether to include it is a minor convenience question, not a structural one; the canonical form is `(' x)` regardless.

---

## 7. Anticipated objections

**"Your consistency complaint doesn't entail head-tagging — a consistent `[...]`-binding container would also fix Lisp."**
Correct, and we concede it openly (§2, §3). Consistency is the floor and is satisfied by many designs, including consistent multi-container ones. Head-tagging is a *further* choice justified by the *separate* dispatch argument (§3), not by consistency. We have separated the two precisely so this objection lands as agreement rather than refutation.

**"This is aesthetic preference dressed as principle."**
The role-locality principle (§2) is a concrete, statable property; Common Lisp and Clojure both depart from it, in different ways. The dispatch preference (§3) names its axis and yields an ordering on that axis. Neither is a bare taste claim; both are conditional on stated targets.

**"You reintroduced brackets — isn't that a retreat?"**
No. The principle was never "no brackets." It was "no form whose role is assigned by context" (§2). Brackets with a single fixed role, used only for data and never for syntax, satisfy role locality fully (§5). Banning them was an over-strong earlier formulation we have corrected.

**"Flat bindings are uglier than a bracketed binding zone."**
Conceded on the human-reading axis (§5.2). The flatness is the cost; uniform head-dispatch is the purchase. We judge the purchase worth more for this language's goals.

**"Models are better at brackets because the corpus is full of them."**
Possibly decisive — see §8. We do not claim head-tagging helps AI generation in general; we predict it helps on transformation-heavy tasks and commit to testing it.

---

## 8. What would change our minds

This is falsifiable.

1. **A controlled generation study.** One language core, two reader/printer skins (all-roles-head-tagged vs roles-spread-across-consistent-containers) parsing to an *identical* AST, so surface form is the only variable. Metric: tokens and repair cycles to a correct (type-checking, test-passing) program. Control for corpus bias by equalizing in-context examples and measuring accuracy-vs-number-of-examples (learnability slope), not raw pretrained recall. Weight tasks toward metaprogramming, where the theory predicts the delta.
   **Committed prediction:** near-tie or slight container advantage on simple tasks (corpus familiarity); head-tag advantage on transformation-heavy tasks that widens with complexity; head-tag reaches target accuracy with fewer in-context examples. **If containers win on transformation tasks, or head-tags need more examples, the dispatch claim is false.**

2. **Evidence that the manipulation/extensibility advantage is illusory** — that container dispatch is fully absorbed by tooling at zero cost, and new roles can be added to a multi-container design without reader/substrate changes — would empty §3.

3. **Evidence that program size does not grow with reduced composability** would weaken the practical case in §5.2.

---

## 9. Conclusion

The bug this paper isolates is narrow and concrete: **a form's syntactic role is assigned by its enclosing context rather than carried by the form itself.** This is not a reader defect — the reader is uniform; it is a *role-interpretation* defect. Common Lisp commits it at its universal container (`(...)` is call, lambda list, binding pair, or clause by position); Clojure keeps data-type reading stable but still commits it (a data container `[]` acquires a binding role by sitting in `let`). The fix is one principle — **role locality**: a form's role is determined by the form, never by its context — and it is the firm floor.

That floor is satisfied by many designs, including multi-container ones. A *separate* argument — single-axis structural dispatch, and the extensibility of syntactic roles without touching the reader or substrate — is what leads Beagle to a *further* choice: put every syntactic role in the head-tagged `(...)` container, and give inert data its own containers (`[...]`, `{...}`), each with a fixed data type. Data containers cost the dispatch property nothing, because data is a leaf to structural dispatch. Quote stays a head because frozen code is list-shaped: a quote *container* would satisfy role locality, but it would create a second structural representation for list-shaped code, weakening single-axis dispatch — so freezing is done by a head operator instead.

We do not claim conventional Lisp is less homoiconic, nor that brackets are wrong. We claim something narrower and harder to dismiss: a form's syntactic role should be local to the form (always), and — for a transformation-first, AI-authored language specifically — syntactic roles are best collapsed into one head-dispatched container while data keeps its own. The first claim is a floor we hold firmly; the second is a preference we justify separately and submit to measurement.

We are looking to be argued with. The soft spots are the flat-binding ergonomics (§5.2) and the unproven dispatch/AI predictions (§3, §8). That is where we expect to be wrong, and where we most want a critical reading.

# beagle/experiments

Empirical benchmarks for design decisions. The point is to replace argument
("`:` is mathematically more correct") with measurement ("LLMs produce
compilable code 92% of the time with variant A vs 78% with variant B").

## Why this exists

Beagle's primary author is increasingly an LLM. So design choices should be
measured against LLM behavior, not human aesthetic preference. The two
diverge in non-obvious places.

Specifically we want to measure, per syntactic variant:

- **Compile rate** — does the LLM's first try compile / type-check?
- **Token efficiency** — fewer tokens to produce the same correct answer means
  the LLM has a stronger prior for this idiom
- **Self-consistency** — same task across multiple runs; lower variance means
  less "candidate anxiety"
- **Time-to-correct** — when first try fails, how many rounds of error
  feedback before correct? (Good error messages compound here.)

## Workflow

The framework is **manual-mode** by default — agnostic to which LLM you use.

1. **Generate prompts:**
   ```
   experiments/bin/gen-prompts
   ```
   Writes one file per `(task, variant)` pair to `experiments/prompts/`.

2. **Run the prompts through your LLM.** For each prompt, save the model's
   beagle source to `experiments/responses/<task>-<variant>.rkt`.

   Recommended: run the same prompt **N** times (say, 5) and save each as
   `<task>-<variant>-run-<N>.rkt` to measure self-consistency.

3. **Score:**
   ```
   experiments/bin/score
   ```
   For each response, attempts compilation, records success / failure /
   token count. Writes `experiments/scoreboard.md`.

## Structure

```
experiments/
  README.md           this file
  tasks/              one .md per task — task description + expected behavior
    01-greet.md
    02-classify.md
    ...
  variants/           per-variant prompt scaffolding
    a-current/        baseline: current beagle (`:`, wrapped, optional types)
      spec.md         the language guide presented to the LLM for this variant
    b-required/       variant: types required on def/defn
      spec.md
    c-minimal/        variant: no type annotations at all
      spec.md
  bin/
    gen-prompts       generates experiments/prompts/<task>-<variant>.md
    score             compiles experiments/responses/*.rkt, writes scoreboard
  prompts/            generated; gitignored
  responses/          paste LLM responses here; gitignored
  scoreboard.md       generated
```

## Adding a task

A task is a `.md` file in `tasks/`. Required sections:

```markdown
# <id>-<name>

## Task

Plain-English description of what beagle code to write.

## Expected behavior

Test predicate / sample inputs that should produce known outputs.
```

The task description is concatenated with the variant's `spec.md` to form
the prompt. Keep tasks small (one function, one concept).

## Adding a variant

A variant is a directory under `variants/`. Required: `spec.md` containing
the full beagle reference under that variant's conventions. The LLM is shown
this spec, so make it complete enough that a fresh LLM (no prior knowledge
of beagle) could write valid code from it.

## Caveats

- **Single-model bias.** Optimizes for the model you actually use.
- **Prompt-engineering sensitivity.** Different spec phrasings flip results.
  When testing a variant, change *only* the syntax under test; hold prompt
  framing constant.
- **Sample size.** N≥30 tasks and M≥5 runs per task for differences to be
  meaningful vs noise.

## Current open questions

Things worth measuring as of 2026-05-15:

1. `:` vs `:-` for type annotation — predicted: `:` wins on familiarity
2. Wrapped `(x : T)` vs inline `[x : T y : T]` params — predicted: wrapped
   wins on consistency (less ambiguous parsing for the LLM)
3. Optional vs required types — predicted: required wins for AI generation
   (more compile-time safety net) but might lose on first-try token count
4. With vs without stdlib extern catalog — predicted: catalog wins big

Note: testing (1) and (2) requires beagle to support both syntaxes. As of
v0, only `:` and wrapped are supported, so those experiments are blocked
until the alternate syntax is implemented.

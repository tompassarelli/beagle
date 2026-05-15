# Bug Fix Task

## Context

You have a Project Tracker program that has 5 bugs in it. The program
used to work correctly — all tests passed — but someone introduced bugs
during a code change.

Your job: find and fix all 5 bugs so that the verify script passes.

## Rules

- There are exactly 5 bugs. Don't change anything else.
- The verify script is correct — do NOT modify it.
- Each bug is in a single function. No bug spans multiple functions.
- Bug types you may encounter: wrong arity (function called with wrong
  number of arguments), typos in function names, wrong field indices,
  wrong sort direction.

## How to verify

For beagle (.rkt): compile with `racket <file>`, then run the verify
script against the compiled output.

For Clojure (.clj): run the verify script directly against the code.

The verify script uses the standard head-to-head framework:
`experiments/head-to-head/bin/verify-all` — or you can run verification
manually.

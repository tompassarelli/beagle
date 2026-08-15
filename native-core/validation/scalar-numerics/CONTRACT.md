# Native scalar numerics v0

`corpus.tsv` is the executable `native-scalar-v0` contract. Each backend uses
the operations exported by `fixture.bgl`, accepts I64 values as signed decimal
and F64 values as sixteen lowercase binary64 hex digits, and reports results in
the representation selected by the row's guarantee column.

The exact guarantees are:

- `i64-exact`: the signed 64-bit result is exact.
- `f64-bits-exact`: the sixteen output bits are exact. This covers signed zero,
  raw `float-from-bits`, canonical `float-to-bits` NaNs, exact division edges,
  and order-sensitive expressions. A materializer must not reassociate or
  contract the frozen Native instructions.
- `bool-exact`: the comparison result is exactly `0` or `1`. F64 comparisons
  are IEEE ordered comparisons: either NaN operand makes `=`, `<`, and `<=`
  false; positive and negative zero compare equal.
- `trap-exact`: execution terminates through `native_trap` with abort status
  `134` and byte-exact reporter output `trap<TAB>CODE<LF>`, where `CODE` is the
  value in `expected`. Code 1 is invalid argument; code 2 is overflow; code 4
  is out of range (`long` truncation of NaN or a Float outside int64,
  deliberately fail-closed where the JVM cast mints a sentinel).

`f64-tolerance` is deliberately narrower. It checks a finite derived kernel by
`abs(actual - expected) <= abs-tol + rel-tol * abs(expected)`. It does not
weaken any `f64-bits-exact` row or turn NaN, infinity, signed zero, codecs,
comparisons, traps, or instruction ordering into approximate claims.

The F64 rows assume binary64 round-to-nearest, ties-to-even. The contract says
nothing about host decimal parsing, transcendental libraries, alternative
rounding modes, or fast-math compilation. Those are not scalar Native
operations in this corpus.

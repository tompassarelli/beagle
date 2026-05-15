# 36-mapv-inc

## Task

Define a vector `nums` containing `[10 20 30]`. Then define `incremented`
as the result of calling `mapv` with `inc` on `nums`. Annotate `incremented`
with type `(Vec Long)`.

The compiler should accept this because `mapv` is polymorphic and infers
that `inc : [Long -> Long]` applied to a vector returns `(Vec Long)`.

## Expected behavior

`incremented` evaluates to `[11 21 31]`.

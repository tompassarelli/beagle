# 13-extern-upper

## Task

Declare an extern for Clojure's `clojure.string/upper-case` function (it takes
a String, returns a String).

Then write a beagle function `loud-greet` that takes a String name, uppercases
it, and returns `"HELLO, NAME!"` (with the uppercased name).

Don't forget to `require` the `clojure.string` namespace.

## Expected behavior

`(loud-greet "world")` → `"HELLO, WORLD!"`

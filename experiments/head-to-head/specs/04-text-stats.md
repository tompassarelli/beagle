# Program 4: Text Statistics

Given a string of text, compute statistics about it.

Write:

1. `count-words` — split text by spaces, return the count of non-empty segments
2. `count-chars` — return the length of the string (using `count`)
3. `longest-word` — return the longest word (first wins on tie), or nil if text is empty
4. `word-lengths` — return a vector of [word length] pairs for each word
5. `text-summary` — takes a string, returns a vector:
   [word-count char-count longest-word-or-""]

Use `clojure.string/split` for splitting (declare it as extern with
appropriate type). Use `clojure.string/blank?` to check for empty text.

Define `demo-result` as `(text-summary "the quick brown fox jumps over the lazy dog")`.

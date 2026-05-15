# Program 6: Library Catalog System (~500 lines)

Build a library catalog management system with books, patrons, and checkouts.

## Data Model

**Book**: vector `[id title author year genre copies]`
- id: Long, title: String, author: String, year: Long (negative for BCE), genre: String, copies: Long

**Patron**: vector `[id name membership-type]`
- id: Long, name: String, membership-type: String ("standard" or "premium")

**Checkout**: vector `[patron-id book-id date-string]`
- patron-id: Long, book-id: Long, date-string: String

## Functions to Implement

### Parsing

Use `clojure.string/split` with `#"\|"` for pipe-delimited fields.
Use `clojure.string/trim` on input text. Use `parse-long` to convert
numeric strings to Longs.

1. `parse-book [s]` — split string `"id|title|author|year|genre|copies"` by `"|"`, return book vector with id/year/copies as Longs
2. `parse-books [text]` — trim text, split by `#"\n"`, filter non-empty lines, parse each as a book, return vector of books
3. `parse-patron [s]` — split `"id|name|type"`, return patron vector with id as Long
4. `parse-patrons [text]` — same pattern as parse-books
5. `parse-checkout [s]` — split `"patron-id|book-id|date"`, return checkout vector with ids as Longs
6. `parse-checkouts [text]` — same pattern

### Lookups

7. `find-book [books id]` — return the first book with matching id, or nil
8. `find-patron [patrons id]` — return the first patron with matching id, or nil

### Filtering

9. `books-by-genre [books genre]` — filter books where genre matches (exact)
10. `books-by-author [books author]` — filter books where author matches (exact)
11. `available-books [books]` — filter books with copies > 0
12. `search-books [books query]` — filter books whose title contains query (case-insensitive). Use `clojure.string/lower-case` and `clojure.string/includes?`.
13. `books-before-year [books year]` — filter books published before the given year

### Book Operations

14. `book-copies [book]` — return the copies field (index 5)
15. `total-available [books]` — sum of copies across all books
16. `update-book-copies [book new-copies]` — return a new book vector with copies replaced. Use `assoc` on the vector at index 5.

### Checkout Operations

17. `checkout-book [books checkout]` — extract book-id from checkout (index 1). Find the book. If not found, return `[books "book not found"]`. If copies = 0, return `[books "no copies available"]`. Otherwise, update that book's copies (decrement by 1) in the books vector, return `[updated-books nil]`. To update a book in the vector: map over books, replacing the one with matching id.

18. `return-book [books book-id]` — find book by id. If found, increment copies by 1 (same map-and-replace strategy). If not found, return books unchanged.

19. `process-checkouts [books checkouts]` — fold over checkouts, applying each with checkout-book. Accumulate the updated books and collect any non-nil error strings. Return `[final-books errors-vector]`.

### Patron Operations

20. `checkout-limit [patron]` — return 3 for "standard", 5 for "premium"
21. `patron-checkout-count [patron-id checkouts]` — count checkouts where patron-id matches
22. `patron-at-limit? [patron checkouts]` — true if patron-checkout-count >= checkout-limit

### Statistics

23. `count-by-genre [books]` — return a vector of `[genre count]` pairs, sorted alphabetically by genre. Group books by genre, count each group.
24. `genre-inventory [books]` — return a vector of `[genre total-copies]` pairs, sorted alphabetically. Sum copies per genre.
25. `most-popular-genre [books]` — the genre with the most book titles. On tie, first alphabetically.
26. `avg-copies-per-book [books]` — total copies / count of books (integer division with `quot`). Return 0 if empty.

### Sorting

27. `sort-by-title [books]` — sort books alphabetically by title (index 1)
28. `sort-by-year [books]` — sort books by year ascending (index 3)
29. `sort-by-copies [books]` — sort books by copies descending (index 5), most first

### Formatting

30. `format-book-short [book]` — `"Title (Author, Year)"`
31. `format-book-detail [book]` — `"Title (Author, Year) [Genre] - N copies available"`
32. `format-genre-stats [pair]` — takes `[genre count]`, returns `"Genre: N books"`
33. `format-patron [patron]` — `"Name (Type, limit: N)"` where N is checkout-limit

### Reports

34. `catalog-report [books]` — return a vector of strings:
    - Line 1: `"=== Library Catalog: N books, M total copies ==="`
    - Lines 2-11: `format-book-detail` for each book sorted by title
    - Line 12: `""` (blank)
    - Line 13: `"--- Genre Summary ---"`
    - Lines 14+: `format-genre-stats` for each genre sorted alphabetically

35. `availability-report [books]` — return a vector of strings:
    - `"=== Availability Report ==="`
    - `"Total books: N"`
    - `"Available titles: M"` (count with copies > 0)
    - `"Total copies: K"`
    - `"Average copies per title: A"`

## Notes

- All "sort" and "group" operations should return vectors (use `sort`, `group-by`, `mapv`, etc.)
- Use `clojure.string` functions for string operations
- `parse-long` is a built-in Clojure 1.11+ function for string→Long conversion
- Integer division uses `quot`
- For case-insensitive search: lowercase both the title and query before checking with `includes?`

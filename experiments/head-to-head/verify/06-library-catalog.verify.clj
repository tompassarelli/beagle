(def book-text (str "1|The Great Gatsby|Fitzgerald|1925|Fiction|3\n"
                    "2|A Brief History of Time|Hawking|1988|Science|2\n"
                    "3|The Art of War|Sun Tzu|-500|Strategy|1\n"
                    "4|Dune|Herbert|1965|Fiction|0\n"
                    "5|The Origin of Species|Darwin|1859|Science|4\n"
                    "6|1984|Orwell|1949|Fiction|5\n"
                    "7|Cosmos|Sagan|1980|Science|2\n"
                    "8|The Republic|Plato|-380|Philosophy|1\n"
                    "9|Neuromancer|Gibson|1984|Fiction|3\n"
                    "10|The Selfish Gene|Dawkins|1976|Science|1"))

(def patron-text (str "1|Alice|premium\n"
                      "2|Bob|standard\n"
                      "3|Carol|standard"))

(def checkout-text (str "1|1|2024-01-15\n"
                        "2|2|2024-02-01\n"
                        "1|6|2024-01-20"))

(def books (r/parse-books book-text))
(def patrons (r/parse-patrons patron-text))
(def checkouts (r/parse-checkouts checkout-text))

;; --- parsing ---
(when-not (= (count books) 10) (System/exit 1))
(when-not (= (nth (first books) 0) 1) (System/exit 1))
(when-not (= (nth (first books) 1) "The Great Gatsby") (System/exit 1))
(when-not (= (nth (first books) 3) 1925) (System/exit 1))
(when-not (= (nth (first books) 5) 3) (System/exit 1))
(when-not (= (count patrons) 3) (System/exit 1))
(when-not (= (nth (first patrons) 0) 1) (System/exit 1))
(when-not (= (count checkouts) 3) (System/exit 1))

;; --- lookups ---
(when-not (= (nth (r/find-book books 1) 1) "The Great Gatsby") (System/exit 1))
(when-not (nil? (r/find-book books 99)) (System/exit 1))
(when-not (= (nth (r/find-patron patrons 1) 1) "Alice") (System/exit 1))
(when-not (nil? (r/find-patron patrons 99)) (System/exit 1))

;; --- filtering ---
(when-not (= (count (r/books-by-genre books "Fiction")) 4) (System/exit 1))
(when-not (= (count (r/books-by-genre books "Science")) 4) (System/exit 1))
(when-not (= (count (r/books-by-genre books "Philosophy")) 1) (System/exit 1))
(when-not (= (count (r/available-books books)) 9) (System/exit 1))
(when-not (= (count (r/search-books books "the")) 5) (System/exit 1))
(when-not (= (count (r/search-books books "xyz")) 0) (System/exit 1))
(when-not (= (count (r/books-before-year books 0)) 2) (System/exit 1))
(when-not (= (count (r/books-before-year books 1960)) 5) (System/exit 1))
(when-not (= (count (r/books-by-author books "Orwell")) 1) (System/exit 1))

;; --- book ops ---
(when-not (= (r/book-copies (first books)) 3) (System/exit 1))
(when-not (= (r/total-available books) 22) (System/exit 1))
(let [updated (r/update-book-copies (first books) 10)]
  (when-not (= (nth updated 5) 10) (System/exit 1))
  (when-not (= (nth updated 1) "The Great Gatsby") (System/exit 1)))

;; --- checkout ops ---
(let [result (r/checkout-book books (first checkouts))]
  (when-not (nil? (nth result 1)) (System/exit 1))
  (when-not (= (r/total-available (nth result 0)) 21) (System/exit 1)))
(let [result (r/checkout-book books [1 4 "2024-01-01"])]
  (when-not (string? (nth result 1)) (System/exit 1)))
(let [result (r/checkout-book books [1 99 "2024-01-01"])]
  (when-not (string? (nth result 1)) (System/exit 1)))
(let [result (r/process-checkouts books checkouts)]
  (when-not (= (count (nth result 1)) 0) (System/exit 1))
  (when-not (= (r/total-available (nth result 0)) 19) (System/exit 1)))
(let [returned (r/return-book books 1)]
  (when-not (= (r/total-available returned) 23) (System/exit 1)))
(when-not (= (r/total-available (r/return-book books 99)) 22) (System/exit 1))

;; --- patron ops ---
(when-not (= (r/checkout-limit (first patrons)) 5) (System/exit 1))
(when-not (= (r/checkout-limit (nth patrons 1)) 3) (System/exit 1))
(when-not (= (r/patron-checkout-count 1 checkouts) 2) (System/exit 1))
(when-not (= (r/patron-checkout-count 2 checkouts) 1) (System/exit 1))
(when-not (= (r/patron-checkout-count 3 checkouts) 0) (System/exit 1))
(when (r/patron-at-limit? (first patrons) checkouts) (System/exit 1))

;; --- statistics ---
(let [cbg (r/count-by-genre books)]
  (when-not (= (count cbg) 4) (System/exit 1))
  (when-not (= (nth (nth cbg 0) 0) "Fiction") (System/exit 1))
  (when-not (= (nth (nth cbg 0) 1) 4) (System/exit 1))
  (when-not (= (nth (nth cbg 1) 0) "Philosophy") (System/exit 1)))
(let [gi (r/genre-inventory books)]
  (when-not (= (nth (nth gi 0) 1) 11) (System/exit 1))
  (when-not (= (nth (nth gi 2) 1) 9) (System/exit 1)))
(when-not (= (r/most-popular-genre books) "Fiction") (System/exit 1))
(when-not (= (r/avg-copies-per-book books) 2) (System/exit 1))

;; --- sorting ---
(let [bt (r/sort-by-title books)]
  (when-not (= (nth (first bt) 1) "1984") (System/exit 1))
  (when-not (= (nth (last bt) 1) "The Selfish Gene") (System/exit 1)))
(let [by (r/sort-by-year books)]
  (when-not (= (nth (first by) 1) "The Art of War") (System/exit 1))
  (when-not (= (nth (last by) 1) "A Brief History of Time") (System/exit 1)))
(let [bc (r/sort-by-copies books)]
  (when-not (= (nth (first bc) 1) "1984") (System/exit 1))
  (when-not (= (nth (last bc) 1) "Dune") (System/exit 1)))

;; --- formatting ---
(when-not (= (r/format-book-short (first books))
             "The Great Gatsby (Fitzgerald, 1925)") (System/exit 1))
(when-not (= (r/format-book-detail (first books))
             "The Great Gatsby (Fitzgerald, 1925) [Fiction] - 3 copies available") (System/exit 1))
(when-not (= (r/format-patron (first patrons))
             "Alice (premium, limit: 5)") (System/exit 1))

;; --- reports ---
(let [cr (r/catalog-report books)]
  (when-not (= (first cr) "=== Library Catalog: 10 books, 22 total copies ===") (System/exit 1))
  (when-not (= (count cr) 17) (System/exit 1))
  (when-not (= (nth cr 12) "--- Genre Summary ---") (System/exit 1)))
(let [ar (r/availability-report books)]
  (when-not (= (first ar) "=== Availability Report ===") (System/exit 1))
  (when-not (= (count ar) 5) (System/exit 1))
  (when-not (= (nth ar 2) "Available titles: 9") (System/exit 1)))

(System/exit 0)

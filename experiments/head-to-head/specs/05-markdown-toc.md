# Program 5: Markdown TOC Generator

Given a vector of strings (lines from a markdown file), generate a table
of contents.

Write:

1. `header?` — takes a string, returns true if it starts with "#"
2. `header-level` — takes a header line, returns 1/2/3 based on leading # count (cap at 3)
3. `header-text` — takes a header line, returns the text after the # marks (trimmed)
4. `extract-headers` — takes lines, returns a vector of [level text] pairs for header lines only
5. `render-toc-line` — takes [level text], returns an indented string:
   level 1 → "- TEXT", level 2 → "  - TEXT", level 3 → "    - TEXT"
6. `generate-toc` — takes lines, extracts headers, renders each, returns vector of rendered strings

Define:
```
(def sample-doc ["# Introduction"
                 "Some text here."
                 "## Background"
                 "More text."
                 "## Methods"
                 "### Data Collection"
                 "Details."
                 "# Conclusion"])
```

Define `demo-result` as `(generate-toc sample-doc)`.

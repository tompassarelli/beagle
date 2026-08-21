# Qualified-name lowering — campaign wave plan (EXEC-61)
Dependency truth: W1 (spine) -> W2 (parallel x7) -> W3 (self-host) -> W4 (branch-core + scaffold burn-down).
All W2 lanes branch FROM the seam-1 lane tip (not main). Integration lane merges W2, runs the 90s gate, lands. W3 mirrors on the landed tree. W4 finishes: deletes the render-back scaffold accessor; a landing with the accessor still called anywhere FAILS (grep-guard).

## W2 seams (dispatch in parallel on SEAM1-DONE; each: commit-only, own files only, gate = targeted tests + accessor-callsite count reduced)
- W2a checker: types.rkt regexp-over-string sites (125-132, 439-454, 363-367) + parse.rkt type slicing (1120-1131, 1146-1149, 1201-1206) consume the node.
- W2b emit-js + emit-jst: all slash re-parse sites per audit inventory; join to text only at output.
- W2c emit-clj: slash-atom construction (343-345) + import qualification branches (930-940, 360-371).
- W2d emit-nix: mangle-qualified-name (60-73) + call paths (1050-1062, 1908-1915) consume structure.
- W2e facts: ast-json.rkt ref name (421-437) becomes structured qualifier/name; source-facts.clj ref/callee facts (467-492, 275-278) become structural — coordinate the fact schema with W4's store reader.
- W2f stdlib catalogs: re-key all five catalogs (clj/js/nix/portable/core) on structured identity; consumers via the node.
- W2g checked-AST JSON consumers: anything reading {"node":"ref"} downstream (self-host reads it — inventory consumers, convert non-self-host ones).

## W3 self-host mirror (one Sol xhigh serial): reader.bclj (245-260), ast.bclj (87-94,132-133), parse.bclj (2873-2903 + test 3609-3613), checker+emitters — mirror W1+W2 exactly; selfhost-remint fixpoint green.

## W4 branch-core + burn-down (one Sol xhigh): resolve_mint.bclj (123-147) mints structural facts only; resolve_corpus.bclj (90-124) stops splitting; resolve_render.bclj (55-67) joins from structure; DELETE the compound v dual representation; DELETE the W1 scaffold accessor; add the grep-guard proving zero callsites; full gate + store tests green.

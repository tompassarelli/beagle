import assert from "node:assert/strict";

import {
  assoc_value,
  assoc_in,
  conj_value,
  dissoc_value,
  disj,
  eager_seq,
  empty_p,
  equivV,
  first,
  get,
  get_in,
  into_value,
  keyword,
  list,
  list_p,
  map_value,
  next,
  rest,
  seq,
  seq_p,
  set_value,
  symbol,
  update_in,
} from "../../../beagle-lib/lib/beagle/core.js";
import {
  asHamtMap,
  hamtMap,
  hamtMapGet,
  hamtSet,
} from "../../../beagle-lib/lib/beagle/hamt.js";

const keywordKey = keyword("same");
const stringKey = "same";
const symbolKey = symbol("same");
const scalars = map_value(keywordKey, false, stringKey, 0, symbolKey, "");
assert.equal(get(scalars, keywordKey), false);
assert.equal(get(scalars, stringKey), 0);
assert.equal(get(scalars, symbolKey), "");
assert.equal(Object.keys(scalars).length, 3);

const promotedScalars = asHamtMap(scalars);
assert.equal(hamtMapGet(promotedScalars, keywordKey), false);
assert.equal(hamtMapGet(promotedScalars, stringKey), 0);
assert.equal(hamtMapGet(promotedScalars, symbolKey), "");

const compoundKey = ["compound"];
const associatedPersistent = assoc_value(promotedScalars, compoundKey, 7);
assert.equal(get(associatedPersistent, compoundKey), 7);
assert.equal(get(promotedScalars, compoundKey), null);

const conjoinedPersistent = conj_value(associatedPersistent, [["second"], 8]);
assert.equal(get(conjoinedPersistent, ["second"]), 8);
const accumulatedPersistent = into_value(hamtMap(), [[["third"], 9], [["fourth"], 10]]);
assert.equal(get(accumulatedPersistent, ["third"]), 9);
assert.equal(get(accumulatedPersistent, ["fourth"]), 10);

const dissociatedPersistent = dissoc_value(conjoinedPersistent, compoundKey, ["second"]);
assert.equal(get(dissociatedPersistent, compoundKey), null);
assert.equal(get(dissociatedPersistent, ["second"]), null);
assert.equal(get(conjoinedPersistent, compoundKey), 7);

const persistentSet = hamtSet([[1], [1]]);
const conjoinedSet = conj_value(persistentSet, [2], [2]);
assert.equal(conjoinedSet.count, 2);

const outer = keyword("outer");
const leaf = keyword("leaf");
const nested = assoc_in(map_value(), [outer, leaf], false);
assert.equal(get_in(nested, [outer, leaf]), false);
assert.throws(
  () => assoc_in(map_value(outer, false), [outer, leaf], true),
  /assoc expects a map or vector/,
);

const hamtNested = {
  _bg: "hamtMap",
  count: 1,
  root: {t: "e", k: outer, v: map_value(leaf, 0)},
};
assert.equal(get_in(hamtNested, [outer, leaf]), 0);

const associatedNestedHamt = assoc_in(hamtMap(), [outer, leaf], false);
assert.equal(get_in(associatedNestedHamt, [outer, leaf]), false);
const updatedNestedHamt = update_in(associatedNestedHamt, [outer, leaf], x => Number(x) + 1);
assert.equal(get_in(updatedNestedHamt, [outer, leaf]), 1);

const equalLeft = [1, 2];
const equalRight = [1, 2];
const values = set_value([equalLeft, equalRight, [3, 4]]);
assert.equal(values.size, 2);
assert.equal(disj(values, equalRight).size, 1);
assert.ok(equivV(set_value([[3, 4]]), disj(values, equalRight)));

const xs = list(1, 2);
const prefixed = conj_value(xs, 3, 4);
const appended = conj_value([1, 2], 3, 4);
assert.ok(list_p(xs) && list_p(prefixed));
assert.ok(!list_p([1, 2]) && !list_p(appended));
assert.deepEqual(prefixed, [4, 3, 1, 2]);
assert.deepEqual(appended, [1, 2, 3, 4]);
assert.deepEqual(into_value(list(1, 2), [3, 4]), [4, 3, 1, 2]);

const mapSeq = seq(scalars);
assert.ok(seq_p(mapSeq));
assert.equal(mapSeq.length, 3);
assert.equal(first(eager_seq([7, 8])), 7);
assert.ok(seq_p(rest([7, 8])));
assert.deepEqual(rest([7, 8]), [8]);
assert.equal(next([7]), null);
assert.equal(seq([]), null);
assert.ok(empty_p(null));

console.log("collections-runtime: PASS");

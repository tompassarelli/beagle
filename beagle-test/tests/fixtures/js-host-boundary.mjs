import {
  aget,
  alength,
  array,
  aset,
  clj_to_js,
  host_array,
  host_object,
  into_array,
  is_host_array,
  is_host_object,
  iterable_array,
  js_delete,
  js_in,
  js_keys,
  js_obj,
  js_to_clj,
  object_array,
  to_array,
} from "../../../beagle-lib/lib/beagle/host.js";
import { property_key } from "../../../beagle-lib/lib/beagle/core.js";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function rejects(action, message) {
  let rejected = false;
  try { action(); } catch (error) { rejected = error instanceof TypeError; }
  assert(rejected, message);
}

const nested = host_array(host_object("row", host_array(4, 5)));
assert(aget(nested, 0, "row", 1) === 5, "nested aget");
assert(aset(nested, 0, "row", 1, 9) === 9, "nested aset result");
assert(aget(nested, 0, "row", 1) === 9, "nested aset mutation");
assert(alength(aget(nested, 0, "row")) === 2, "alength");

const constructed = array(1, 2);
const object = js_obj("present", true, "remove", 3);
assert(is_host_array(constructed) && is_host_object(object), "constructors brand host values");
assert(js_in("present", object), "js-in");
assert(js_delete(object, "remove") && !js_in("remove", object), "js-delete");
const objectKeys = js_keys(object);
assert(is_host_array(objectKeys) && objectKeys.length === 1 && objectKeys[0] === "present", "js-keys");

const copied = into_array(new Set([1, 2]));
const typedCopy = into_array("ignored-type", new Set([3, 4]));
const sized = object_array(3);
const sequenced = object_array(new Set([5, 6]));
assert(is_host_array(copied) && copied.join(",") === "1,2", "into-array");
assert(typedCopy.join(",") === "3,4", "typed into-array");
assert(sized.length === 3 && sized.every(value => value === null), "sized object-array");
assert(sequenced.join(",") === "5,6", "sequence object-array");

const persistent = [{[property_key("deep")]: [7, 8]}];
const converted = clj_to_js(persistent);
assert(converted !== persistent && is_host_array(converted), "clj->js allocates host array");
assert(is_host_object(converted[0]) && is_host_array(converted[0].deep), "clj->js recurses");
aset(converted, 0, "deep", 0, 11);
assert(persistent[0][property_key("deep")][0] === 7, "clj->js does not expose persistent storage");

const roundTrip = js_to_clj(converted);
assert(!is_host_array(roundTrip) && !is_host_object(roundTrip[0]), "js->clj returns persistent values");
assert(roundTrip[0][property_key("deep")][0] === 11, "js->clj recurses");
aset(converted, 0, "deep", 0, 12);
assert(roundTrip[0][property_key("deep")][0] === 11, "js->clj detaches host storage");

const generated = {
  *[Symbol.iterator]() {
    yield 13;
    yield 14;
  },
};
const hostCopy = to_array(generated);
const persistentCopy = iterable_array(generated);
assert(is_host_array(hostCopy) && hostCopy.join(",") === "13,14", "to-array host result");
assert(!is_host_array(persistentCopy) && persistentCopy.join(",") === "13,14", "iterable adapter persistent result");

rejects(() => aset([1, 2], 0, 3), "aset rejects ordinary vector storage");
rejects(() => js_delete({x: 1}, "x"), "js-delete rejects ordinary map storage");
rejects(() => alength([1, 2]), "alength rejects ordinary vector storage");

console.log("host-boundary: PASS");

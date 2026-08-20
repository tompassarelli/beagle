import assert from "node:assert/strict";

import {
  catch_dispatch,
  default_catch,
} from "../../beagle-lib/lib/beagle/exception-dispatch.js";
import {
  ExceptionInfo,
  ex_info,
} from "../../beagle-lib/lib/beagle/exception-info.js";
import {
  recover_exception,
} from "./fixtures/js-exception-dispatch.mjs";

const data = { phase: "compile" };
const exceptionInfo = ex_info("failed", data);

assert.equal(
  catch_dispatch(exceptionInfo, [TypeError, ExceptionInfo, Error]),
  1,
);
assert.equal(catch_dispatch(exceptionInfo, [Error, ExceptionInfo]), 0);
assert.equal(catch_dispatch("foreign throw", [Error, default_catch]), 1);

let laterTypeTested = false;
const laterType = {
  [Symbol.hasInstance]() {
    laterTypeTested = true;
    return true;
  },
};
assert.equal(catch_dispatch(exceptionInfo, [Error, laterType]), 0);
assert.equal(laterTypeTested, false);

const unmatched = new RangeError("unmatched");
assert.throws(
  () => catch_dispatch(unmatched, [TypeError, ExceptionInfo]),
  (caught) => caught === unmatched,
);

const infoEvents = [];
assert.deepEqual(
  recover_exception(() => {
    throw exceptionInfo;
  }, infoEvents),
  { message: "failed", data },
);
assert.deepEqual(infoEvents, ["exception-info", "finally"]);

const typeEvents = [];
assert.equal(
  recover_exception(() => {
    throw new TypeError("bad type");
  }, typeEvents),
  "bad type",
);
assert.deepEqual(typeEvents, ["type-error", "finally"]);

const defaultEvents = [];
assert.equal(
  recover_exception(() => {
    throw 42;
  }, defaultEvents),
  42,
);
assert.deepEqual(defaultEvents, ["default", "finally"]);

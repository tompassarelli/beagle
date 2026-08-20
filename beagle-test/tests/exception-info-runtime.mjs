import assert from "node:assert/strict";

import {
  ExceptionInfo,
  ex_cause,
  ex_data,
  ex_info,
  ex_message,
} from "../../beagle-lib/lib/beagle/exception-info.js";

const data = { phase: "compile" };
const cause = new TypeError("invalid input");
const error = ex_info("failed", data, cause);

assert.ok(error instanceof ExceptionInfo);
assert.ok(error instanceof Error);
assert.equal(error.message, "failed");
assert.equal(error.name, "Error");
assert.equal(typeof error.stack, "string");
assert.strictEqual(error.data, data);
assert.strictEqual(error.cause, cause);
assert.strictEqual(ex_data(error), data);
assert.equal(ex_message(error), "failed");
assert.strictEqual(ex_cause(error), cause);

const withoutCause = new ExceptionInfo("plain", {});
assert.equal(withoutCause.cause, null);
assert.equal(ex_data(new Error("ordinary")), null);
assert.equal(ex_message({ message: "not an error" }), null);
assert.equal(ex_cause(cause), null);


function obj_keys(o) {
  return Object.keys(o);
}

function obj_values(o) {
  return Object.values(o);
}

function obj_entries(o) {
  return Object.entries(o);
}

function merge_objects(a, b) {
  return Object.assign(a, b);
}

function freeze_it(o) {
  return Object.freeze(o);
}

function is_frozen_p(o) {
  return Object.isFrozen(o);
}

function from_entries(pairs) {
  return Object.fromEntries(pairs);
}

function parse_int_of(s) {
  return Number.parseInt(s, 10);
}

function parse_float_of(s) {
  return Number.parseFloat(s);
}

function array_from(iter) {
  return Array.from(iter);
}

function array_is_p(x) {
  return Array.isArray(x);
}

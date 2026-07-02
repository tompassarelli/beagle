
function parse_config(s) {
  return JSON.parse(s);
}

function to_config(obj) {
  return JSON.stringify(obj);
}

function floor_of(x) {
  return Math.floor(x);
}

function sqrt_of(x) {
  return Math.sqrt(x);
}

function pow_of(x, y) {
  return Math.pow(x, y);
}

function random_float() {
  return Math.random();
}

function pi_times(n) {
  return (Math.PI * n);
}

function integer_p(x) {
  return Number.isInteger(x);
}

function nan_p(x) {
  return Number.isNaN(x);
}

function parse_int(s) {
  return Number.parseInt(s);
}

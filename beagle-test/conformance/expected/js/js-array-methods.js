
function push_one(xs, x) {
  return xs.push(x);
}

function pop_last(xs) {
  return xs.pop();
}

function first_idx(xs, target) {
  return xs.indexOf(target);
}

function includes_p(xs, target) {
  return xs.includes(target);
}

function joined(xs) {
  return xs.join(", ");
}

function sliced(xs, start, end) {
  return xs.slice(start, end);
}

function reversed(xs) {
  return xs.reverse();
}

function concatenated(a, b) {
  return a.concat(b);
}

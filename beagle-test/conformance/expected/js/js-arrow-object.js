
function pairs(xs) {
  return xs.map((g) => ({k: g.name, v: g.v}));
}

function empties(xs) {
  return xs.map((__x) => ({}));
}

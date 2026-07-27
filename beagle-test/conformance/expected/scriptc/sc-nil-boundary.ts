
function nil_value(x: null): null {
  return x;
}

function nil_or_zero(x: null): number {
  return ((x == null) ? 0 : 1);
}

console.log(nil_value(null));

console.log(nil_or_zero(null));

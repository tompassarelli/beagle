
function classify(n: number): string {
  return ((n < 0)) ? "negative" : ((n < 1)) ? "zero" : "positive";
}

function clamped(n: number): number {
  const lo = 0;
  const hi = 10;
  return ((n < lo) ? lo : ((hi < n) ? hi : n));
}

console.log(classify(-5));

console.log(classify(0));

console.log(classify(42));

console.log(clamped(-3));

console.log(clamped(25));

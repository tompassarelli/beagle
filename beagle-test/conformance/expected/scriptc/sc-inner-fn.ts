
function apply_twice(x: number): number {
  const bump = (n) => (n + 1);
  return bump(bump(x));
}

console.log(apply_twice(40));

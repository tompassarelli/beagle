
function apply_twice(x: number): number {
  const bump = (n: number): number => (n + 1);
  return bump(bump(x));
}

console.log(apply_twice(40));

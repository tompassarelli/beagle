
function add(x: number, y: number): number {
  return (x + y);
}

function scale(x: number, factor: number): number {
  return (add(x, 1) * factor);
}

console.log(add(20, 22));

console.log(scale(6, 7));

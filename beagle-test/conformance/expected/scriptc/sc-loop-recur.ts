
function sum_to(n: number): number {
  return (() => { let i = 1; let acc = 0; while (true) {
    if ((n < i)) { return acc; } else { const _recur_0 = (i + 1); const _recur_1 = (acc + i); i = _recur_0; acc = _recur_1; continue; }
  } })();
}

console.log(sum_to(10));

console.log(sum_to(0));

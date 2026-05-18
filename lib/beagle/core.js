export function range(...args) {
  let start = 0, end, step = 1;
  if (args.length === 1) { end = args[0]; }
  else if (args.length === 2) { start = args[0]; end = args[1]; }
  else { start = args[0]; end = args[1]; step = args[2]; }
  const r = [];
  if (step > 0) { for (let i = start; i < end; i += step) r.push(i); }
  else if (step < 0) { for (let i = start; i > end; i += step) r.push(i); }
  return r;
}

export function remove(pred, coll) {
  return coll.filter(x => !pred(x));
}

export function mapcat(f, coll) {
  return coll.flatMap(f);
}

export function every_p(pred, coll) {
  return coll.every(pred);
}

export function keep(f, coll) {
  return coll.map(f).filter(x => x != null);
}

export function map_indexed(f, coll) {
  return coll.map((x, i) => f(i, x));
}

export function assoc_in(m, path, v) {
  if (path.length === 0) return v;
  const [k, ...rest] = path;
  return { ...m, [k]: rest.length === 0 ? v : assoc_in(m[k] || {}, rest, v) };
}

export function update_in(m, path, f) {
  if (path.length === 0) return f(m);
  const [k, ...rest] = path;
  return { ...m, [k]: rest.length === 0 ? f(m[k]) : update_in(m[k] || {}, rest, f) };
}

export function select_keys(m, ks) {
  const r = {};
  for (const k of ks) if (k in m) r[k] = m[k];
  return r;
}

export function merge_with(f, ...ms) {
  const r = {};
  for (const m of ms) {
    for (const k in m) {
      r[k] = k in r ? f(r[k], m[k]) : m[k];
    }
  }
  return r;
}

export function take_while(pred, coll) {
  const r = [];
  for (const x of coll) {
    if (!pred(x)) break;
    r.push(x);
  }
  return r;
}

export function drop_while(pred, coll) {
  let dropping = true;
  const r = [];
  for (const x of coll) {
    if (dropping && pred(x)) continue;
    dropping = false;
    r.push(x);
  }
  return r;
}

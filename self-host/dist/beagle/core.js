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

export function memoize(f) {
  const cache = new Map();
  return (...args) => {
    const k = JSON.stringify(args);
    if (cache.has(k)) return cache.get(k);
    const v = f(...args);
    cache.set(k, v);
    return v;
  };
}

export function fnil(f, ...defaults) {
  return (...args) => f(...args.map((a, i) => a == null && i < defaults.length ? defaults[i] : a));
}

export function some_fn(...preds) {
  return (...args) => {
    for (const p of preds) {
      const v = p(...args);
      if (v) return v;
    }
    return null;
  };
}

export function every_pred(...preds) {
  return (...args) => {
    for (const p of preds) {
      if (!p(...args)) return false;
    }
    return true;
  };
}

export function rename_keys(m, kmap) {
  const r = { ...m };
  for (const [old_k, new_k] of Object.entries(kmap)) {
    if (old_k in r) {
      r[new_k] = r[old_k];
      delete r[old_k];
    }
  }
  return r;
}

export function map_keys(f, m) {
  return Object.fromEntries(Object.entries(m).map(([k, v]) => [f(k), v]));
}

export function map_vals(f, m) {
  return Object.fromEntries(Object.entries(m).map(([k, v]) => [k, f(v)]));
}

export function disj(s, ...ks) {
  const r = new Set(s);
  for (const k of ks) r.delete(k);
  return r;
}

export function reduce_kv(f, init, m) {
  let acc = init;
  for (const [k, v] of Object.entries(m)) acc = f(acc, k, v);
  return acc;
}

export function dedupe(coll) {
  const r = [];
  let prev;
  for (const x of coll) {
    if (r.length === 0 || x !== prev) r.push(x);
    prev = x;
  }
  return r;
}

export function interpose(sep, coll) {
  const r = [];
  for (let i = 0; i < coll.length; i++) {
    if (i > 0) r.push(sep);
    r.push(coll[i]);
  }
  return r;
}

export function partition_all(n, coll) {
  const r = [];
  for (let i = 0; i < coll.length; i += n) r.push(coll.slice(i, i + n));
  return r;
}

export function partition_by(f, coll) {
  if (coll.length === 0) return [];
  const r = [];
  let group = [coll[0]], prev = f(coll[0]);
  for (let i = 1; i < coll.length; i++) {
    const cur = f(coll[i]);
    if (cur === prev) { group.push(coll[i]); }
    else { r.push(group); group = [coll[i]]; prev = cur; }
  }
  r.push(group);
  return r;
}

export function split_with(pred, coll) {
  const t = [], d = [];
  let splitting = true;
  for (const x of coll) {
    if (splitting && pred(x)) t.push(x);
    else { splitting = false; d.push(x); }
  }
  return [t, d];
}

export function zipmap(keys, vals) {
  const r = {};
  for (let i = 0; i < keys.length && i < vals.length; i++) r[keys[i]] = vals[i];
  return r;
}

export function format(fmt, ...args) {
  let i = 0;
  return fmt.replace(/%[sd]/g, () => i < args.length ? String(args[i++]) : '');
}

export function hash(x) {
  const s = JSON.stringify(x);
  let h = 0;
  for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  return h;
}

export function get_in(m, path) {
  let v = m;
  for (const k of path) {
    if (v == null) return null;
    v = v[k];
  }
  return v ?? null;
}

export function take_nth(n, coll) {
  const r = [];
  for (let i = 0; i < coll.length; i += n) r.push(coll[i]);
  return r;
}

export function keep_indexed(f, coll) {
  return coll.map((x, i) => f(i, x)).filter(x => x != null);
}

export function reductions(f, ...args) {
  const [init, coll] = args.length === 1 ? [args[0][0], args[0].slice(1)] : [args[0], args[1]];
  const r = [init];
  let acc = init;
  for (const x of coll) { acc = f(acc, x); r.push(acc); }
  return r;
}

export function replace(smap, coll) {
  return coll.map(x => x in smap ? smap[x] : x);
}

export function max_key(k, ...xs) {
  return xs.reduce((a, b) => k(b) > k(a) ? b : a);
}

export function min_key(k, ...xs) {
  return xs.reduce((a, b) => k(b) < k(a) ? b : a);
}

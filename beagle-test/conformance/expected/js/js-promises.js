
async function fetch_text(url) {
  const resp = await fetch(url);
  return await resp.text();
}

async function fetch_and_parse(url) {
  const text = await fetch_text(url);
  return parse_json(text);
}

async function fetch_both(a, b) {
  const ta = await fetch_text(a);
  const tb = await fetch_text(b);
  return [ta, tb];
}

function resolve_now(x) {
  return Promise.resolve(x);
}

function reject_with(msg) {
  return Promise.reject(msg);
}

function all_of(promises) {
  return Promise.all(promises);
}

function race_of(promises) {
  return Promise.race(promises);
}

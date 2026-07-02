
function Product(name, price, in_stock) {
  return Object.freeze({_tag: "Product", name, price, in_stock});
}

function product_name(r) { return r.name; }

function product_price(r) { return r.price; }

function product_in_stock(r) { return r.in_stock; }

const tax_rate = 0.08;

function make_product(name, price) {
  return Product(name, price, true);
}

function product_total(p) {
  return (product_price(p) + (product_price(p) * tax_rate));
}

function discount(p, pct) {
  return Object.freeze({...p, price: (product_price(p) - (product_price(p) * pct))});
}

function cheap_p(p) {
  return (product_price(p) < 10);
}

function summarize(products) {
  return products.map((p) => product_name(p));
}

function find_cheap(products) {
  return products.filter((p) => cheap_p(p)).map((p) => p);
}

function process_order(p) {
  return (product_in_stock(p) ? ("".concat("Shipping: ", product_name(p))) : "Out of stock");
}

function classify(p) {
  return ((product_price(p) < 10)) ? "budget" : ((product_price(p) < 50)) ? "mid-range" : "premium";
}

function safe_lookup(products, idx) {
  const p = (() => { const _x = products, _i = idx; return _x[_i] != null ? _x[_i] : null; })();
  return ((p == null) ? "not found" : product_name(p));
}

function greet(name) {
  return console.log(("".concat("Hello, ", name, "!")));
}

async function load_and_classify(id) {
  const p = await fetch_product(id);
  return classify(p);
}

async function load_two(a, b) {
  const p1 = await fetch_product(a);
  const p2 = await fetch_product(b);
  return [product_name(p1), product_name(p2)];
}

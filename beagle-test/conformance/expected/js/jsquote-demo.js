
const greeting = "Hello, World!";

function validateAge(age) {
  if ((age < 0)) {
    throw new Error("Age cannot be negative");
  } else {
    if ((age >= 18)) {
      return true;
    } else {
      return false;
    }
  }
}

export async function fetchData(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`HTTP error: ${response.status}`);
  }
  const data = await response.json();
  return data;
}

const api_base = "/api/v1";

const baseUrl = unquote(api_base);
const fullUrl = `${baseUrl}/users`;

class Counter {
  constructor(initial) {
    this.count = initial;
  }

  increment() {
    this.count = (this.count + 1);
    return this;
  }

  get value() {
    return this.count;
  }

  static create() {
    return new Counter(0);
  }
}

function processItems(items) {
  const results = [];
  for (const item of items) {
    const processed = `item: ${item}`;
    results.push(processed);
  }
  return results;
}

async function safeFetch(url) {
  try {
    const response = await fetch(url);
    return await response.json();
  } catch (err) {
    console.error(err.message);
    return null;
  } finally {
    console.log("fetch complete");
  }
}

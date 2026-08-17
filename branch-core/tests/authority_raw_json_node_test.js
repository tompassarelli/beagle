'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

class ParseFailure extends Error {}

function parseStrictAuthorityJson(raw) {
  let index = 0;

  function fail(message) {
    throw new ParseFailure(`${message} at offset ${index}`);
  }

  function skipWhitespace() {
    while (index < raw.length) {
      const character = raw[index];
      if (character !== ' ' && character !== '\t' && character !== '\r' && character !== '\n') {
        break;
      }
      index += 1;
    }
  }

  function readHexUnit() {
    const digits = raw.slice(index, index + 4);
    if (digits.length !== 4 || !/^[0-9a-fA-F]{4}$/.test(digits)) {
      fail('invalid Unicode escape');
    }
    index += 4;
    return Number.parseInt(digits, 16);
  }

  function isHighSurrogate(unit) {
    return unit >= 0xd800 && unit <= 0xdbff;
  }

  function isLowSurrogate(unit) {
    return unit >= 0xdc00 && unit <= 0xdfff;
  }

  function parseString() {
    if (raw[index] !== '"') {
      fail('expected string');
    }
    index += 1;
    let value = '';

    while (index < raw.length) {
      const character = raw[index];
      if (character === '"') {
        index += 1;
        return value;
      }

      if (character === '\\') {
        index += 1;
        if (index >= raw.length) {
          fail('unterminated escape');
        }
        const escape = raw[index];
        index += 1;
        const simpleEscapes = {
          '"': '"',
          '\\': '\\',
          '/': '/',
          b: '\b',
          f: '\f',
          n: '\n',
          r: '\r',
          t: '\t'
        };
        if (Object.hasOwn(simpleEscapes, escape)) {
          value += simpleEscapes[escape];
          continue;
        }
        if (escape !== 'u') {
          fail('invalid escape');
        }

        const first = readHexUnit();
        if (isLowSurrogate(first)) {
          fail('lone low surrogate');
        }
        if (!isHighSurrogate(first)) {
          value += String.fromCharCode(first);
          continue;
        }
        if (raw[index] !== '\\' || raw[index + 1] !== 'u') {
          fail('lone high surrogate');
        }
        index += 2;
        const second = readHexUnit();
        if (!isLowSurrogate(second)) {
          fail('high surrogate without low surrogate');
        }
        value += String.fromCharCode(first, second);
        continue;
      }

      const unit = raw.charCodeAt(index);
      if (unit <= 0x1f) {
        fail('raw control character');
      }
      if (isLowSurrogate(unit)) {
        fail('lone low surrogate');
      }
      if (isHighSurrogate(unit)) {
        const second = raw.charCodeAt(index + 1);
        if (!isLowSurrogate(second)) {
          fail('lone high surrogate');
        }
        value += raw[index] + raw[index + 1];
        index += 2;
        continue;
      }
      value += character;
      index += 1;
    }
    fail('unterminated string');
  }

  function parseArray() {
    index += 1;
    const values = [];
    skipWhitespace();
    if (raw[index] === ']') {
      index += 1;
      return values;
    }

    while (true) {
      values.push(parseValue());
      skipWhitespace();
      if (raw[index] === ']') {
        index += 1;
        return values;
      }
      if (raw[index] !== ',') {
        fail('expected comma or closing bracket');
      }
      index += 1;
    }
  }

  function parseObject() {
    index += 1;
    const entries = [];
    const names = new Set();
    skipWhitespace();
    if (raw[index] === '}') {
      index += 1;
      return {};
    }

    while (true) {
      skipWhitespace();
      if (raw[index] !== '"') {
        fail('expected object key');
      }
      const name = parseString();
      if (names.has(name)) {
        fail('duplicate object key');
      }
      names.add(name);
      skipWhitespace();
      if (raw[index] !== ':') {
        fail('expected colon');
      }
      index += 1;
      entries.push([name, parseValue()]);
      skipWhitespace();
      if (raw[index] === '}') {
        index += 1;
        return Object.fromEntries(entries);
      }
      if (raw[index] !== ',') {
        fail('expected comma or closing brace');
      }
      index += 1;
    }
  }

  function parseValue() {
    skipWhitespace();
    if (raw[index] === '"') {
      return parseString();
    }
    if (raw[index] === '[') {
      return parseArray();
    }
    if (raw[index] === '{') {
      return parseObject();
    }
    if (raw.startsWith('true', index)) {
      index += 4;
      return true;
    }
    if (raw.startsWith('false', index)) {
      index += 5;
      return false;
    }
    fail('expected authority JSON value');
  }

  const value = parseValue();
  skipWhitespace();
  if (index !== raw.length) {
    fail('trailing input');
  }
  return value;
}

function loadFixture(fixturePath) {
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  assert.equal(fixture.fixtureVersion, 'fram.authority/raw-json-no-number-no-null/v1');
  assert.ok(Array.isArray(fixture.vectors));

  const names = new Set();
  for (const vector of fixture.vectors) {
    assert.equal(typeof vector.name, 'string');
    assert.ok(!names.has(vector.name), `duplicate vector name: ${vector.name}`);
    names.add(vector.name);
    assert.equal(typeof vector.raw, 'string', `${vector.name}: raw must be a string`);
    const hasExpected = Object.hasOwn(vector, 'expected');
    assert.notEqual(hasExpected, vector.reject === true, `${vector.name}: choose expected or reject=true`);
  }
  return fixture;
}

const fixturePath = process.argv[2] || path.join(__dirname, 'fixtures', 'authority_raw_json_v1.json');
const fixture = loadFixture(fixturePath);
const failures = [];
let passed = 0;

for (const vector of fixture.vectors) {
  try {
    const actual = parseStrictAuthorityJson(vector.raw);
    if (vector.reject === true) {
      failures.push(`${vector.name}: accepted a rejected input`);
      continue;
    }
    assert.deepEqual(actual, vector.expected);
    passed += 1;
  } catch (error) {
    if (vector.reject === true && error instanceof ParseFailure) {
      passed += 1;
    } else {
      failures.push(`${vector.name}: ${error.stack || error}`);
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(failure);
  }
  console.error(`FAIL ${passed}/${fixture.vectors.length}`);
  process.exitCode = 1;
} else {
  console.log(`PASS ${passed}`);
}

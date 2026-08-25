export function join(separatorOrValues, maybeValues) {
  const separator = maybeValues === undefined ? "" : separatorOrValues;
  const values = maybeValues === undefined ? separatorOrValues : maybeValues;
  return Array.from(values).join(separator);
}

export function split(value, pattern, limit = 0) {
  const pieces = value.split(pattern, limit > 0 ? limit : undefined);
  if (limit === 0) {
    while (pieces.at(-1) === "") pieces.pop();
  }
  return pieces;
}

export function replace(value, match, replacement) {
  if (typeof match === "string") {
    return value.split(match).join(replacement);
  }
  const flags = match.flags.replace(/[gy]/g, "") + (match.flags.includes("u") ? "g" : "gu");
  return value.replace(new RegExp(match.source, flags), replacement);
}

export function trim(value) {
  return value.trim();
}

export function triml(value) {
  return value.trimStart();
}

export function trimr(value) {
  return value.trimEnd();
}

export function upper_case(value) {
  return value.toUpperCase();
}

export function lower_case(value) {
  return value.toLowerCase();
}

export function capitalize(value) {
  return value.length === 0
    ? value
    : value.charAt(0).toUpperCase() + value.slice(1).toLowerCase();
}

export function blank_p(value) {
  return value == null || /^\s*$/.test(value);
}

export function includes_p(value, search) {
  return value.includes(search);
}

export function starts_with_p(value, search) {
  return value.startsWith(search);
}

export function ends_with_p(value, search) {
  return value.endsWith(search);
}

export function reverse(value) {
  return Array.from(value).reverse().join("");
}

export function escape(value, characterMap) {
  return Array.from(value, (character) => {
    if (characterMap instanceof Map && characterMap.has(character)) {
      return characterMap.get(character);
    }
    if (characterMap != null && Object.hasOwn(characterMap, character)) {
      return characterMap[character];
    }
    return character;
  }).join("");
}

export function re_quote_replacement(value) {
  return value.replaceAll("\\", "\\\\").replaceAll("$", "\\$");
}

export function index_of(value, search, fromIndex = 0) {
  const index = value.indexOf(search, fromIndex);
  return index === -1 ? null : index;
}

export function last_index_of(value, search, fromIndex = value.length) {
  const index = value.lastIndexOf(search, fromIndex);
  return index === -1 ? null : index;
}

export function split_lines(value) {
  return value.split(/\r\n|\n|\r/);
}

export function replace_first(value, match, replacement) {
  if (typeof match === "string") {
    const index = value.indexOf(match);
    return index === -1
      ? value
      : value.slice(0, index) + replacement + value.slice(index + match.length);
  }
  return value.replace(match, replacement);
}

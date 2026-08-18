import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const domain = [...new TextEncoder().encode('beagle.store/FactEnvelope')];
const kinds = new Map([
  ['GateCandidateV1', 1],
  ['GatePhaseClaimV1', 2],
  ['GatePhaseObservationV1', 3],
  ['GateCandidateVerdictV1', 4],
  ['FactMissEventV1', 5],
  ['GateMaintenanceReceiptV1', 6],
  ['DevCompileUnitResultV1', 7],
]);

const u16 = value => [(value >>> 8) & 255, value & 255];
const u32 = value => [
  (value >>> 24) & 255,
  (value >>> 16) & 255,
  (value >>> 8) & 255,
  value & 255,
];
const i64 = value => {
  const bits = BigInt.asUintN(64, value);
  return [56n, 48n, 40n, 32n, 24n, 16n, 8n, 0n]
    .map(shift => Number((bits >> shift) & 255n));
};
const compareBytes = (left, right) => {
  for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return left.length - right.length;
};
const counted = (tag, items) => [tag, ...u32(items.length), ...items.flat()];

function valueBytes(value) {
  if (value === null) return [0];
  if (value === false) return [1];
  if (value === true) return [2];
  if (typeof value === 'string') {
    const bytes = [...new TextEncoder().encode(value)];
    return [5, ...u32(bytes.length), ...bytes];
  }
  if (Array.isArray(value)) return counted(7, value.map(valueBytes));
  if (typeof value !== 'object') throw new Error('fixture value is not tagged');
  if ('$int' in value) return [3, ...i64(BigInt(value.$int))];
  if ('$float' in value) return [4, ...i64(BigInt(`0x${value.$float}`))];
  if ('$keyword' in value) {
    const bytes = [...new TextEncoder().encode(value.$keyword)];
    return [6, ...u32(bytes.length), ...bytes];
  }
  if ('$set' in value) {
    const items = value.$set.map(valueBytes).sort(compareBytes);
    return counted(9, items);
  }
  if ('$map' in value) {
    const entries = value.$map
      .map(([key, item]) => [valueBytes(key), valueBytes(item)])
      .sort((left, right) => compareBytes(left[0], right[0]));
    return counted(8, entries.map(([key, item]) => [...key, ...item]));
  }
  throw new Error('unknown fixture tag');
}

function envelope(kind, payload) {
  const body = valueBytes(payload);
  const bytes = [...domain, ...u16(1), ...u16(kinds.get(kind)), ...u32(body.length), ...body];
  const hex = Buffer.from(bytes).toString('hex');
  const id = `sha256:${createHash('sha256').update(Buffer.from(bytes)).digest('hex')}`;
  return { hex, id };
}

const fixture = JSON.parse(readFileSync(process.argv[2], 'utf8'));
process.stdout.write(JSON.stringify(fixture.vectors.map(
  vector => ({ name: vector.name, ...envelope(vector.kind, vector.payload) }),
)));

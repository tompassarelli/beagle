# Standard library catalog

## Overview

~729 pre-typed entries across 6 targets.

## Portable (all targets) — 269 entries

### Collections
`map`, `filter`, `reduce`, `mapv`, `filterv`, `first`, `rest`, `last`,
`next`, `count`, `empty?`, `conj`, `into`, `concat`, `flatten`,
`distinct`, `sort`, `sort-by`, `reverse`, `take`, `drop`, `take-while`,
`drop-while`, `partition`, `partition-by`, `group-by`, `frequencies`,
`interleave`, `interpose`, `zipmap`

### Higher-order
`apply`, `partial`, `comp`, `complement`, `juxt`, `identity`, `constantly`,
`every?`, `some`, `not-any?`, `not-every?`, `keep`, `map-indexed`,
`mapcat`, `remove`

### Math
`+`, `-`, `*`, `/`, `mod`, `rem`, `inc`, `dec`, `max`, `min`, `abs`,
`Math/floor`, `Math/ceil`, `Math/round`, `Math/sqrt`, `Math/pow`,
`Math/random`, `rand`, `rand-int`

### String
`str`, `subs`, `str/join`, `str/split`, `str/replace`, `str/trim`,
`str/lower-case`, `str/upper-case`, `str/blank?`, `str/starts-with?`,
`str/ends-with?`, `str/includes?`

### Equality & comparison
`=`, `not=`, `<`, `>`, `<=`, `>=`, `compare`, `identical?`

### Boolean
`and`, `or`, `not`, `true?`, `false?`, `boolean`

### Type predicates
`nil?`, `some?`, `string?`, `number?`, `integer?`, `float?`,
`keyword?`, `symbol?`, `boolean?`, `fn?`, `seq?`, `coll?`,
`vector?`, `map?`, `set?`, `sequential?`

### I/O
`println`, `print`, `pr`, `prn`, `pr-str`, `newline`, `slurp`, `spit`

### Access
`get`, `get-in`, `assoc`, `assoc-in`, `dissoc`, `update`, `update-in`,
`select-keys`, `merge`, `merge-with`, `keys`, `vals`, `contains?`

## JavaScript target — 38 entries

`Math.floor`, `Math.ceil`, `Math.round`, `Math.abs`, `Math.min`,
`Math.max`, `Math.random`, `Math.sqrt`, `Math.pow`, `Math.log`,
`JSON.parse`, `JSON.stringify`, `parseInt`, `parseFloat`,
`console.log`, `console.error`, `console.warn`,
`Promise.resolve`, `Promise.reject`, `Promise.all`, `Promise.race`,
`fetch`, `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`,
`Object.keys`, `Object.values`, `Object.entries`, `Object.assign`,
`Array.isArray`, `Array.from`, `String.fromCharCode`,
`encodeURIComponent`, `decodeURIComponent`, `Date.now`, `isNaN`, `isFinite`

## Nix target — 120 entries

`builtins.map`, `builtins.filter`, `builtins.length`, `builtins.head`,
`builtins.tail`, `builtins.elem`, `builtins.attrNames`, `builtins.attrValues`,
`builtins.hasAttr`, `builtins.getAttr`, `builtins.isString`, `builtins.isBool`,
`builtins.isInt`, `builtins.isList`, `builtins.isAttrs`, `builtins.isNull`,
`builtins.toString`, `builtins.toJSON`, `builtins.fromJSON`,
`builtins.readFile`, `builtins.pathExists`, `builtins.import`,
`lib.mkOption`, `lib.mkEnableOption`, `lib.mkIf`, `lib.mkMerge`,
`lib.mkDefault`, `lib.mkForce`, `lib.mkOverride`,
`lib.types.str`, `lib.types.bool`, `lib.types.int`, `lib.types.port`,
`lib.types.path`, `lib.types.package`, `lib.types.listOf`,
`lib.types.attrsOf`, `lib.types.enum`, `lib.types.nullOr`,
`lib.types.submodule`, `lib.types.either`
(and more — run `beagle provides` on .bnix files for full list)

## Lookup

Use query tools for precise signatures:
```bash
beagle sig map examples/      # typed signature of map
beagle fields Point src/      # fields of a record
```

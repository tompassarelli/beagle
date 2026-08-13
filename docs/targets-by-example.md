# Targets by example

Bare `#lang beagle` on `.bgl` selects Native Core; `.bgl` is not a neutral
container for a later target choice. `beagle build --materializer c17|qbe|wasm
--out DIR FILE.bgl` first freezes `module.native-program`, then writes only the
selected projection. `wasm` requires `--abi wasm32`; it is currently the named
Restricted-C17-to-wasi-clang bootstrap rather than a direct emitter. Its reactor
exports only `_initialize` and `memory`, and `module_0.wasm.seams` records the
exact import/export surface. That frozen native program is backend-neutral even
though its source profile is native. Hosted Clojure is explicit
`#lang beagle/clj` on `.bclj`; JavaScript and Nix keep their explicit language
paths below.

## One source, many hosted back-ends

The same source body, saved as `.bclj`, `.bjs`, and `.bnix`:

```clojure
(defn even-doubles [(xs (List Int))] (List Int)
  (->> xs
       (filter even?)
       (map (fn [(n Int)] Int (* n 2)))))
```

Each target renders it idiomatically — not transliterated:

```clojure
;; → Clojure: threading macro and seq fns preserved
(defn even-doubles [xs]
  (->> xs (filter even?) (map (fn [n] (* n 2)))))
```

```javascript
// → JavaScript: array methods + arrow functions
function even_doubles(xs) {
  return xs.filter(((_x) => _x % 2 === 0)).map((n) => (n * 2));
}
```

```nix
# → Nix: lazy let-bindings and curried lambdas
let
  even-doubles = xs: builtins.map (n: (n * 2)) (builtins.filter even_p xs);
in
null
```

Same logic, three back-ends. `even?` becomes `even_p` where the target's
identifiers can't carry a `?` — names follow each language's rules, the shape
follows each language's idiom. Static type information erases after doing its
job at check time; an explicitly authored binding constraint remains only as
its target-idiomatic runtime guard.

## Typed against the target's real schema

Types aren't only shapes you declare — they can come from the target itself. A
NixOS module, authored against the typed option schema:

```clojure
#lang beagle/nix
(ns ssh)

(nix/module [config lib pkgs ...]
  {:options.myConfig.modules.ssh.enable (lib.mkEnableOption "SSH server")
   :config
    (lib.mkIf config.myConfig.modules.ssh.enable
      {:services.openssh.enable true})})
```

emits:

```nix
{ config, lib, pkgs, ... }:
{
  options.myConfig.modules.ssh.enable = lib.mkEnableOption "SSH server";
  config = lib.mkIf config.myConfig.modules.ssh.enable {
    services.openssh.enable = true;
  };
}
```

`services.openssh.enable` is typed `Bool`, resolved from the schema cache.
Assigning a `String` fails at check time with `file:line:col` precision —
*before* `nixos-rebuild` is ever invoked. Unknown option paths fail at parse
time; wrong-typed values fail at type-check time.

For a longer `.bnix` module, see `examples/nix-module.bnix`; for a whole NixOS
system authored this way, see [firn](https://github.com/tompassarelli/firn),
which builds from `flake.bnix` directly.

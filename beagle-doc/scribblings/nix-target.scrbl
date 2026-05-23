#lang scribble/manual

@title{Nix Target}

@section{Overview}

@tt{#lang beagle/nix} compiles to Nix expression-language source code.
Use it for NixOS modules, flake skeletons, overlays, and standalone
package derivations.

@codeblock|{
#lang beagle/nix
(ns demo)

(module [config lib pkgs]
  (with-cfg config.myConfig.modules.demo
    {:options.myConfig.modules.demo {:enable (lib/mkEnableOption "demo")}
     :config (lib/mkIf cfg.enable
       {:environment.systemPackages [pkgs.hello]})}))
}|

Compiles to:

@codeblock|{
{ config, lib, pkgs, ... }:

let
  cfg = config.myConfig.modules.demo;
in
{
  options.myConfig.modules.demo = {
    enable = lib.mkEnableOption "demo";
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hello ];
  };
}
}|

@section{Lambdas / Attrset Functions}

Nix functions that take an attrset come in three shapes:

@tabular[#:sep @hspace[2]
  (list
    (list @bold{Beagle} @bold{Nix})
    (list @tt{(fn-set [a b] body)}        @tt{{ a, b }: body})
    (list @tt{(module [a b] body)}        @tt{{ a, b, ... }: body})
    (list @tt{(overlay [final prev] body)} @tt{final: prev: body}))]

@bold{module} is for NixOS modules (and any open-attrs lambda). @bold{fn-set} is
the closed form (rejects unknown attrs). @bold{overlay} requires exactly two
positional formals and is curried (not an attrset lambda).

@section{Recommended Authoring Idiom: with-cfg}

NixOS modules conventionally bind @tt{cfg = config.<path>;} in a @tt{let} block.
The @tt{(with-cfg PATH BODY)} form does this AST-level, also rewriting
@tt{PATH.foo} references inside @tt{BODY} to @tt{cfg.foo} for readability.

@codeblock|{
(with-cfg config.services.demo
  (lib/mkIf cfg.enable
    {:networking.firewall.allowedTCPPorts [cfg.port]}))
}|

→

@codeblock|{
let
  cfg = config.services.demo;
in
lib.mkIf cfg.enable {
  networking.firewall.allowedTCPPorts = [ cfg.port ];
}
}|

@section{Strings}

Three coherent strategies:

@tabular[#:sep @hspace[2]
  (list
    (list @bold{Beagle} @bold{Nix} @bold{Use for})
    (list @tt{"hi"}                @tt{"hi"}            "plain literal")
    (list @tt{~"hi ${name}!"}      @tt{"hi ${name}!"}   "single-line interpolation (reader macro)")
    (list @tt{(s "hi " name "!")}  @tt{"hi ${name}!"}   "explicit s-form (equivalent to ~\"...\")")
    (list @tt{(ms "l1" "l2")}      @tt{''\nl1\nl2\n''}    "multi-line + interp")
    (list @tt{''raw text''}        @tt{''raw text''}    "reader-level indented string"))]

The reader macro @tt{~"text ${expr} text"} is the canonical way to write
interpolated strings. It desugars to @tt{(s "text " expr " text")}.
Escapes: @tt{\\n}, @tt{\\t}, @tt{\\"}, @tt{\\$}, @tt{\\\\}.

@section{Attrsets and Lists}

Map literals lower to Nix attrsets; keyword keys are attribute names.
Dotted keyword keys flatten to native Nix path syntax.

@codeblock|{
{:networking.firewall.allowedTCPPorts [22 80 443]}
}|

→

@codeblock|{
{ networking.firewall.allowedTCPPorts = [ 22 80 443 ]; }
}|

Vec literals lower to Nix lists. Set literals (@tt{#{...}}) are rejected on
the Nix target (Nix has no native set; use a list or an attrset of booleans).

@section{Records (recursive attrsets)}

@codeblock|{
(rec-attrs hostName "myhost"
           domain (s hostName ".local"))
}|

→

@codeblock|{
rec {
  hostName = "myhost";
  domain = "${hostName}.local";
}
}|

@section{inherit / inherit-from}

@codeblock|{
(inherit a b c)               → inherit a b c;
(inherit-from pkgs vim git)   → inherit (pkgs) vim git;
}|

@section{Scoped Lookup: with}

@tt{(with NS BODY)} produces a Nix @tt{with NS; BODY} expression. Disambiguated
from the cross-target record-update @tt{(with target [:k v] ...)} by argument
shape: if there is one body arg that is not a @tt{[:keyword value]} bracket,
it parses as Nix scope.

@codeblock|{
(with pkgs [hello cowsay fortune])
}|

→ @tt{with pkgs; [ hello cowsay fortune ]}

@section{Assertions and Implication}

@tabular[#:sep @hspace[2]
  (list
    (list @tt{(assert cond body)}    @tt{assert cond; body})
    (list @tt{(implies a b)}         @tt{(a -> b)})
    (list @tt{(has base 'a.b)}       @tt{base ? a.b})
    (list @tt{(get-or base 'a.b d)}  @tt{base.a.b or d}))]

@section{Paths and Search Paths}

@tabular[#:sep @hspace[2]
  (list
    (list @tt{(p "./hardware.nix")}  @tt{./hardware.nix})
    (list @tt{(search-path nixpkgs)} @tt{<nixpkgs>}))]

@section{Pipes (Nix 2.15+)}

@codeblock|{
(pipe-to x f)    → (x |> f)
(pipe-from f x)  → (f <| x)
}|

@section{Derivations}

@tt{(derivation ATTRS)} is sugar for @tt{(pkgs.stdenv.mkDerivation ATTRS)}.
At compile time it rejects derivations without @tt{:pname} or @tt{:name}.
Override the default builder with @tt{:builder}:

@codeblock|{
(derivation {:pname "hello-rust"
             :version "0.1.0"
             :src (p "./src")
             :nativeBuildInputs [pkgs.rustc pkgs.cargo]
             :buildPhase ~"cargo build --release"
             :installPhase ~"install -Dm755 target/release/hello $out/bin/hello"})
}|

@section{Flakes}

@codeblock|{
(flake
  {:description "minimal flake"
   :inputs {:nixpkgs {:url "github:NixOS/nixpkgs/nixos-unstable"}}
   :outputs (module [self nixpkgs] {:packages.x86_64-linux.default nixpkgs.hello})})
}|

@section{Overlays}

@codeblock|{
(overlay [final prev]
  {:my-tool (prev.callPackage (p "./my-tool.nix") {})})
}|

@section{NixType — Module Option Type Values}

@tt{lib.types.bool}, @tt{lib.types.int}, etc. are typed as @tt{NixType} (an
opaque primitive). Parametric helpers like @tt{lib.types.listOf} have
signature @tt{[NixType -> NixType]}. Passing a @tt{Bool} literal where a
@tt{NixType} is expected is now a compile-time error:

@codeblock|{
(lib/mkOption {:type true})  ;; ❌ type error: expected NixType, got Bool
(lib/mkOption {:type lib/types.bool}) ;; ✓
}|

@section{Stdlib Coverage}

The Nix stdlib catalog (@tt{beagle-lib/private/stdlib-nix.rkt}) ships 280
typed entries:

@itemlist[
  @item{Full @tt{builtins.*}: arithmetic, paths, fetch*, hashing, JSON, attrsets}
  @item{Full @tt{lib.*}: mkIf/mkOption/mkOverride/mkDefault/mkForce, version helpers,
        string helpers, attrset helpers, module evaluation, overlay composition}
  @item{Full @tt{lib.types.*}: bool/str/int/float/path/package/port + listOf/attrsOf/
        nullOr/either/oneOf/submodule + ints.* sized integers}]

@section{Escape Hatch: unsafe-nix}

When you need to write raw Nix that beagle can't model (yet):

@codeblock|{
(unsafe-nix "pkgs.lib.fakeHash")
}|

The string is inserted verbatim. The checker won't validate it; the renamer
won't see references inside it. Treat as last resort.

@section{Validator}

The schema-driven validator (@tt{bin/beagle-validate}) reads
@tt{.nisp-cache/schema.json} and checks every option path + value type. Configure
with @tt{.nisp-cache/validate-config.json}:

@codeblock|{
{
  "homeManagerRoots": ["programs", "home", "xdg"],
  "freeformKeyPrefixes": ["boot.kernel.sysctl"],
  "typesNeedingDefault": ["lib/types.bool"]
}
}|

If @tt{homeManagerRoots} is absent, roots are auto-discovered from the loaded
HM schema's top-level prefixes.

@section{Nix-Aware Lint Warnings}

In strict mode (default), @tt{beagle/nix} files get extra lints beyond the
generic beagle ones:

@itemlist[
  @item{@tt{(lib/mkIf false ...)} → dead code}
  @item{@tt{(lib/mkIf true BODY)} → pointless wrapper}
  @item{@tt{(lib/mkIf X X)} → typo (body equals condition)}
  @item{@tt{lib/mkOption} with type @tt{lib/types.bool|int|str|float|path} but no @tt{:default} → will throw at eval time}
  @item{@tt{lib/mkOption} missing @tt{:description}}
  @item{@tt{(merge {} X)} / @tt{(merge X {})} / @tt{(concat [] X)} → no-op}
  @item{@tt{(s "literal")} with no interpolated parts → use a plain string literal}]

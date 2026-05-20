#lang scribble/manual

@title[#:tag "getting-started"]{Getting Started}

@section{Installation}

Install beagle as a linked Racket package:

@verbatim|{
  raco pkg install --link beagle-lib/ beagle-test/ beagle-doc/ beagle/
}|

If using Nix, the flake provides a dev shell:

@verbatim|{
  echo 'use flake' > .envrc && direnv allow
}|

@section{File Structure}

A beagle source file uses the @tt{#lang beagle} declaration:

@codeblock|{
#lang beagle

(ns example.demo)              ; namespace (default: beagle.user)
(define-mode strict)           ; default; or dynamic to skip type checks
(require some.module :as mod)  ; import types/fns from another beagle module
(declare-extern fn [A -> R])   ; only for Java interop or non-beagle fns
(import java.io.File)          ; Java class import

;; definitions follow...
(def greeting : String "hello")

(defn add [(x : Int) (y : Int)] : Int
  (+ x y))
}|

Meta forms (@tt{ns}, @tt{define-mode}, @tt{require}, @tt{declare-extern},
@tt{define-macro}, @tt{import}) can appear anywhere but conventionally
go at the top.

@section{Compiling and Checking}

@itemlist[
  @item{@tt{beagle check .} --- type-check all files in the current directory}
  @item{@tt{beagle build . --out .build/} --- compile beagle to Clojure source}
  @item{@tt{beagle fix --apply .} --- auto-fix mechanical type errors}
  @item{@tt{beagle sig fn-name .} --- query a function's type signature}
  @item{@tt{beagle repl} --- interactive REPL with type checking}
  @item{@tt{beagle lsp} --- LSP server for editor integration}
]

@section{Cross-Module Imports}

@tt{(require module :as alias)} imports all typed definitions, records,
scalars, and macros from another beagle module. No @tt{declare-extern}
is needed for cross-module beagle calls:

@codeblock|{
(require inventory :as inv)

;; Type checker knows: inv/can-fulfill? : [(Vec StockLevel) Int Int -> Bool]
(inv/can-fulfill? levels product-id qty)
}|

For non-beagle namespaces (Clojure libraries), use @tt{declare-extern}
for type-checked calls, or accept @tt{Any}-typed pass-through.

@section{Claude Code Integration}

For a one-command setup with Claude Code (hooks, daemon, context):

@verbatim|{
  beagle init --claude-code
}|

This creates:
@itemlist[
  @item{@tt{.claude/beagle-context.md} --- language reference for system context}
  @item{@tt{.claude/hooks/beagle-check.sh} --- PostToolUse hook for instant type feedback}
  @item{@tt{.claude/settings.json} --- hook wiring}
  @item{@tt{CLAUDE.md} --- project instructions}
]

Then start the daemon: @tt{beagle-daemon start --watch .}

Without @tt{--claude-code}, @tt{beagle init} only creates the context file.

@section{Viewing Documentation}

After installation, view these docs locally:

@verbatim|{
  raco docs beagle
}|

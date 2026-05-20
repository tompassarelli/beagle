#lang scribble/manual

@(require (for-label racket/base))

@title{Beagle: Typed Clojure Authoring}
@author{Tom Passarelli}

@defmodule[beagle #:lang]

Beagle is a typed authoring layer that compiles to Clojure. It provides
compile-time type checking, arity validation, and structured error diagnostics
while emitting plain Clojure source for runtime.

@bold{Design goals:} Rich types, explicit forms, low syntactic surface area,
structured errors. One canonical idiom per concept. LLM authoring is a
first-class concern.

@bold{What the checker catches at compile time:}
@itemlist[
  @item{Type mismatches --- passing an @tt{Int} where a @tt{String} is expected}
  @item{Arity errors --- wrong number of arguments to a function}
  @item{Undefined references --- using a name that hasn't been defined}
  @item{Record field errors --- accessing a field that doesn't exist on a record type}
  @item{Cross-module contract violations --- imported function signatures enforced at call sites}
  @item{Refinement violations --- literal values outside declared bounds (e.g., @tt{(->Percentage 150)} when max is 100)}
]

@table-of-contents[]

@include-section["getting-started.scrbl"]
@include-section["forms.scrbl"]
@include-section["types.scrbl"]
@include-section["records.scrbl"]
@include-section["control-flow.scrbl"]
@include-section["iteration.scrbl"]
@include-section["interop.scrbl"]
@include-section["macros.scrbl"]
@include-section["tools.scrbl"]

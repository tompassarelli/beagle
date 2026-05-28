// nix-parse-json: lossless Nix parser using rnix.
//
// Reads a .nix file path as a single argv, parses with rnix, and writes
// an S-expression representation of the AST to stdout. The S-expression
// shape matches what beagle-import-nix's parse-normalized previously
// produced (so the Racket-side emit-bnix continues to work unchanged
// except for one structural change: `(interp ...)` payloads are now
// full sub-ASTs instead of raw substrings).
//
// Exit code: 0 on success, 1 on parse errors (errors printed to stderr).

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::process::ExitCode;

use rnix::ast::{self, AstToken, HasEntry};
use rnix::Root;
use rowan::ast::AstNode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: nix-parse-json FILE");
        return ExitCode::from(2);
    }
    let path = &args[1];
    let source = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("nix-parse-json: cannot read {}: {}", path, e);
            return ExitCode::from(1);
        }
    };

    let parse = Root::parse(&source);
    let errors = parse.errors();
    if !errors.is_empty() {
        for err in errors {
            eprintln!("nix-parse-json: parse error: {}", err);
        }
        return ExitCode::from(1);
    }
    let root = parse.tree();
    let expr = match root.expr() {
        Some(e) => e,
        None => {
            eprintln!("nix-parse-json: empty source");
            return ExitCode::from(1);
        }
    };

    let mut out = String::new();
    emit_expr(&expr, &mut out);
    out.push('\n');
    print!("{}", out);
    ExitCode::SUCCESS
}

fn emit_expr(expr: &ast::Expr, out: &mut String) {
    match expr {
        ast::Expr::Paren(p) => {
            if let Some(inner) = p.expr() {
                emit_expr(&inner, out);
            } else {
                out.push_str("(null)");
            }
        }
        ast::Expr::Ident(i) => {
            let name = i.ident_token().map(|t| t.text().to_string()).unwrap_or_default();
            match name.as_str() {
                "true" => out.push_str("(bool #t)"),
                "false" => out.push_str("(bool #f)"),
                "null" => out.push_str("(null)"),
                _ => {
                    out.push_str("(id ");
                    emit_nix_ident(&name, out);
                    out.push(')');
                }
            }
        }
        ast::Expr::Literal(l) => emit_literal(l, out),
        ast::Expr::Path(p) => {
            let text = p.syntax().text().to_string();
            out.push_str("(path ");
            emit_racket_string(&text, out);
            out.push(')');
        }
        ast::Expr::Apply(a) => {
            out.push_str("(apply ");
            if let Some(f) = a.lambda() {
                emit_expr(&f, out);
            } else {
                out.push_str("(null)");
            }
            out.push(' ');
            if let Some(arg) = a.argument() {
                emit_expr(&arg, out);
            } else {
                out.push_str("(null)");
            }
            out.push(')');
        }
        ast::Expr::Lambda(l) => emit_lambda(l, out),
        ast::Expr::LetIn(l) => {
            out.push_str("(let (");
            let mut first = true;
            for entry in l.entries() {
                if !first {
                    out.push(' ');
                }
                first = false;
                emit_entry(&entry, out);
            }
            out.push_str(") ");
            if let Some(body) = l.body() {
                emit_expr(&body, out);
            } else {
                out.push_str("(null)");
            }
            out.push(')');
        }
        ast::Expr::With(w) => {
            out.push_str("(with ");
            if let Some(ns) = w.namespace() {
                emit_expr(&ns, out);
            } else {
                out.push_str("(null)");
            }
            out.push(' ');
            if let Some(body) = w.body() {
                emit_expr(&body, out);
            } else {
                out.push_str("(null)");
            }
            out.push(')');
        }
        ast::Expr::IfElse(ie) => {
            out.push_str("(if ");
            if let Some(c) = ie.condition() {
                emit_expr(&c, out);
            } else {
                out.push_str("(null)");
            }
            out.push(' ');
            if let Some(t) = ie.body() {
                emit_expr(&t, out);
            } else {
                out.push_str("(null)");
            }
            out.push(' ');
            if let Some(e) = ie.else_body() {
                emit_expr(&e, out);
            } else {
                out.push_str("(null)");
            }
            out.push(')');
        }
        ast::Expr::AttrSet(s) => emit_attrset(s, out),
        ast::Expr::List(l) => {
            out.push_str("(list (");
            let mut first = true;
            for item in l.items() {
                if !first {
                    out.push(' ');
                }
                first = false;
                emit_expr(&item, out);
            }
            out.push_str("))");
        }
        ast::Expr::Str(s) => emit_str(s, out),
        ast::Expr::BinOp(b) => emit_binop(b, out),
        ast::Expr::UnaryOp(u) => emit_unop(u, out),
        ast::Expr::HasAttr(h) => {
            out.push_str("(has-attr ");
            if let Some(e) = h.expr() {
                emit_expr(&e, out);
            } else {
                out.push_str("(null)");
            }
            out.push_str(" (");
            if let Some(ap) = h.attrpath() {
                let mut first = true;
                for attr in ap.attrs() {
                    if !first {
                        out.push(' ');
                    }
                    first = false;
                    emit_attr(&attr, out);
                }
            }
            out.push_str("))");
        }
        ast::Expr::Select(s) => emit_select(s, out),
        ast::Expr::Assert(a) => {
            // Map `assert cond; body` to `(assert cond body)`.
            // Racket emit side handles it via emit-expr's match.
            out.push_str("(assert ");
            if let Some(c) = a.condition() {
                emit_expr(&c, out);
            } else {
                out.push_str("(null)");
            }
            out.push(' ');
            if let Some(b) = a.body() {
                emit_expr(&b, out);
            } else {
                out.push_str("(null)");
            }
            out.push(')');
        }
        ast::Expr::LegacyLet(_) => {
            // `let { ... }` form — rare, treat as error for now.
            eprintln!("nix-parse-json: legacy let form not supported");
            out.push_str("(null)");
        }
        ast::Expr::Error(_) => {
            out.push_str("(null)");
        }
        ast::Expr::Root(_) => unreachable!("root inside expr"),
    }
}

fn emit_literal(l: &ast::Literal, out: &mut String) {
    match l.kind() {
        ast::LiteralKind::Float(f) => {
            let v = f.value().unwrap_or(0.0);
            // Emit so Racket reads it back as inexact.
            if v.fract() == 0.0 && v.is_finite() {
                write!(out, "(float {:.1})", v).unwrap();
            } else {
                write!(out, "(float {})", v).unwrap();
            }
        }
        ast::LiteralKind::Integer(i) => {
            write!(out, "(int {})", i.value().unwrap_or(0)).unwrap();
        }
        ast::LiteralKind::Uri(u) => {
            // Nix URIs (deprecated bare http://...) — treat as string.
            let text = u.syntax().text().to_string();
            out.push_str("(str-lit ");
            emit_racket_string(&text, out);
            out.push(')');
        }
    }
}

fn emit_str(s: &ast::Str, out: &mut String) {
    // Distinguish indented `''...''` from regular `"..."` by raw source.
    // The escape rules differ — ''$ for literal $, '' for literal ', etc. —
    // so nix-instantiate --parse produces a different AST for each shape
    // when the content contains $ or '. The importer needs to know the
    // original delimiter to emit (ms ...) vs (s ...).
    let raw = s.syntax().text().to_string();
    let indented = raw.starts_with("''");
    let (lit_tag, interp_tag) = if indented {
        ("str-lit-ind", "str-interp-ind")
    } else {
        ("str-lit", "str-interp")
    };

    let parts = s.normalized_parts();
    if parts.is_empty() {
        out.push_str(&format!("({} \"\")", lit_tag));
        return;
    }
    let all_literal = parts.iter().all(|p| matches!(p, ast::InterpolPart::Literal(_)));
    if all_literal {
        let mut buf = String::new();
        for p in &parts {
            if let ast::InterpolPart::Literal(s) = p {
                buf.push_str(s);
            }
        }
        out.push_str(&format!("({} ", lit_tag));
        emit_racket_string(&buf, out);
        out.push(')');
        return;
    }
    out.push_str(&format!("({} (", interp_tag));
    let mut first = true;
    for p in &parts {
        if !first {
            out.push(' ');
        }
        first = false;
        match p {
            ast::InterpolPart::Literal(s) => {
                emit_racket_string(s, out);
            }
            ast::InterpolPart::Interpolation(i) => {
                out.push_str("(interp ");
                if let Some(e) = i.expr() {
                    emit_expr(&e, out);
                } else {
                    out.push_str("(null)");
                }
                out.push(')');
            }
        }
    }
    out.push_str("))");
}

fn emit_lambda(l: &ast::Lambda, out: &mut String) {
    let body = l.body();
    let param = l.param();
    out.push_str("(lambda ");
    match param {
        Some(ast::Param::IdentParam(ip)) => {
            let name = ip
                .ident()
                .and_then(|i| i.ident_token())
                .map(|t| t.text().to_string())
                .unwrap_or_default();
            out.push_str("(single ");
            emit_nix_ident(&name, out);
            out.push(')');
        }
        Some(ast::Param::Pattern(p)) => {
            let entries: Vec<_> = p.pat_entries().collect();
            let ellipsis = p.ellipsis_token().is_some();
            let bind = p.pat_bind();
            // Determine whether the bind is BEFORE or AFTER the brace pattern.
            // In rnix, the bind token appears as a child of the pattern; check
            // text-offset against the opening curly to tell `name@{...}` from
            // `{...}@name`.
            let position = if let Some(b) = &bind {
                let b_offset = b
                    .syntax()
                    .text_range()
                    .start();
                let p_offset = p.syntax().text_range().start();
                if b_offset < p_offset {
                    "before"
                } else {
                    "after"
                }
            } else {
                ""
            };
            let formals_text = format_formals(&entries, ellipsis);
            if let Some(b) = bind {
                let alias = b
                    .ident()
                    .and_then(|i| i.ident_token())
                    .map(|t| t.text().to_string())
                    .unwrap_or_default();
                out.push_str("(formals-at ");
                emit_nix_ident(&alias, out);
                out.push(' ');
                out.push_str(&formals_text);
                out.push(' ');
                out.push_str(position);
                out.push(')');
            } else {
                out.push_str("(formals ");
                out.push_str(&formals_text);
                out.push(')');
            }
        }
        None => {
            out.push_str("(single _)");
        }
    }
    out.push(' ');
    if let Some(b) = body {
        emit_expr(&b, out);
    } else {
        out.push_str("(null)");
    }
    out.push(')');
}

fn format_formals(entries: &[ast::PatEntry], ellipsis: bool) -> String {
    let mut s = String::from("(("); // outer wrap: (args ellipsis?)
    let mut first = true;
    for e in entries {
        if !first {
            s.push(' ');
        }
        first = false;
        s.push('(');
        let name = e
            .ident()
            .and_then(|i| i.ident_token())
            .map(|t| t.text().to_string())
            .unwrap_or_default();
        let mut tmp = String::new();
        emit_nix_ident(&name, &mut tmp);
        s.push_str(&tmp);
        s.push(' ');
        if let Some(default) = e.default() {
            let mut buf = String::new();
            emit_expr(&default, &mut buf);
            s.push_str(&buf);
        } else {
            s.push_str("#f");
        }
        s.push(')');
    }
    s.push(')');
    s.push(' ');
    s.push_str(if ellipsis { "#t" } else { "#f" });
    s.push(')');
    s
}

fn emit_attrset(s: &ast::AttrSet, out: &mut String) {
    let is_rec = s.rec_token().is_some();
    out.push_str(if is_rec { "(rec-attrset (" } else { "(attrset (" });
    let mut first = true;
    for entry in s.entries() {
        if !first {
            out.push(' ');
        }
        first = false;
        emit_entry(&entry, out);
    }
    out.push_str("))");
}

fn emit_entry(entry: &ast::Entry, out: &mut String) {
    match entry {
        ast::Entry::AttrpathValue(av) => {
            out.push_str("(bind (");
            if let Some(ap) = av.attrpath() {
                let mut first = true;
                for attr in ap.attrs() {
                    if !first {
                        out.push(' ');
                    }
                    first = false;
                    emit_attr(&attr, out);
                }
            }
            out.push_str(") ");
            if let Some(v) = av.value() {
                emit_expr(&v, out);
            } else {
                out.push_str("(null)");
            }
            out.push(')');
        }
        ast::Entry::Inherit(i) => {
            let from = i.from();
            if let Some(f) = from {
                out.push_str("(inherit-from ");
                if let Some(e) = f.expr() {
                    emit_expr(&e, out);
                } else {
                    out.push_str("(null)");
                }
                out.push_str(" (");
                let mut first = true;
                for a in i.attrs() {
                    if !first {
                        out.push(' ');
                    }
                    first = false;
                    emit_inherit_attr(&a, out);
                }
                out.push_str("))");
            } else {
                out.push_str("(inherit (");
                let mut first = true;
                for a in i.attrs() {
                    if !first {
                        out.push(' ');
                    }
                    first = false;
                    emit_inherit_attr(&a, out);
                }
                out.push_str("))");
            }
        }
    }
}

fn emit_attr(attr: &ast::Attr, out: &mut String) {
    match attr {
        ast::Attr::Ident(i) => {
            let name = i
                .ident_token()
                .map(|t| t.text().to_string())
                .unwrap_or_default();
            // Emit as quoted string — Racket-side parsing expects strings
            // for attr-path segments (it stringly-distinguishes ident
            // segments from `(str ...)` and dynamic forms).
            emit_racket_string(&name, out);
        }
        ast::Attr::Str(s) => {
            let parts = s.normalized_parts();
            out.push_str("(str (");
            let mut first = true;
            for p in &parts {
                if !first {
                    out.push(' ');
                }
                first = false;
                match p {
                    ast::InterpolPart::Literal(t) => {
                        emit_racket_string(t, out);
                    }
                    ast::InterpolPart::Interpolation(i) => {
                        out.push_str("(interp ");
                        if let Some(e) = i.expr() {
                            emit_expr(&e, out);
                        } else {
                            out.push_str("(null)");
                        }
                        out.push(')');
                    }
                }
            }
            out.push_str("))");
        }
        ast::Attr::Dynamic(d) => {
            // ${expr} as a key — represent as str with a single interp part.
            out.push_str("(str ((interp ");
            if let Some(e) = d.expr() {
                emit_expr(&e, out);
            } else {
                out.push_str("(null)");
            }
            out.push_str(")))");
        }
    }
}

fn emit_inherit_attr(attr: &ast::Attr, out: &mut String) {
    // Inherit lists carry Nix identifiers (Racket parses them as symbols
    // downstream; emit-binding consumes them via symbol->string).
    match attr {
        ast::Attr::Ident(i) => {
            let name = i
                .ident_token()
                .map(|t| t.text().to_string())
                .unwrap_or_default();
            emit_nix_ident(&name, out);
        }
        ast::Attr::Str(s) => {
            let mut buf = String::new();
            for p in s.normalized_parts() {
                if let ast::InterpolPart::Literal(t) = p {
                    buf.push_str(&t);
                }
            }
            emit_nix_ident(&buf, out);
        }
        ast::Attr::Dynamic(_) => {
            // Dynamic inherits don't really make sense in Nix; skip.
        }
    }
}

fn emit_select(s: &ast::Select, out: &mut String) {
    let target = s.expr();
    let attrs: Vec<_> = s
        .attrpath()
        .map(|ap| ap.attrs().collect())
        .unwrap_or_default();
    let default = s.default_expr();
    if let Some(d) = default {
        out.push_str("(select-or ");
        if let Some(t) = target {
            emit_expr(&t, out);
        } else {
            out.push_str("(null)");
        }
        out.push_str(" (");
        let mut first = true;
        for a in &attrs {
            if !first {
                out.push(' ');
            }
            first = false;
            emit_attr(a, out);
        }
        out.push_str(") ");
        emit_expr(&d, out);
        out.push(')');
    } else {
        out.push_str("(select ");
        if let Some(t) = target {
            emit_expr(&t, out);
        } else {
            out.push_str("(null)");
        }
        out.push_str(" (");
        let mut first = true;
        for a in &attrs {
            if !first {
                out.push(' ');
            }
            first = false;
            emit_attr(a, out);
        }
        out.push_str("))");
    }
}

fn emit_binop(b: &ast::BinOp, out: &mut String) {
    let op = b.operator().map(binop_str).unwrap_or("?");
    out.push_str("(binop ");
    emit_racket_string(op, out);
    out.push(' ');
    if let Some(l) = b.lhs() {
        emit_expr(&l, out);
    } else {
        out.push_str("(null)");
    }
    out.push(' ');
    if let Some(r) = b.rhs() {
        emit_expr(&r, out);
    } else {
        out.push_str("(null)");
    }
    out.push(')');
}

fn binop_str(op: ast::BinOpKind) -> &'static str {
    use ast::BinOpKind::*;
    match op {
        Concat => "++",
        Update => "//",
        Add => "+",
        Sub => "-",
        Mul => "*",
        Div => "/",
        And => "&&",
        Or => "||",
        Implication => "->",
        Equal => "==",
        NotEqual => "!=",
        Less => "<",
        LessOrEq => "<=",
        More => ">",
        MoreOrEq => ">=",
    }
}

fn emit_unop(u: &ast::UnaryOp, out: &mut String) {
    use ast::UnaryOpKind::*;
    let op = match u.operator() {
        Some(Invert) => "!",
        Some(Negate) => "-",
        None => "?",
    };
    out.push_str("(unop ");
    emit_racket_string(op, out);
    out.push(' ');
    if let Some(e) = u.expr() {
        emit_expr(&e, out);
    } else {
        out.push_str("(null)");
    }
    out.push(')');
}

fn emit_racket_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                write!(out, "\\u{:04x}", c as u32).unwrap();
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn emit_nix_ident(name: &str, out: &mut String) {
    // Nix identifiers allow chars that Racket's reader treats specially
    // (notably `'` which acts as a quote prefix mid-symbol — e.g.
    // `mapAttrs'` reads as `mapAttrs` followed by `'(quote ...)`).
    // Always emit Nix identifiers using `|...|` bar-quoting so the
    // Racket reader returns them as a single symbol regardless of
    // character content.
    if name.is_empty() {
        out.push_str("||");
        return;
    }
    // ASCII identifiers without special chars don't need bars; emit
    // bare for readability when safe.
    let safe = name.chars().all(|c| {
        c.is_ascii_alphanumeric() || c == '_' || c == '-'
    });
    if safe && name.chars().next().map_or(false, |c| c.is_alphabetic() || c == '_') {
        out.push_str(name);
    } else {
        out.push('|');
        for c in name.chars() {
            if c == '|' || c == '\\' {
                out.push('\\');
            }
            out.push(c);
        }
        out.push('|');
    }
}

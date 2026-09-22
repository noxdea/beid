# ADR 002: HTML comments as directives

- Status: Accepted
- Date: 2026-09-23

## Context

Applications built on Markdown need lightweight metadata without introducing a custom block syntax that ordinary Markdown tools cannot preserve.

## Decision

Beid recognizes a standalone HTML comment containing one `key: value` pair, such as `<!-- layout: two-column -->`, as a directive. It also retains `::: name` fenced div blocks as source-positioned directive nodes, without interpreting their contents.

## Consequences

Directive metadata remains valid Markdown and round-trips unchanged. YAML and directive values are not evaluated; applications define their meaning. Beid's directive helper deliberately handles one key-value pair per HTML comment.

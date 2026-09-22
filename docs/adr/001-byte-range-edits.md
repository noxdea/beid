# ADR 001: Byte-range edits instead of AST reserialization

- Status: Accepted
- Date: 2026-09-23

## Context

Beid is meant to support editing Markdown documents without changing untouched formatting. Rebuilding source from a parsed tree would normalize markers, spacing, line endings, and syntax Beid does not understand.

## Decision

Each node keeps a half-open byte range into an immutable source snapshot. Editing operations splice only that range and reparse the result; `Document#to_s` returns the stored source verbatim.

## Consequences

Unedited bytes remain unchanged, including syntax outside Beid's supported subset. Consumers must use a node from the same document snapshot and reparse after edits; ranges from an earlier document are not reusable.

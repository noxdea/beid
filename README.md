# Beid

Beid (ο¹ Eridani; Arabic *bayḍ*, “egg”) parses Markdown into a source-positioned tree and edits the original bytes in place. It is intended for applications that need to update part of a Markdown document without normalizing untouched formatting.

Beid uses Ruby's standard library at runtime and supports Ruby 3.1 and later.

## Installation

```ruby
gem "beid"
```

## Usage

```ruby
require "beid"

source = "# Title\n\nKeep this *formatting*.\n"
document = Beid::Document.parse(source)
paragraph = document.root.children.find { |node| node.type == :paragraph }

updated = Beid::Editing.replace_text(document, paragraph, "A new sentence.")
puts updated
# # Title
#
# A new sentence.
```

`Document#source` and `#to_s` return the exact source string. Node ranges and all offsets are half-open byte ranges in that original UTF-8 string. `position_at` returns zero-based line and Unicode-codepoint column; `utf16_position_at` returns a zero-based LSP position. `nodes_at` returns the document-to-deepest-node path at a byte offset.

`Beid::Editing` provides `replace`, `replace_text`, `insert_before`, `insert_after`, `remove`, `set_attribute`, `set_directive`, and `move`. Each operation returns a new parsed `Document`; the original remains unchanged. Edits splice only the requested byte range. Replacements are reparsed, and nodes from another document are rejected.

```ruby
heading = document.root.children.first
updated = Beid::Editing.set_attribute(document, heading, :level, 2)
```

`Document.parse(text, gfm: true, front_matter: true)` retains YAML front matter as raw text, recognizes HTML-comment directives (`<!-- layout: two-column -->`), fenced code blocks, headings, paragraphs, nested lists, block quotes, tables, task-list items, strikethrough, and footnote references/definitions. `::: name` fenced divs are retained as directive nodes. Inline nodes include emphasis, strong emphasis, inline and reference links, autolinks, images, code spans, and text. Reference definitions are retained as `:link_definition` nodes and resolved link nodes carry their destination and source ranges.

Beid does not evaluate YAML or render HTML. It is not yet a complete CommonMark/GFM implementation: unsupported or ambiguous syntax may be represented as plain text or raw HTML. The official CommonMark 0.31.2 fixture is bundled under `spec/fixtures/commonmark`; CI verifies exact source round-tripping and node byte ranges, and reports top-level block-shape plus reference-link, autolink, and nested-list recognition metrics. These AST-shape proxies are not semantic/rendered-HTML conformance, so the design's 95% semantic conformance gate remains open until a defensible independent semantic comparison is available. Regardless of parser coverage, `Document#to_s` is an exact round trip because serialization returns the original source rather than regenerating Markdown from the tree. Treat the tree as a best-effort editing view and keep application-level edits within recognized node ranges.

## Development

```sh
bundle install
bundle exec rake
bundle exec rbs -I sig validate
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).

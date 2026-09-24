<h1 align="center">Beid</h1>

<p align="center">
  <strong>Source-preserving Markdown parser and editor with exact byte-range edits</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/beid"><img src="https://img.shields.io/gem/v/beid.svg" alt="Gem version"></a>
  <a href="https://github.com/noxdea/beid/actions/workflows/main.yml"><img src="https://github.com/noxdea/beid/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Ruby-%3E%3D%203.1-cc342d.svg" alt="Ruby 3.1 or newer">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#editing-api">Editing API</a> ·
  <a href="#limits">Limits</a>
</p>

---

Beid parses Markdown into source-positioned nodes and edits the original bytes
without normalizing untouched formatting. It is for editors and document tools
that need precise changes while preserving a user's Markdown. It uses only
Ruby's standard library at runtime. Its name comes from Arabic *bayḍ*, “egg”
(ο¹ Eridani).

## Features

- Exact source round trips: `Document#to_s` returns the original Markdown, not regenerated output
- Half-open byte ranges for nodes, plus Unicode and LSP UTF-16 positions
- Immutable editing operations that reparse only after splicing the requested source range
- CommonMark and GFM-oriented parsing with front matter, tables, task lists, links, and directives

## Installation

```sh
gem install beid
```

Beid requires Ruby 3.1 or newer. With Bundler, add `gem "beid"` to your Gemfile.

## Quick start

```ruby
require "beid"

source = "# Title\n\nKeep this *formatting*.\n"
document = Beid::Document.parse(source)
heading = document.root.children.first

updated = Beid::Editing.set_attribute(document, heading, :level, 2)
puts updated.to_s
# ## Title
#
# Keep this *formatting*.
```

`updated` is a new document; `document` and its original source are unchanged.

## Editing API

Use `Document#nodes_at` to find the path from the document root to the deepest
node at a byte offset. `Document#position_at` returns a zero-based line and
Unicode-codepoint column; `#utf16_position_at` returns the corresponding LSP
position. Ranges are half-open byte ranges in the original UTF-8 source.

`Beid::Editing` supports `replace`, `replace_text`, `insert_before`,
`insert_after`, `remove`, `set_attribute`, `set_directive`, and `move`. Each
operation returns a newly parsed document. Nodes from a different document are
rejected.

`Document.parse(text, gfm: true, front_matter: true)` retains YAML front matter
as raw text and recognizes headings, paragraphs, lists, block quotes, fenced
code, tables, task lists, strikethrough, footnotes, links, images, and code
spans. It also retains HTML-comment directives such as
`<!-- layout: two-column -->` and `::: name` fenced divs. Reference definitions
are kept as `:link_definition` nodes.

## Limits

Beid does not evaluate YAML or render HTML. Its parse tree is a best-effort
editing view, not a complete CommonMark/GFM implementation: unsupported or
ambiguous syntax may appear as plain text or raw HTML. Keep edits within
recognized node ranges. Exact round-tripping does not depend on parser coverage
because Beid returns the original source rather than reserializing the tree.

The test suite covers all 652 official CommonMark 0.31.2 examples for exact
source round trips and valid node ranges. Its test-only semantic HTML comparison
currently agrees on 620/652 examples (95.1%); CI reports the remaining cases
by section. Nokogiri is used only for that test oracle, not at runtime.

## Documentation

- [Byte-range editing decision](docs/adr/001-byte-range-edits.md)
- [HTML-comment directive decision](docs/adr/002-html-comment-directives.md)

## Development

```sh
bundle install
bundle exec rake
bundle exec rbs -I sig validate
```

## License

Beid is released under the [MIT License](LICENSE.txt).

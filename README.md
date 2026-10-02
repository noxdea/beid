<h1 align="center">Beid</h1>

<p align="center">
  <strong>Source-preserving Markdown parser and editor with exact byte-range edits</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/beid"><img src="https://img.shields.io/gem/v/beid.svg" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/beid"><img src="https://img.shields.io/gem/dt/beid.svg" alt="Gem downloads"></a>
  <a href="https://github.com/noxdea/beid/actions/workflows/main.yml"><img src="https://github.com/noxdea/beid/actions/workflows/main.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="beid.gemspec"><img src="https://img.shields.io/badge/Ruby-%3E%3D%203.1-cc342d.svg" alt="Ruby 3.1 or newer"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://noxdea.github.io/beid/">Website</a> ·
  <a href="https://noxdea.github.io/beid/docs/">User Guide</a> ·
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick start</a>
</p>

---

Beid parses Markdown into source-positioned nodes and edits the original bytes
without normalizing untouched formatting. It is for editors and document tools
that need precise changes while preserving a user's Markdown. It uses only
Ruby's standard library at runtime. Its name comes from Arabic *bayḍ*, “egg”
(ο¹ Eridani).

## Features

- Preserve spacing, markers, line endings, and unsupported syntax with exact source round trips.
- Find nodes by byte offset and read half-open ranges, Unicode positions, or LSP UTF-16 positions.
- Replace, insert, remove, or move content; each edit returns a new document.
- Inspect CommonMark and GFM-oriented nodes, including tables, task lists, links, and footnotes.
- Keep front matter and HTML-comment directives as raw metadata without evaluating them.

## Installation

```sh
gem install beid
```

Beid requires Ruby 3.1 or newer. With Bundler, add this to your Gemfile and run
`bundle install`:

```ruby
gem "beid"
```

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
Find nodes again in `updated` before making another edit. See
[Getting started](https://noxdea.github.io/beid/docs/) for reading and saving a file.

## Editing API

Use `Document#nodes_at` to find the path from the document root to the deepest
node at a byte offset. `Document#position_at` returns a zero-based line and
Unicode-codepoint column; `#utf16_position_at` returns the corresponding LSP
position. Ranges are half-open byte ranges in the original UTF-8 source.

`Beid::Editing` supports `replace`, `replace_text`, `insert_before`,
`insert_after`, `remove`, `set_attribute`, `set_directive`, and `move`. Each
operation returns a newly parsed document. Nodes from a different document are
rejected, including nodes from a previous edit. Use `replace` for Markdown
syntax and `replace_text` to change text while retaining its surrounding markers.

`Document.parse(text, gfm: true, front_matter: true)` retains YAML front matter
as raw text and recognizes headings, paragraphs, lists, block quotes, fenced
code, tables, task lists, strikethrough, footnotes, links, images, and code
spans. It also retains HTML-comment directives such as
`<!-- layout: two-column -->` and `::: name` fenced divs. Reference definitions
are kept as `:link_definition` nodes.

See the [User guide](https://noxdea.github.io/beid/docs/usage.html) for runnable
examples, parser options, node lookup, editing operations, and directives.

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
See [Validation and limits](https://noxdea.github.io/beid/docs/usage.html#validation-and-limits)
before relying on the tree for automated edits.

## Documentation

- [Getting started](https://noxdea.github.io/beid/docs/)
- [User guide and editing API](https://noxdea.github.io/beid/docs/usage.html)
- [Byte offsets and editor positions](https://noxdea.github.io/beid/docs/usage.html#byte-offsets-and-editor-positions)
- [Development](https://noxdea.github.io/beid/docs/development.html)
- [Byte-range editing decision](docs/adr/001-byte-range-edits.md)
- [HTML-comment directive decision](docs/adr/002-html-comment-directives.md)
- [Changelog](CHANGELOG.md)

## Development

```sh
bundle install
bundle exec rake
bundle exec rbs -I sig validate
```

The [development guide](https://noxdea.github.io/beid/docs/development.html)
explains the test suite and how to preview the website locally.

## License

Beid is released under the [MIT License](LICENSE.txt).

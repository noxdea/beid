---
title: User guide
description: Beid's parser options, nodes, byte and UTF-16 positions, immutable editing API, directives, and current limits.
---

# User guide

Beid keeps the original Markdown as an immutable source snapshot. Nodes describe
recognized syntax and its source ranges; editing operations splice those ranges
and return a newly parsed document. All examples below are independent Ruby snippets.

## On this page
{:.no_toc}

* Contents
{:toc}

## Parse Markdown

```ruby
require "beid"

source = "# Notes\n\nA **bold** paragraph.\n"
document = Beid::Document.parse(source)
document.to_s == source # => true
document.root.children.map(&:type) # => [:heading, :paragraph]
document.options # => {gfm: true, front_matter: true}
```

`Document.parse` requires a `String`. Use UTF-8 source for Unicode positions and
editor integrations. The input is copied and frozen, so changing the original
string later does not change the document.

| Option | Default | Behavior |
| --- | --- | --- |
| `gfm` | `true` | Recognize extensions such as tables, task lists, strikethrough, and footnotes. |
| `front_matter` | `true` | Recognize an initial `---` block terminated by `---` or `...`, retaining its contents as raw text. |

Pass `gfm: false, front_matter: false` to disable those extensions. HTML-comment
directives and fenced divs are recognized independently of these options.
Every editing operation retains the document's parser options.

## Inspect nodes and source ranges

The root is a `:document` node. Its `children` hold blocks such as `:heading`,
`:paragraph`, `:list`, `:ordered_list`, `:block_quote`, `:code_block`, and
`:thematic_break`. Inline children include `:text`, `:emphasis`, `:strong`,
`:link`, `:image`, and `:code_span`.

```ruby
require "beid"

document = Beid::Document.parse("# **bold**\n")
heading = document.root.children.first
heading.type # => :heading
heading.attributes[:level] # => 1
heading.marker # => "#"
heading.children.map(&:type) # => [:strong]
heading.range # => 0...11
document.range_of(heading) # => 0...11
document.source.byteslice(heading.range) # => "# **bold**\n"
```

| Node property | Meaning |
| --- | --- |
| `type` | Syntax kind as a symbol. |
| `attributes` | Syntax-specific values, such as a heading's `:level` or a link's `:destination`, and any editable subranges. |
| `children` | Nested nodes in source order. |
| `range` | Half-open byte range in the original source: the start is included, the end is excluded. |
| `marker` | Retained syntax marker, or `nil` when there is no marker. |
| `text` | The `:text` attribute when present; other nodes may return `nil`. |

Nodes, their children, and attributes are frozen. Use `document.source.byteslice`
to read exact Markdown for any node. `node.text` is a parsed value and may have
escapes or code-span whitespace normalized; it is not a substitute for source.
Use `document.range_of(node)` when you also need to verify that the node belongs
to this document, or `document.include_node?(node)` for a boolean check.

## Find nodes by byte offset

```ruby
require "beid"

document = Beid::Document.parse("# **bold**\n")
offset = document.source.b.index("bold")
document.nodes_at(offset).map(&:type) # => [:document, :heading, :strong, :text]
document.node_at(offset).type # => :text
document.nodes_at(document.source.bytesize) # => []
document.node_at(document.source.bytesize) # => nil
```

`nodes_at` returns the path from the root to the deepest containing node.
`node_at` returns its last node, or `nil` when no node contains the offset.
An offset on a blank line can return only the root.

Calculate offsets in bytes: `source.b.index(text.b)` and `prefix.bytesize` are
useful. Ruby's ordinary `String#index` and `String#length` count characters in
UTF-8 strings, which differs from byte offsets when non-ASCII text precedes a match.

`nodes_at` raises `RangeError` for a non-integer offset, an offset outside
`0..source.bytesize`, or one that splits a UTF-8 character. `node_at` returns
`nil` for those invalid offsets. For an empty document, `nodes_at(0)` returns
the root; for a nonempty document, the end offset is outside its half-open range.

## Byte offsets and editor positions

`position_at` returns a zero-based `[line, Unicode-codepoint column]`.
`utf16_position_at` returns `[line, UTF-16 code-unit column]`, as used by LSP.
Both take byte offsets:

```ruby
require "beid"

document = Beid::Document.parse("a😀b\r\n次")
offset = "a😀".bytesize
offset # => 5
document.position_at(offset) # => [0, 2]
document.utf16_position_at(offset) # => [0, 3]
document.position_at(document.source.bytesize) # => [1, 1]
```

The emoji occupies four UTF-8 bytes, one Unicode codepoint, and two UTF-16 code
units. These columns are not visual widths or grapheme counts.
Unlike node lookup, position lookup accepts the end offset of a nonempty document.
Both position methods reject invalid offsets or split UTF-8 characters with
`RangeError`; invalid source encoding raises `EncodingError`.

## Edit Markdown

All public operations below take a document and nodes from that same document.
Each returns a new `Beid::Document`. After an edit, find nodes again in the result;
old nodes and byte ranges cannot be reused against a new source snapshot.

| Operation | What changes |
| --- | --- |
| `replace(document, node, markdown)` | Replace the node's source with Markdown. |
| `replace_text(document, node, text)` | Replace supported text content while retaining surrounding markers. |
| `insert_before(document, node, markdown)` | Insert Markdown before a node. |
| `insert_after(document, node, markdown)` | Insert Markdown after a node. |
| `remove(document, node)` | Remove the node's source range. |
| `set_attribute(document, node, key, value)` | Change a heading level or link/image destination. |
| `set_directive(document, node, key, value)` | Update the value in an HTML-comment directive. |
| `move(document, node, before: target)` | Move a node's exact source before another node. |
| `move(document, node, after: target)` | Move a node's exact source after another node. |

### Replace Markdown or text

Use `replace` when the replacement includes Markdown syntax:

```ruby
require "beid"

document = Beid::Document.parse("# Title\n\nA **bold** paragraph.\n")
paragraph = document.root.children.last
updated = Beid::Editing.replace(document, paragraph, "A _changed_ paragraph.")
updated.to_s # => "# Title\n\nA _changed_ paragraph.\n"
```

When a nonempty replacement has no final newline, `replace` retains the node's
original final line ending. An empty replacement removes the entire range.

Use `replace_text` to retain a node's outer syntax and escape inline punctuation
such as `*` and `[` in the replacement:

```ruby
require "beid"

document = Beid::Document.parse("# Title\n")
heading = document.root.children.first
updated = Beid::Editing.replace_text(document, heading, "A *literal* title")
updated.to_s # => "# A \\*literal\\* title\n"
```

Supported types are `:text`, `:heading`, `:paragraph`, `:footnote_definition`,
`:link`, `:image`, `:emphasis`, `:strong`, `:strikethrough`, and `:code_span`.
The operation replaces all inner content, so nested formatting within the
replaced region is removed. Link and image replacements change the label;
autolinks do not expose a replaceable label range. Code-span replacements grow
their backtick delimiters when needed. Other node types raise `ArgumentError`.

### Change heading levels and destinations

```ruby
require "beid"

document = Beid::Document.parse("# Title\n\n[Guide](https://old.example)\n")
heading = document.root.children.first
document = Beid::Editing.set_attribute(document, heading, :level, 2)

link = document.root.children.last.children.find { |node| node.type == :link }
document = Beid::Editing.set_attribute(document, link, :destination, "https://example.com/guide")
document.to_s # => "## Title\n\n[Guide](https://example.com/guide)\n"
```

ATX headings accept levels 1 through 6. Setext headings keep their underline
style: level 1 uses `=`, and levels 2 through 6 use `-`, which parses as level 2.
Use `replace` if you need to convert a Setext heading to an ATX heading.

Destination edits support inline links and images whose destination range is
inside the node. They escape parentheses, spaces, and backslashes, and reject
newlines or angle brackets. Reference links point to a destination range in a
separate `:link_definition` node; replace that definition to change the shared
destination. Editing it through the reference-use node raises `ArgumentError`
because the range is outside that node.

### Insert content

```ruby
require "beid"

document = Beid::Document.parse("- first\n- second\n")
item = document.root.children.first.children.first
updated = Beid::Editing.insert_after(document, item, "* inserted")
updated.to_s # => "- first\n- inserted\n- second\n"
```

List-item insertion adapts the supplied list marker to the existing item's
marker. Other nodes receive blank-line separators. Insertion uses the first
line-ending style found in the document, falling back to LF for an empty source.
Pass the content to insert without extra separators when using these helpers.

### Remove or move a node

```ruby
require "beid"

document = Beid::Document.parse("# Title\n\nBody.\n")
heading, paragraph = document.root.children

removed = Beid::Editing.remove(document, heading)
removed.to_s # => "\nBody.\n"

moved = Beid::Editing.move(document, heading, after: paragraph)
moved.to_s # => "\nBody.\n# Title\n"
```

`remove` deletes exactly the node range, leaving surrounding blank lines in
place. `move` copies the exact source bytes without adding separators or
reindentation. Check the returned source when moving content between blocks
or containers; adjacency can change how Markdown is parsed.
Specify exactly one of `before:` or `after:`. Moving relative to the same node
or to an overlapping node, including its parent or child, raises `ArgumentError`.

## Front matter and directives

Front matter is retained as raw text and is never evaluated as YAML:

```ruby
require "beid"

document = Beid::Document.parse("---\ntitle: Notes\n---\n\n# Notes\n")
document.front_matter # => "title: Notes\n"
front_matter = document.root.children.first
front_matter.type # => :front_matter
document.source.byteslice(front_matter.range) # => "---\ntitle: Notes\n---\n"
```

To change front matter, use `replace` with a complete replacement block,
including its opening and closing delimiters. Without a closed block at the
start, `front_matter` is `nil` and the source is parsed as ordinary Markdown.

A standalone HTML comment containing one `key: value` pair is a `:directive`:

```ruby
require "beid"

document = Beid::Document.parse("<!-- layout: one-column -->\n\n# Notes\n")
directive = document.root.children.first
directive.attributes[:values] # => {"layout" => "one-column"}
updated = Beid::Editing.set_directive(document, directive, :layout, "two-column")
updated.to_s # => "<!-- layout: two-column -->\n\n# Notes\n"

Beid::Directive.parse("<!-- layout: wide -->") # => {"layout" => "wide"}
Beid::Directive.render("layout" => "wide") # => "<!-- layout: wide -->"
```

`set_directive` updates an existing key. Changing the key or adding a second
key is unsupported; replace the entire comment when renaming it.
`Directive.render` accepts exactly one pair. Keys start with an ASCII letter and
may contain letters, digits, `_`, and `-`. Values cannot contain `-->` or a
newline. Ordinary comments return `nil` from `Directive.parse`.

Fenced divs such as `::: columns` followed by a closing `:::` are also directive
nodes, with `:kind => :div`, `:name`, and `:closed` attributes and parsed
children. `set_directive` supports HTML-comment directives only; use `replace`
for a fenced div. Applications define the meaning of all metadata.

## Validation and limits

`document.valid?` checks the source encoding and whether diagnostics are empty.
It does not certify CommonMark or GFM conformance. Malformed or unsupported
syntax can still produce a valid document whose content is retained as text
or raw HTML.

```ruby
require "beid"

source = "bad\xFF".force_encoding(Encoding::UTF_8)
document = Beid::Document.parse(source)
document.valid? # => false
document.diagnostics # => ["Source is not valid UTF-8"]
document.to_s.b == source.b # => true
```

Parsing retains invalid source bytes for inspection. Check `valid?` and inspect
`diagnostics` before editing. An editing operation that produces an invalid
document raises `Beid::Error`; no new document is returned.
The original document remains unchanged when an operation fails.

| Exception | Typical cause |
| --- | --- |
| `TypeError` | A non-string source or replacement, or a non-node passed to `range_of`. |
| `RangeError` | An invalid byte offset or an offset splitting a UTF-8 character. |
| `EncodingError` | Position lookup on invalid source encoding. |
| `ArgumentError` | A foreign or stale node, unsupported attribute, invalid heading level, directive, destination, or move target. |
| `KeyError` | An operation requires a subrange that the parsed node does not expose, such as an autolink label. |
| `Beid::Error` | The edited source fails the document's validity check. |

Beid does not render HTML, evaluate front matter, or guarantee a complete
CommonMark/GFM tree. Source preservation does not depend on parser coverage;
fine-grained edits do. Inspect the node and its ranges before applying changes
to syntax your application has not handled before.

Each edit reparses the entire resulting document. There is no incremental parser,
batch-edit transaction, or disk-writing API. File I/O and application-level
validation belong to the caller.

The suite checks exact round trips and valid ranges for all 652 official
CommonMark 0.31.2 examples. Its test-only semantic HTML comparison currently
matches 620/652 examples (95.1%). See the [development guide](development.md)
for running the suite and understanding that comparison.

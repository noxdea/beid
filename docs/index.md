---
title: Getting started
description: Install Beid, edit your first Markdown document, and read and save files without rewriting untouched source.
permalink: /docs/
---

# Getting started

Beid is a Ruby library for Markdown tools that need to change a document while
preserving its original formatting. Parse a source snapshot, choose a node,
and edit its source range. The result is a new document; the original stays unchanged.

## Install

Use Ruby 3.1 or newer:

```sh
gem install beid
```

For a Bundler project, add `gem "beid"` to your Gemfile and run `bundle install`.
Beid has no runtime dependencies beyond Ruby's standard library. It is a library;
there is no command-line editor to launch.

## Make your first edit

Save this as `example.rb` and run `ruby example.rb`. In a Bundler project, run
`bundle exec ruby example.rb` instead.

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

document.to_s == source # => true
```

Only the heading marker changes. The blank line, emphasis marker, and final
newline remain as written. `Document#to_s` returns the stored source rather than
generating Markdown from the tree.

## Make another edit

Every editing operation reparses the result. Find a node in the returned
document before editing again:

```ruby
require "beid"

document = Beid::Document.parse("# Title\n\nKeep this *formatting*.\n")
heading = document.root.children.first
document = Beid::Editing.set_attribute(document, heading, :level, 2)

heading = document.root.children.first
document = Beid::Editing.replace_text(document, heading, "New title")
document.to_s # => "## New title\n\nKeep this *formatting*.\n"
```

Passing the old `heading` to a new document raises `ArgumentError`. Nodes and
ranges belong to one source snapshot, even if an edit leaves their text unchanged.

## Read and save a file

Use binary I/O to preserve line endings across platforms. Mark the input as
UTF-8, then check the document before editing it:

```ruby
require "beid"

source = File.binread("notes.md").force_encoding(Encoding::UTF_8)
document = Beid::Document.parse(source)
raise Beid::Error, document.diagnostics.join("; ") unless document.valid?

heading = document.root.children.find { |node| node.type == :heading }
raise ArgumentError, "notes.md needs a top-level heading" unless heading

updated = Beid::Editing.replace_text(document, heading, "Updated notes")
File.binwrite("notes.updated.md", updated.to_s)
```

This writes a separate file you can compare with the original. Setting the
encoding does not transcode invalid input. See
[Validation and limits](usage.md#validation-and-limits) for what `valid?` checks.

## Continue with the user guide

- [Parse Markdown and inspect nodes](usage.md#parse-markdown).
- [Find a node and translate byte offsets to editor positions](usage.md#find-nodes-by-byte-offset).
- [Replace, insert, remove, or move content](usage.md#edit-markdown).
- [Work with front matter and directives](usage.md#front-matter-and-directives).
- [Run the tests and preview the website](development.md).

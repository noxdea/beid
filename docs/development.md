---
title: Development
description: Set up Beid, run its specs and CommonMark comparison, and preview the GitHub Pages website.
---

# Development

Beid requires Ruby 3.1 or newer. The repository's CI runs on Linux, macOS, and
Windows with Ruby 3.1, 3.2, 3.3, 3.4, and 4.0.

## Set up the repository

```sh
git clone https://github.com/noxdea/beid.git
cd beid
bundle install
```

## Run the checks

```sh
bundle exec rake
bundle exec rbs -I sig validate
gem build --strict beid.gemspec
```

The default Rake task runs RSpec. The RBS check validates the signatures in
`sig/beid.rbs`. The gem build checks the package specification.

For the public API specs or the CommonMark comparison separately:

```sh
bundle exec rspec spec/beid_spec.rb
bundle exec rspec spec/commonmark_spec.rb
```

## Understand the CommonMark comparison

The repository includes the official CommonMark 0.31.2 fixture with 652
examples. Its specs check exact source round trips, valid node ranges, a
test-only semantic HTML comparison, and block-node coverage.

The semantic comparison currently agrees on 620/652 examples (95.1%). This
describes the comparison implemented by the test helper; Beid itself does not
render HTML. Nokogiri is a development dependency for the HTML comparison,
not a runtime dependency. CI prints the remaining mismatches by section.

Fixture provenance, its checksum, and its CC BY-SA 4.0 license are documented
in the [fixture README](https://github.com/noxdea/beid/blob/main/spec/fixtures/commonmark/README.md).

## Preview the website

The website uses GitHub Pages' built-in Jekyll support. The landing page is
`index.html`; the guide is Markdown in `docs/`, rendered with
`_layouts/guide.html`. Both share `styles.css`. No JavaScript build is needed.

Install Jekyll separately from the library's development bundle:

```sh
gem install jekyll -v 3.10.0
gem install jekyll-relative-links
JEKYLL_NO_BUNDLER_REQUIRE=true jekyll _3.10.0_ serve
```

Open <http://localhost:4000/beid/> and <http://localhost:4000/beid/docs/>.
`JEKYLL_NO_BUNDLER_REQUIRE` lets the site use Jekyll without adding it to the
library's Gemfile. Use the same prefix with `jekyll _3.10.0_ build` for a static
build in `_site/`.

The site's `/beid` prefix and canonical URL are set in `_config.yml`.
The repository is configured to publish from `main` at the repository root.
Changes to the website are published when they reach that branch.

## Architecture decisions

- [Byte-range edits instead of AST reserialization](https://github.com/noxdea/beid/blob/main/docs/adr/001-byte-range-edits.md): source snapshots and range ownership.
- [HTML comments as directives](https://github.com/noxdea/beid/blob/main/docs/adr/002-html-comment-directives.md): one metadata pair per comment and raw metadata preservation.

For user-facing changes, update the relevant guide examples and the
[changelog](https://github.com/noxdea/beid/blob/main/CHANGELOG.md), and run the checks above.

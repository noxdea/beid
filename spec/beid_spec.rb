# frozen_string_literal: true

RSpec.describe Beid do
  describe Beid::Document do
    it "has a version number" do
      expect(Beid::VERSION).to eq("0.1.0")
    end

    it "round trips representative Markdown without normalizing bytes" do
      samples = [
        "",
        "# Heading\r\n\r\nParagraph with *emphasis*, **strong**, `code`, [link](https://example.test/a_(b) \"title\"), and ![image](a.png).\r\n",
        "Title\n=====\n\n> quoted **text**\n> next line\n\n---\n",
        "- one\n- two\n\n1. first\n2. second\n\n```ruby\nputs :ok\n```\n",
        "| left | right |\n| :--- | ---: |\n| a | b |\n",
        "---\ntitle: sample\n---\n\n<!-- layout: two-column -->\n\n::: columns\n## Content\nbody\n:::\n",
        "<div>raw HTML</div>\n\nA paragraph with ~~deleted~~ text.\n",
        "[^note]: footnote body\n\nAn indented code block follows:\n\n    puts :code\n"
      ]

      samples.each do |source|
        document = described_class.parse(source)
        expect(document.to_s).to eq(source)
        expect(document.valid?).to be(true)
      end
    end

    it "keeps unsupported custom HTML blocks as raw source nodes" do
      source = "<x-card data-kind='demo'>\n*unparsed* content\n</x-card>\n\nAfter.\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      raw_block = document.root.children.first

      expect(raw_block.type).to eq(:html_block)
      expect(raw_block.attributes[:text]).to eq("<x-card data-kind='demo'>\n*unparsed* content\n</x-card>\n")
      expect(document.to_s).to eq(source)
    end

    it "parses block and inline nodes with byte ranges" do
      source = "# 見出し *強調*\n\nA [link](https://example.test) and `code`.\n\n- first\n- second\n\n> quote\n\n```rb\nx\n```\n\n***\n"
      document = described_class.parse(source)
      heading, paragraph, list, quote, code, rule = document.root.children

      expect([heading.type, paragraph.type, list.type, quote.type, code.type, rule.type]).to eq(
        %i[heading paragraph list block_quote code_block thematic_break]
      )
      expect(heading.range).to eq(0..."# 見出し *強調*\n".bytesize)
      expect(heading.children.map(&:type)).to eq(%i[text emphasis])
      expect(paragraph.children.map(&:type)).to eq(%i[text link text code_span text])
      expect(list.children.map(&:type)).to eq(%i[list_item list_item])
      expect(document.range_of(heading)).to eq(heading.range)
      expect(document.source.byteslice(paragraph.children[1].range)).to eq("[link](https://example.test)")

      setext_document = described_class.parse("A *setext* heading\n===\n")
      setext = setext_document.root.children.first
      expect([setext.type, setext.attributes[:style], setext.attributes[:level]]).to eq([:heading, :setext, 1])
      expect(Beid::Editing.set_attribute(setext_document, setext, :level, 2).to_s).to eq("A *setext* heading\n---\n")
    end

    it "exposes inline constructs and nested source ranges beside punctuation" do
      source = "日本語 *emphasis*, **strong**! ~~deleted~~. [**linked**](https://example.test). ![alt](image.png). `code`."
      document = described_class.parse(source)
      paragraph = document.root.children.first
      constructs = paragraph.children.select { |node| %i[emphasis strong strikethrough link image code_span].include?(node.type) }

      expect(constructs.map(&:type)).to eq(%i[emphasis strong strikethrough link image code_span])
      expect(constructs.map { |node| document.source.byteslice(node.range) }).to eq([
        "*emphasis*", "**strong**", "~~deleted~~", "[**linked**](https://example.test)",
        "![alt](image.png)", "`code`"
      ])
      nested_strong = constructs[3].children.first
      expect(nested_strong.type).to eq(:strong)
      expect(document.source.byteslice(nested_strong.range)).to eq("**linked**")
      expect(document.to_s).to eq(source)
    end

    it "matches exact CommonMark code-span delimiter runs and normalizes their text" do
      # The first four samples cover CommonMark 0.31.2 examples 330, 331, 340, and 349.
      [
        ["` `` `\n", "``", "` `` `"],
        ["`  ``  `\n", " `` ", "`  ``  `"],
        ["` foo `` bar `\n", "foo `` bar", "` foo `` bar `"],
        ["`foo``bar``\n", "bar", "``bar``"],
        ["`line\nbreak`\n", "line break", "`line\nbreak`"]
      ].each do |source, expected_text, expected_source|
        document = Beid::Document.parse(source, gfm: false, front_matter: false)
        code_spans = document.root.children.flat_map(&:children).select { |node| node.type == :code_span }

        expect(code_spans.map { |node| node.attributes[:text] }).to eq([expected_text])
        expect(document.source.byteslice(code_spans.first.range)).to eq(expected_source)
      end
    end

    it "recognizes tab-indented code and preserves its semantic code text" do
      [
        ["  \tfoo\tbaz\t\tbim\n", "foo\tbaz\t\tbim\n"],
        ["\t\tbar\n", "\tbar\n"],
        ["  \tfoo\n", "foo\n"]
      ].each do |source, expected_text|
        document = described_class.parse(source, gfm: false, front_matter: false)
        code = document.root.children.fetch(0)

        expect(code.type).to eq(:code_block)
        expect(code.attributes[:text]).to eq(expected_text)
        expect(document.source.byteslice(code.range)).to eq(source)
        expect(document.to_s).to eq(source)
      end
    end

    it "recognizes thematic breaks before list markers" do
      ["- - -\n", "-     -      -      -\n", "*\t*\t*\t\n"].each do |source|
        document = described_class.parse(source, gfm: false, front_matter: false)

        expect(document.root.children.map(&:type)).to eq([:thematic_break])
        expect(document.to_s).to eq(source)
      end
    end

    it "treats escaped punctuation as text and exposes CommonMark line breaks" do
      source = "\\*not emphasized*\nfoo\\\nbar\nspace  \nbaz\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      paragraph = document.root.children.fetch(0)

      expect(paragraph.children.map(&:type)).to eq([
        :text, :softbreak, :text, :linebreak, :text, :softbreak, :text, :linebreak, :text
      ])
      expect(paragraph.children.map { |node| node.attributes[:text] }.compact).to eq([
        "*not emphasized*", "foo", "bar", "space", "baz"
      ])
      expect(document.source.byteslice(paragraph.children[3].range)).to eq("\\\n")
      expect(document.source.byteslice(paragraph.children[7].range)).to eq("  \n")
      expect(document.to_s).to eq(source)
    end

    it "recognizes inline HTML without parsing markup as Markdown text" do
      source = "<span>*emphasis*</span> and <br />\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      paragraph = document.root.children.fetch(0)

      expect(paragraph.children.map(&:type)).to eq([:html_inline, :emphasis, :html_inline, :text,
                                                    :html_inline])
      expect(paragraph.children.values_at(0, 2, 4).map { |node| node.attributes[:text] }).to eq([
        "<span>", "</span>", "<br />"
      ])
      expect(paragraph.children.all? do |node|
        paragraph.range.begin <= node.range.begin && node.range.end <= paragraph.range.end
      end).to be(true)
      expect(document.to_s).to eq(source)
    end

    it "applies CommonMark delimiter flanking and nested emphasis cases" do
      [
        ["a * foo bar*\n", []],
        ["a*\"foo\"*\n", []],
        ["** foo bar**\n", []],
        ["__ foo bar__\n", []],
        ["__\nfoo bar__\n", []],
        ["foo*bar*\n", [:emphasis]],
        ["5*6*78\n", [:emphasis]],
        ["*foo*bar\n", [:emphasis]],
        ["**foo**bar\n", [:strong]],
        ["foo_bar_\n", []],
        ["_foo_bar_baz_\n", [:emphasis]],
        ["*(*foo*)*\n", %i[emphasis emphasis]]
      ].each do |source, expected_emphasis|
        document = described_class.parse(source, gfm: false, front_matter: false)
        emphasis_nodes = document.root.children.flat_map do |block|
          stack = block.children.dup
          found = []
          until stack.empty?
            node = stack.pop
            found << node.type if %i[emphasis strong].include?(node.type)
            stack.concat(node.children)
          end
          found
        end

        expect(emphasis_nodes.sort).to eq(expected_emphasis.sort)
        expect(document.to_s).to eq(source)
      end
    end

    it "resolves reference links, collapsed references, images, and autolinks" do
      source = "[Guide][docs], [reference][], [shortcut], ![badge][img], <https://example.test/a?q=1>, <dev+bot@example.test>\n\n[DOCS]: /guides \"Quick guide\"\n[reference]: /reference\n[shortcut]: /short\n[img]: /badge.png\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      paragraph = document.root.children.first
      links = paragraph.children.select { |node| %i[link image].include?(node.type) }

      expect(links.map { |node| [node.type, node.attributes[:destination], node.attributes[:title]] }).to eq([
        [:link, "/guides", "Quick guide"],
        [:link, "/reference", nil],
        [:link, "/short", nil],
        [:image, "/badge.png", nil],
        [:link, "https://example.test/a?q=1", nil],
        [:link, "mailto:dev+bot@example.test", nil]
      ])
      expect(links.map { |node| document.source.byteslice(node.range) }).to eq([
        "[Guide][docs]", "[reference][]", "[shortcut]", "![badge][img]",
        "<https://example.test/a?q=1>", "<dev+bot@example.test>"
      ])
      expect(links.all? do |node|
        child = node.children.first
        child.nil? || (node.range.begin <= child.range.begin && child.range.end <= node.range.end)
      end).to be(true)
      definitions = document.root.children.select { |node| node.type == :link_definition }
      expect(definitions.map { |node| node.attributes[:normalized_label] }).to eq(%w[docs reference shortcut img])
    end

    it "keeps an autolink that crosses a malformed inline-link candidate" do
      source = "[foo<https://example.com/?search=](uri)>\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      paragraph = document.root.children.first
      link = paragraph.children.find { |node| node.type == :link }

      expect(link.attributes[:autolink]).to be(true)
      expect(link.attributes[:destination]).to eq("https://example.com/?search=](uri)")
      expect(document.to_s).to eq(source)
    end

    it "keeps nested list levels as nested nodes with contained byte ranges" do
      source = "- parent\n  - child\n    - grandchild\n  - sibling\n- root sibling\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      list = document.root.children.first
      parent_item = list.children.first
      child_list = parent_item.children.find { |node| node.type == :list }
      grandchild_list = child_list.children.first.children.find { |node| node.type == :list }

      expect(list.children.length).to eq(2)
      expect(child_list.children.length).to eq(2)
      expect(grandchild_list.children.length).to eq(1)
      expect(document.source.byteslice(child_list.range)).to eq("  - child\n    - grandchild\n  - sibling\n")
      expect(document.source.byteslice(grandchild_list.range)).to eq("    - grandchild\n")
      expect(document.to_s).to eq(source)
    end

    it "parses list-item continuation paragraphs into source-nested blocks" do
      source = "- a\n  continuation\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      list = document.root.children.fetch(0)
      item = list.children.fetch(0)
      paragraph = item.children.fetch(0)
      text, softbreak, continuation = paragraph.children

      expect(list.type).to eq(:list)
      expect(item.type).to eq(:list_item)
      expect(item.children.map(&:type)).to eq([:paragraph])
      expect([text.attributes[:text], softbreak.type, continuation.attributes[:text]]).to eq(["a", :softbreak, "continuation"])
      expect(item.range.begin).to be <= paragraph.range.begin
      expect(paragraph.range.end).to be <= item.range.end
      expect(paragraph.range.begin).to be <= text.range.begin
      expect(continuation.range.end).to be <= paragraph.range.end
      expect(document.source.byteslice(item.range)).to eq(source)
      expect(document.to_s).to eq(source)
    end

    it "keeps multiple indented blocks inside one list item" do
      source = "- a\n  continuation\n\n  > quoted\n  >\n  > body\n\n  ```rb\n  puts :ok\n  ```\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      item = document.root.children.fetch(0).children.fetch(0)

      expect(item.children.map(&:type)).to eq(%i[paragraph block_quote code_block])
      expect(item.children[0].children.map(&:type)).to eq(%i[text softbreak text])
      expect(item.children[0].children.map { |node| node.attributes[:text] }.compact.join).to eq("acontinuation")
      expect(item.children[1].children.map(&:type)).to eq(%i[paragraph paragraph])
      expect(item.children[1].children.map { |node| node.children.first.attributes[:text] }).to eq(["quoted", "body"])
      expect(item.children[2].attributes[:info]).to eq("rb")
      expect(item.children.all? do |node|
        item.range.begin <= node.range.begin && node.range.end <= item.range.end
      end).to be(true)
      expect(document.source.byteslice(item.range)).to eq(source)
      expect(document.to_s).to eq(source)
    end

    it "parses empty list markers with indented continuation blocks" do
      source = "-\n  foo\n-\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      list = document.root.children.first

      expect(list.type).to eq(:list)
      expect(list.children.map { |item| item.children.map(&:type) }).to eq([[:paragraph], []])
      expect(list.children.first.children.first.children.first.attributes[:text]).to eq("foo")
      expect(document.to_s).to eq(source)
    end

    it "parses block quote headings and lazy paragraph continuations" do
      source = "> # Foo\n> bar\nbaz\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      quote = document.root.children.fetch(0)
      heading, paragraph = quote.children

      expect(quote.type).to eq(:block_quote)
      expect(heading.type).to eq(:heading)
      expect(heading.attributes[:level]).to eq(1)
      expect(heading.children.map { |node| node.attributes[:text] }.join).to eq("Foo")
      expect(paragraph.type).to eq(:paragraph)
      expect(paragraph.children.map(&:type)).to eq(%i[text softbreak text])
      expect(paragraph.children.map { |node| node.attributes[:text] }.compact.join).to eq("barbaz")
      [heading, paragraph].each do |child|
        expect(quote.range.begin).to be <= child.range.begin
        expect(child.range.end).to be <= quote.range.end
        child.children.each do |inline|
          expect(child.range.begin).to be <= inline.range.begin
          expect(inline.range.end).to be <= child.range.end
        end
      end
      expect(document.source.byteslice(quote.range)).to eq(source)
      expect(document.to_s).to eq(source)
    end

    it "uses the first reference definition and ignores definitions inside code fences" do
      source = "[item][key]\n\n[key]: /first\n[key]: /second\n\n```\n[hidden]: /code\n```\n\n[hidden]\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      links = document.root.children.flat_map { |node| node.children.select { |child| child.type == :link } }
      definitions = document.root.children.select { |node| node.type == :link_definition }

      expect(links.map { |node| node.attributes[:destination] }).to eq(["/first"])
      expect(definitions.map { |node| node.attributes[:effective] }).to eq([true, false])
      expect(document.to_s).to eq(source)
    end

    it "does not treat a link definition as interrupting a paragraph" do
      source = "Foo\n[bar]: /baz\n\n[bar]\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      paragraphs = document.root.children.select { |node| node.type == :paragraph }

      expect(document.root.children.map(&:type)).to eq(%i[paragraph paragraph])
      expect(document.root.children.flat_map(&:children).none? { |node| node.type == :link_definition }).to be(true)
      expect(paragraphs.map { |node| document.source.byteslice(node.range) }).to eq(["Foo\n[bar]: /baz\n", "[bar]\n"])
      expect(document.root.children.last.children.map(&:type)).to eq([:text])
      expect(document.to_s).to eq(source)
    end

    it "prefers valid inline links but falls back to a shortcut reference after an invalid inline form" do
      source = "[foo]() [foo](not a link)\n\n[foo]: /reference\n"
      document = described_class.parse(source, gfm: false, front_matter: false)
      links = document.root.children.first.children.select { |node| node.type == :link }

      expect(links.map { |node| [node.attributes[:destination], document.source.byteslice(node.range)] }).to eq([
        ["", "[foo]()"], ["/reference", "[foo]"]
      ])
      expect(document.to_s).to eq(source)
    end

    it "parses multiline reference destinations and titles without losing their ranges" do
      samples = [
        ["   [foo]: \n      /url  \n           'the title'  \n\n[foo]\n", "/url", "the title", "/url"],
        ["[Foo bar]:\n<my url>\n\'title\'\n\n[Foo bar]\n", "my url", "title", "my url"],
        ["[Foo\n  bar]: /url\n\n[Baz][Foo bar]\n", "/url", nil, "/url"],
        ["[foo]: /url '\ntitle\nline1\nline2\n'\n\n[foo]\n", "/url", "\ntitle\nline1\nline2\n", "/url"],
        ["[foo]:\n/url\n\n[foo]\n", "/url", nil, "/url"]
      ]

      samples.each do |source, destination, title, raw_destination|
        document = described_class.parse(source, gfm: false, front_matter: false)
        definition = document.root.children.find { |node| node.type == :link_definition }
        link = document.root.children.flat_map(&:children).find { |node| node.type == :link }

        expect([definition.attributes[:destination], definition.attributes[:title]]).to eq([destination, title])
        expect(document.source.byteslice(definition.attributes[:destination_range])).to eq(raw_destination)
        expect(link.attributes.values_at(:destination, :title)).to eq([destination, title])
        expect(document.source.byteslice(link.attributes[:definition_range])).to eq(document.source.byteslice(definition.range))
        expect(document.to_s).to eq(source)
      end
    end

    it "recognizes GFM nodes and respects parser options" do
      document = described_class.parse("- [x] done\n\n~~old~~ and [^id]\n\n[^id]: note\n\n| a | b |\n| --- | --- |\n| c | d |\n")
      item = document.root.children.first.children.first

      expect(item.attributes.values_at(:task, :checked)).to eq([true, true])
      expect(item.children.first.type).to eq(:task_checkbox)
      expect(document.root.children.find { |node| node.type == :paragraph }.children.map(&:type)).to include(:strikethrough)
      expect(document.root.children.find { |node| node.type == :paragraph }.children.map(&:type)).to include(:footnote_reference)
      expect(document.root.children.map(&:type)).to include(:footnote_definition, :table)
      table = document.root.children.find { |node| node.type == :table }
      expect(table.children[1].marker).to eq("| --- | --- |")
      expect(described_class.parse("~~text~~", gfm: false).root.children.first.children.map(&:type)).to eq([:text])
      expect(described_class.parse("---\ntitle: x\n---\n", front_matter: false).front_matter).to be_nil

      div = described_class.parse("::: columns\n## Inside\ntext\n:::\n").root.children.first
      expect(div.attributes.values_at(:kind, :name, :closed)).to eq([:div, "columns", true])
      expect(div.children.map(&:type)).to eq(%i[heading paragraph])
    end

    it "provides codepoint and UTF-16 positions and rejects split characters" do
      document = described_class.parse("a😀b\r\n次")
      expect(document.position_at("a😀".bytesize)).to eq([0, 2])
      expect(document.utf16_position_at("a😀".bytesize)).to eq([0, 3])
      expect(document.position_at("a😀b\r\n次".bytesize)).to eq([1, 1])
      expect { document.utf16_position_at(2) }.to raise_error(RangeError)
    end

    it "returns nodes from outermost to innermost at a source byte" do
      document = described_class.parse("# **bold**\n")
      offset = document.source.index("bold")
      expect(document.nodes_at(offset).map(&:type)).to eq(%i[document heading strong text])
      expect(document.node_at(offset).type).to eq(:text)
      expect(document.node_at(document.source.bytesize)).to be_nil
      expect { document.nodes_at(document.source.bytesize + 1) }.to raise_error(RangeError)
    end

    it "keeps the source immutable and safely retains invalid UTF-8 bytes" do
      source = String.new("# title\n")
      document = described_class.parse(source)
      source.replace("changed")
      expect(document.to_s).to eq("# title\n")

      invalid = String.new("bad\xFF").force_encoding(Encoding::UTF_8)
      fallback = described_class.parse(invalid)
      expect(fallback.to_s.b).to eq(invalid.b)
      expect(fallback.root.children.first.type).to eq(:text)
      expect(fallback.valid?).to be(false)
    end
  end

  describe Beid::Directive do
    it "parses and renders a single safe HTML-comment directive" do
      source = "<!-- layout: two-column -->"
      expect(described_class.parse(source)).to eq("layout" => "two-column")
      expect(described_class.render("layout" => "two-column")).to eq(source)
      expect(described_class.parse("<!-- ordinary comment -->")).to be_nil
      expect { described_class.render("layout" => "wide -->\nunsafe") }.to raise_error(ArgumentError)
    end
  end

  describe Beid::Editing do
    let(:source) { "# Title\n\nA **bold** paragraph.\n\n- first\n- second\n\n[link](https://old.test)\n\n<!-- layout: one -->\n" }
    let(:document) { Beid::Document.parse(source) }

    it "replaces a node without reserializing neighboring Markdown" do
      paragraph = document.root.children.find { |node| node.type == :paragraph }
      edited = described_class.replace(document, paragraph, "A _changed_ paragraph.")

      expect(edited.to_s).to eq(source.sub("A **bold** paragraph.", "A _changed_ paragraph."))
      expect(document.to_s).to eq(source)
    end

    it "replaces text while keeping the heading marker and line endings" do
      heading = document.root.children.first
      edited = described_class.replace_text(document, heading, "New title")
      expect(edited.to_s).to start_with("# New title\n\n")
    end

    it "inserts into lists using the existing marker" do
      list = document.root.children.find { |node| node.type == :list }
      edited = described_class.insert_after(document, list.children.first, "* inserted")

      expect(edited.to_s).to include("- first\n- inserted\n- second")

      no_final_newline = Beid::Document.parse("- last")
      inserted = described_class.insert_after(no_final_newline, no_final_newline.root.children.first.children.first, "+ next")
      expect(inserted.to_s).to eq("- last\n- next")
    end

    it "inserts before a node, removes a node, and moves a node" do
      heading, paragraph = document.root.children.first(2)
      inserted = described_class.insert_before(document, paragraph, "## New")
      expect(inserted.to_s).to include("# Title\n\n## New\n\nA **bold** paragraph.")

      removed = described_class.remove(document, heading)
      expect(removed.to_s).to eq(source.sub("# Title\n", ""))

      moved = described_class.move(document, heading, after: paragraph)
      expect(moved.to_s).to include("A **bold** paragraph.\n# Title\n")
    end

    it "sets heading, link, and directive attributes by replacing only their ranges" do
      heading = document.root.children.first
      link = document.root.children.flat_map(&:children).find { |node| node.type == :link }
      directive = document.root.children.find { |node| node.type == :directive }

      expect(described_class.set_attribute(document, heading, :level, 2).to_s).to start_with("## Title\n")
      expect(described_class.set_attribute(document, link, :destination, "https://new.test").to_s).to include("[link](https://new.test)")
      expect(described_class.set_directive(document, directive, :layout, "wide").to_s).to include("<!-- layout: wide -->")
    end

    it "rejects foreign nodes, unsupported attributes, and invalid heading levels" do
      paragraph = document.root.children.find { |node| node.type == :paragraph }
      foreign = Beid::Document.parse("paragraph").root.children.first

      expect { described_class.remove(document, foreign) }.to raise_error(ArgumentError)
      expect { described_class.set_attribute(document, document.root.children.first, :level, 7) }.to raise_error(ArgumentError)
      expect { described_class.set_attribute(document, paragraph, :unknown, "x") }.to raise_error(ArgumentError)
    end
  end
end

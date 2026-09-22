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

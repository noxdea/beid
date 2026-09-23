# frozen_string_literal: true

require "json"

RSpec.describe "CommonMark 0.31.2 fixture" do
  FIXTURE = File.expand_path("fixtures/commonmark/0.31.2.json", __dir__)
  EXAMPLES = JSON.parse(File.read(FIXTURE)).freeze
  HTML_BLOCK_TYPES = {
    "p" => :paragraph,
    "blockquote" => :block_quote,
    "ul" => :list,
    "ol" => :ordered_list,
    "pre" => :code_block,
    "hr" => :thematic_break
  }.freeze
  HTML_TAG = /(?:<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<![^>]*>|<\/?([A-Za-z][A-Za-z0-9:-]*)(?:[ \t]+(?:[^>"']|"[^"]*"|'[^']*')*)?[ \t]*\/?>)/
  HTML_VOID_ELEMENTS = %w[area base br col embed hr img input link meta param source track wbr].freeze

  it "round trips every official example and keeps all node ranges within their source" do
    round_trip_failures = []
    range_failures = []

    EXAMPLES.each do |example|
      source = example.fetch("markdown")
      document = Beid::Document.parse(source, gfm: false, front_matter: false)
      round_trip_failures << example.fetch("example") unless document.to_s == source
      stack = [[document.root, nil]]
      until stack.empty?
        node, parent = stack.pop
        range = node.range
        valid = range.begin >= 0 && range.end <= source.bytesize && range.end >= range.begin
        valid &&= range.begin >= parent.range.begin && range.end <= parent.range.end if parent
        unless valid
          range_failures << example.fetch("example")
          break
        end
        stack.concat(node.children.reverse.map { |child| [child, node] })
      end
    end

    puts "CommonMark 0.31.2: exact round-trip #{EXAMPLES.length - round_trip_failures.length}/#{EXAMPLES.length}; " \
      "valid source ranges #{EXAMPLES.length - range_failures.length}/#{EXAMPLES.length}"
    expect(round_trip_failures).to be_empty, "round-trip failed for examples #{round_trip_failures.first(20)}"
    expect(range_failures).to be_empty, "invalid node ranges in examples #{range_failures.first(20)}"
  end

  it "reports top-level block-node coverage against balanced official HTML tags" do
    scored = 0
    expected_types_present = 0
    type_set_matches = 0
    sequence_matches = 0
    unbalanced_html_fragments = 0

    EXAMPLES.each do |example|
      expected = expected_block_types(example.fetch("html"))
      unless expected
        unbalanced_html_fragments += 1
        next
      end

      scored += 1
      actual = Beid::Document.parse(example.fetch("markdown"), gfm: false, front_matter: false)
        .root.children.map(&:type)
      expected_types_present += 1 if expected.empty? ? actual.empty? : expected.uniq.all? { |type| actual.include?(type) }
      type_set_matches += 1 if expected.uniq.sort == actual.uniq.sort
      sequence_matches += 1 if expected == actual
    end

    type_recall_rate = 100.0 * expected_types_present / scored
    type_set_rate = 100.0 * type_set_matches / scored
    sequence_rate = 100.0 * sequence_matches / scored
    puts format("CommonMark 0.31.2: expected root block-type recall proxy %d/%d (%.1f%%); exact type-set agreement %d/%d (%.1f%%); exact root sequence %d/%d (%.1f%%); unbalanced HTML fragments %d (raw source round-trip tested above)",
      expected_types_present, scored, type_recall_rate, type_set_matches, scored, type_set_rate,
      sequence_matches, scored, sequence_rate, unbalanced_html_fragments)

    # Recall is a deliberately loose AST-shape regression guard, not semantic conformance.
    expect(type_recall_rate).to be >= 95.0
  end

  def expected_block_types(html)
    roots = []
    stack = []
    offset = 0
    while (match = HTML_TAG.match(html, offset))
      offset = match.end(0)
      token = match[0]
      next if token.start_with?("<!--", "<!")

      name = match[1].downcase
      if token.start_with?("</")
        return nil unless stack.pop == name
      else
        if stack.empty?
          roots << if name.match?(/\Ah[1-6]\z/)
            :heading
          else
            HTML_BLOCK_TYPES.fetch(name, :html_block)
          end
        end
        stack << name unless token.end_with?("/>") || HTML_VOID_ELEMENTS.include?(name)
      end
    end

    stack.empty? ? roots : nil
  end
end

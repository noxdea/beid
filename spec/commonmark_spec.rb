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
  AUTOLINK_SOURCE = /<(?:[A-Za-z][A-Za-z0-9.+-]{1,31}:[^ <>]*|[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9.-]+)>/
  REFERENCE_USE_SOURCE = /!?\[[^\]\n]+\](?:[ \t]*(?:\r\n|\r|\n)?[ \t]*\[[^\]\n]*\])?/

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
    reference_examples = 0
    reference_nodes = 0
    autolink_examples = 0
    autolink_nodes = 0
    nested_list_examples = 0
    nested_list_matches = 0

    EXAMPLES.each do |example|
      expected = expected_block_types(example.fetch("html"))
      unless expected
        unbalanced_html_fragments += 1
        next
      end

      scored += 1
      document = Beid::Document.parse(example.fetch("markdown"), gfm: false, front_matter: false)
      actual = document.root.children.reject { |node| node.type == :link_definition }.map(&:type)
      expected_types_present += 1 if expected.empty? ? actual.empty? : expected.uniq.all? { |type| actual.include?(type) }
      type_set_matches += 1 if expected.uniq.sort == actual.uniq.sort
      sequence_matches += 1 if expected == actual

      nodes = all_nodes(document.root)
      if example.fetch("markdown").match?(/^ {0,3}\[[^\]\n]+\]:/) &&
        reference_link_use?(example.fetch("markdown")) && example.fetch("html").match?(/<a href=|<img(?:\s|>)/)
        reference_examples += 1
        reference_nodes += 1 if nodes.any? { |node| node.attributes[:reference_label] }
      end
      if example.fetch("markdown").match?(AUTOLINK_SOURCE) && example.fetch("html").include?("<a href=")
        autolink_examples += 1
        autolink_nodes += 1 if nodes.any? { |node| node.type == :link && node.attributes[:autolink] }
      end
      expected_nested = expected_nested_list_count(example.fetch("html"))
      if expected_nested.positive? && example.fetch("markdown").match?(/^ {2,}(?:[-+*]|\d+[.)])[ \t]+/)
        nested_list_examples += 1
        actual_nested = nodes.count { |node| %i[list ordered_list].include?(node.type) } -
          document.root.children.count { |node| %i[list ordered_list].include?(node.type) }
        nested_list_matches += 1 if actual_nested == expected_nested
      end
    end

    type_recall_rate = 100.0 * expected_types_present / scored
    type_set_rate = 100.0 * type_set_matches / scored
    sequence_rate = 100.0 * sequence_matches / scored
    puts format("CommonMark 0.31.2: expected root block-type recall proxy %d/%d (%.1f%%); exact type-set agreement %d/%d (%.1f%%); exact root sequence %d/%d (%.1f%%); unbalanced HTML fragments %d (raw source round-trip tested above)",
      expected_types_present, scored, type_recall_rate, type_set_matches, scored, type_set_rate,
      sequence_matches, scored, sequence_rate, unbalanced_html_fragments)
    puts format("CommonMark features: reference-link cases %d/%d; autolink cases %d/%d; nested-list counts %d/%d",
      reference_nodes, reference_examples, autolink_nodes, autolink_examples, nested_list_matches, nested_list_examples)

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

  def all_nodes(root)
    nodes = []
    stack = [root]
    until stack.empty?
      node = stack.pop
      nodes << node
      stack.concat(node.children)
    end
    nodes
  end

  def reference_link_use?(markdown)
    source = markdown.lines.reject { |line| line.match?(/^ {0,3}\[[^\]\n]+\]:/) }.join
    source = source.gsub(AUTOLINK_SOURCE, "")
    remaining = +""
    cursor = 0
    while (match = Beid::InlineParser::TOKEN.match(source, cursor))
      remaining << source[cursor...match.begin(0)]
      remaining << (match[3] ? " " : match[0])
      cursor = match.end(0)
    end
    remaining << source[cursor..].to_s
    remaining.match?(REFERENCE_USE_SOURCE)
  end

  def expected_nested_list_count(html)
    stack = []
    count = 0
    offset = 0
    while (match = HTML_TAG.match(html, offset))
      offset = match.end(0)
      token = match[0]
      next if token.start_with?("<!--", "<!")

      name = match[1].downcase
      if token.start_with?("</")
        return 0 unless stack.pop == name
      else
        count += 1 if %w[ul ol].include?(name) && stack.include?("li")
        stack << name unless token.end_with?("/>") || HTML_VOID_ELEMENTS.include?(name)
      end
    end
    stack.empty? ? count : 0
  end
end

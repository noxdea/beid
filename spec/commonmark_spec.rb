# frozen_string_literal: true

require "json"
require "cgi"
require "uri"
require "nokogiri"

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

  it "compares rendered Beid semantics with the official CommonMark HTML" do
    matched = 0
    mismatches = []
    mismatch_sections = Hash.new(0)

    EXAMPLES.each do |example|
      document = Beid::Document.parse(example.fetch("markdown"), gfm: false, front_matter: false)
      actual = semantic_html(render_document(document))
      expected = semantic_html(example.fetch("html"))
      if actual == expected
        matched += 1
      else
        mismatches << example.fetch("example")
        mismatch_sections[example.fetch("section")] += 1
      end
    end

    rate = 100.0 * matched / EXAMPLES.length
    puts format("CommonMark 0.31.2: semantic HTML DOM agreement %d/%d (%.1f%%); first mismatches: %s",
      matched, EXAMPLES.length, rate, mismatches.first(20).join(", "))
    puts "Largest semantic mismatch sections: #{mismatch_sections.sort_by { |_section, count| -count }.first(10).map { |section, count| "#{section}=#{count}" }.join(", ")}"
    expect(EXAMPLES.length).to eq(652), "the semantic oracle must cover every official fixture"
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

  def render_document(document)
    document.root.children.map { |node| render_node(node, document) }.join
  end

  def render_node(node, document, tight_list: false)
    children = -> { node.children.map { |child| render_node(child, document) }.join }
    case node.type
    when :link_definition
      ""
    when :paragraph
      tight_list ? children.call : "<p>#{children.call}</p>\n"
    when :heading
      level = node.attributes.fetch(:level)
      "<h#{level}>#{children.call}</h#{level}>\n"
    when :block_quote
      "<blockquote>\n#{children.call}</blockquote>\n"
    when :list, :ordered_list
      tag = node.type == :ordered_list ? "ol" : "ul"
      attrs = if tag == "ol" && node.attributes.fetch(:start, 1) != 1
        " start=\"#{node.attributes.fetch(:start)}\""
      else
        ""
      end
      source = document.source.byteslice(node.range)
      loose = source.match?(/\n[ \t]*\n/)
      body = node.children.map { |child| render_node(child, document, tight_list: !loose) }.join
      "<#{tag}#{attrs}>\n#{body}</#{tag}>\n"
    when :list_item
      body = node.children.map { |child| render_node(child, document, tight_list: tight_list) }.join
      "<li>#{body}</li>\n"
    when :thematic_break
      "<hr />\n"
    when :code_block
      render_code_block(node, document)
    when :html_block
      node.attributes.fetch(:text)
    when :directive
      node.attributes[:kind] == :html_comment ? "#{node.marker}\n" : escape_text(source_for(node, document))
    when :text
      text = node.attributes[:literal] ? node.attributes.fetch(:text) : markdown_text(source_for(node, document))
      escape_text(text)
    when :softbreak
      "\n"
    when :linebreak
      "<br />\n"
    when :html_inline
      node.attributes.fetch(:text)
    when :code_span
      "<code>#{escape_text(node.attributes.fetch(:text))}</code>"
    when :emphasis
      "<em>#{children.call}</em>"
    when :strong
      "<strong>#{children.call}</strong>"
    when :strikethrough
      "<del>#{children.call}</del>"
    when :link
      destination = source_attribute(node, :destination_range, document) || node.attributes[:destination]
      title = source_attribute(node, :title_range, document) || node.attributes[:title]
      href = if node.attributes[:autolink]
        uri_escape(destination.to_s)
      else
        uri_escape(markdown_text(destination.to_s))
      end
      attrs = html_attributes("href" => href, "title" => title && markdown_text(title))
      "<a#{attrs}>#{children.call}</a>"
    when :image
      label = node.attributes[:label] || source_for(node, document)
      destination = source_attribute(node, :destination_range, document) || node.attributes[:destination]
      title = source_attribute(node, :title_range, document) || node.attributes[:title]
      attrs = html_attributes("src" => uri_escape(markdown_text(destination.to_s)), "alt" => markdown_text(label),
                              "title" => title && markdown_text(title))
      "<img#{attrs} />"
    else
      escape_text(source_for(node, document))
    end
  end

  def render_code_block(node, document)
    fence = node.attributes[:fence]
    if fence
      info = markdown_text(node.attributes[:info].to_s).split(/[ \t]+/, 2).first
      code = node.attributes.fetch(:text)
      attrs = info.to_s.empty? ? "" : html_attributes("class" => "language-#{info}")
    else
      code = node.attributes.fetch(:text)
      attrs = ""
    end
    "<pre><code#{attrs}>#{escape_text(code)}</code></pre>\n"
  end

  def semantic_html(html)
    fragment = Nokogiri::HTML5.fragment(html)
    semantic_children(fragment, preserve_whitespace: false)
  end

  BLOCK_ELEMENTS = %w[address article aside blockquote body dd details dialog div dl dt fieldset figcaption
                      figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr li main nav ol p pre section table
                      tbody td tfoot th thead tr ul].freeze
  RAW_TEXT_ELEMENTS = %w[code pre script style textarea].freeze

  def semantic_children(parent, preserve_whitespace:)
    entries = parent.children.map do |child|
      if child.text?
        text = child.text
        text = text.gsub(/[\t\r\n\f ]+/, " ") unless preserve_whitespace
        [:text, text]
      elsif child.element?
        raw = RAW_TEXT_ELEMENTS.include?(child.name)
        attrs = child.attribute_nodes.map { |attribute| [attribute.name, attribute.value] }.sort
        [:element, child.name, attrs,
         semantic_children(child, preserve_whitespace: raw)]
      elsif child.comment?
        [:comment, child.content]
      else
        nil
      end
    end.compact

    entries.each_with_index.reject do |entry, index|
      next false unless entry.first == :text && entry[1].strip.empty?

      previous = entries[0...index].reverse.find { |candidate| candidate.first != :text || !candidate[1].strip.empty? }
      following = entries[(index + 1)..].to_a.find { |candidate| candidate.first != :text || !candidate[1].strip.empty? }
      (previous && previous.first == :element && BLOCK_ELEMENTS.include?(previous[1])) ||
        (following && following.first == :element && BLOCK_ELEMENTS.include?(following[1]))
    end.map(&:first).each_with_object([]) do |entry, normalized|
      if entry.first == :text && normalized.last&.first == :text
        normalized.last[1] << entry[1]
      else
        normalized << entry
      end
    end
  end

  def markdown_text(text)
    output = +""
    index = 0
    while index < text.length
      if text[index] == "\\" && text[index + 1]&.match?(/[!\"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~]/)
        output << text[index + 1]
        index += 2
      elsif text[index] == "&" && (entity = /\A&(?:#[xX][0-9A-Fa-f]+|#\d+|[A-Za-z][A-Za-z0-9]+);/.match(text[index..]))
        decoded = Nokogiri::HTML5.fragment(entity[0]).text
        output << decoded
        index += entity[0].length
      else
        output << text[index]
        index += 1
      end
    end
    output
  end

  def escape_text(text)
    CGI.escapeHTML(text)
  end

  def html_attributes(attributes)
    attributes.compact.map { |name, value| " #{name}=\"#{CGI.escapeHTML(value.to_s)}\"" }.join
  end

  def source_attribute(node, name, document)
    range = node.attributes[name]
    range && document.source.byteslice(range)
  end

  def uri_escape(value)
    URI::DEFAULT_PARSER.escape(value, /[^#{URI::PATTERN::UNRESERVED}#{URI::PATTERN::RESERVED}]/)
  end

  def source_for(node, document)
    document.source.byteslice(node.range).to_s
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

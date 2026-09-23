# frozen_string_literal: true

module Beid
  class Parser
    LINK_DEFINITION_START = /\A {0,3}\[((?:\\[[:punct:]]|[^\[\]\n])+)\]:[ \t]*(.*)\z/
    LINK_DESTINATION = /\A(<[^>\n]*>|(?:\\.|[^\s])+)(.*)\z/

    Line = Struct.new(:text, :ending, :start, :finish, keyword_init: true) do
      def blank?
        text.match?(/\A[ \t]*\z/)
      end
    end
    FragmentLine = Struct.new(:text, :ending, :source_start, :range_start, keyword_init: true)

    def initialize(source, gfm: true, front_matter: true, inherited_link_definitions: {})
      @source, @gfm, @front_matter = source, gfm, front_matter
      @lines = source.valid_encoding? ? lines_for(source) : []
      local_definitions, @link_definition_lines = collect_link_definitions
      @link_definitions = inherited_link_definitions.merge(local_definitions).freeze
    end

    def parse
      unless @source.valid_encoding?
        return [Node.new(type: :document, range: 0...@source.bytesize,
                         children: [Node.new(type: :text, range: 0...@source.bytesize,
                                             attributes: { text: @source })]), nil, ["Source is not valid UTF-8"]]
      end

      children = []
      front_matter = nil
      index = 0
      if @front_matter && @lines.first&.text == "---"
        finish = (1...@lines.length).find { |i| ["---", "..."].include?(@lines[i].text) }
        if finish
          first, last = @lines.first, @lines[finish]
          front_matter = @source.byteslice(first.finish...last.start)
          inner_start = first.finish
          children << make(:front_matter, first.start, last.finish,
                           marker: first.text, attributes: { text: front_matter,
                                                            content_range: inner_start...last.start })
          index = finish + 1
        end
      end

      while index < @lines.length
        index += 1 while index < @lines.length && @lines[index].blank?
        break if index >= @lines.length

        node, index = parse_block(index)
        children << node
      end

      root = Node.new(type: :document, range: 0...@source.bytesize, children: children)
      [root, front_matter, []]
    end

    private

    def lines_for(source)
      lines = []
      offset = 0
      source.each_line do |raw|
        ending = raw[/\r\n|\n|\r\z/] || ""
        text = ending.empty? ? raw : raw[0...-ending.length]
        lines << Line.new(text: text, ending: ending, start: offset, finish: offset + raw.bytesize)
        offset += raw.bytesize
      end
      lines
    end

    def parse_block(index)
      line = @lines[index]
      text = line.text

      return parse_fence(index) if (match = /\A {0,3}(`{3,}|~{3,})(.*)\z/.match(text))
      return parse_div(index) if (match = /\A {0,3}:::\s*([^\s]*)\s*\z/.match(text))
      return parse_quote(index) if text.match?(/\A {0,3}>/)
      return [make(:thematic_break, line.start, line.finish, marker: text.strip), index + 1] if thematic_break?(text)
      return parse_list(index) if list_marker(text)
      return parse_indented_code(index) if indented_code_start?(text)
      return [parse_comment_directive(index), index + 1] if directive_comment(text)
      return parse_html(index) if html_block_start?(text)
      return parse_link_definition(index) if @link_definition_lines.key?(index)
      return parse_table(index) if @gfm && table_separator?(@lines[index + 1]&.text) && text.include?("|")
      return parse_footnote(index) if @gfm && text.match?(/\A {0,3}\[\^[^\]]+\]:/)
      return [parse_heading(index), index + 1] if (match = /\A {0,3}(\#{1,6})(?:[ \t]+|$)(.*)\z/.match(text))
      parse_paragraph(index)
    end

    def parse_fence(index)
      opener = @lines[index]
      match = /\A {0,3}(`{3,}|~{3,})(.*)\z/.match(opener.text)
      fence, info = match[1], match[2].strip
      close = (index + 1...@lines.length).find do |i|
        @lines[i].text.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*\z/)
      end
      last = close ? @lines[close] : @lines[-1]
      finish_index = close ? close + 1 : @lines.length
      content_end = close ? @lines[close].start : @source.bytesize
      content = @source.byteslice(opener.finish...content_end).to_s
      [make(:code_block, opener.start, last.finish, marker: fence,
            attributes: { info: info, fence: fence, closed: !close.nil?,
                          text: content, content_range: opener.finish...content_end }), finish_index]
    end

    def parse_div(index)
      opener = @lines[index]
      name = /\A {0,3}:::\s*([^\s]*)/.match(opener.text)[1]
      depth = 1
      finish_index = index + 1
      while finish_index < @lines.length
        text = @lines[finish_index].text
        depth += 1 if text.match?(/\A {0,3}:::\s*\S+/)
        if text.match?(/\A {0,3}:::\s*\z/)
          depth -= 1
          if depth.zero?
            finish_index += 1
            break
          end
        end
        finish_index += 1
      end
      last = @lines[finish_index - 1]
      closing_index = depth.zero? ? finish_index - 1 : finish_index
      children = []
      child_index = index + 1
      while child_index < closing_index
        child_index += 1 while child_index < closing_index && @lines[child_index].blank?
        break if child_index >= closing_index

        child, child_index = parse_block(child_index)
        children << child
      end
      [make(:directive, opener.start, last.finish, marker: ":::",
            attributes: { kind: :div, name: name, closed: depth.zero? }, children: children), finish_index]
    end

    def parse_quote(index)
      first = index
      fragments = []
      paragraph_open = false
      while index < @lines.length
        line = @lines[index]
        match = /\A {0,3}> ?(.*)\z/.match(line.text)
        if match
          prefix_end = match.begin(1)
          content = match[1]
          content_start = line.start + byte_length(line.text[0...prefix_end])
          fragments << FragmentLine.new(text: content, ending: line.ending,
                                        source_start: content_start, range_start: line.start)
          paragraph_open = paragraph_continuation?(content)
          index += 1
        elsif paragraph_open && paragraph_continuation?(line.text)
          fragments << FragmentLine.new(text: line.text, ending: line.ending,
                                        source_start: line.start, range_start: line.start)
          index += 1
        else
          break
        end
      end
      children = parse_fragment(fragments)
      [make(:block_quote, @lines[first].start, @lines[index - 1].finish, marker: ">", children: children), index]
    end

    def parse_list(index)
      first = index
      initial = list_marker(@lines[index].text)
      base_indent, list_marker_text, ordered = initial
      items = []
      while index < @lines.length
        current = list_marker(@lines[index].text)
        break unless same_list?(current, initial)

        line = @lines[index]
        marker_match = /\A[ \t]*(?:([-+*])|(\d{1,9}[.)]))(?:([ \t]+)(.*)|\z)/.match(line.text)
        marker = marker_match[1] || marker_match[2]
        content = marker_match[4].to_s
        content_prefix = line.text[0...(marker_match.begin(4) || line.text.length)]
        content_start = line.start + byte_length(content_prefix)
        content_indent = indentation(content_prefix)
        if content.empty?
          marker_end = marker_match.begin(1) || marker_match.begin(2)
          marker_end += marker.length
          content_indent = indentation(line.text[0...marker_end]) + 1
        end
        content_finish = content_start + byte_length(content)
        task = @gfm && /\A\[([ xX])\](?:[ \t]+|$)(.*)\z/.match(content)
        if task
          content_start += byte_length(content[0...task.begin(2)])
          content, content_finish = task[2], content_start + byte_length(task[2])
        end
        attrs = { content_range: content_start...content_finish, ordered: ordered,
                  start: marker[/\A\d+/]&.to_i, task: !task.nil?, checked: task && task[1].downcase == "x" }
        fragments = [FragmentLine.new(text: content, ending: line.ending,
                                      source_start: content_start, range_start: content_start)]
        item_end = line.finish
        has_item_content = !content.empty?
        paragraph_open = paragraph_continuation?(content)
        index += 1
        while index < @lines.length
          if @lines[index].blank?
            next_index = index + 1
            next_index += 1 while next_index < @lines.length && @lines[next_index].blank?
            next_line = @lines[next_index]
            next_marker = list_marker(next_line&.text.to_s, max_indent: nil)
            if next_marker && next_marker[0] == base_indent
              index = next_index
              break
            end
            if has_item_content && next_line && indentation(next_line.text[/\A[ \t]*/].to_s) >= content_indent
              while index < next_index
                blank = @lines[index]
                blank_text, blank_start = strip_indent(blank, content_indent)
                fragments << FragmentLine.new(text: blank_text, ending: blank.ending,
                                              source_start: blank_start, range_start: blank.start)
                item_end = blank.finish
                index += 1
              end
              next
            end
            break
          end

          continuation = @lines[index]
          continuation_marker = list_marker(continuation.text, max_indent: nil)
          continuation_indent = indentation(continuation.text[/\A[ \t]*/].to_s)
          break if continuation_marker && continuation_marker[0] == base_indent

          if continuation_indent >= content_indent
            text, source_start = strip_indent(continuation, content_indent)
            fragments << FragmentLine.new(text: text, ending: continuation.ending,
                                          source_start: source_start, range_start: continuation.start)
            has_item_content ||= !text.empty?
            paragraph_open = paragraph_continuation?(text)
            item_end = continuation.finish
            index += 1
          elsif paragraph_open && paragraph_continuation?(continuation.text)
            fragments << FragmentLine.new(text: continuation.text, ending: continuation.ending,
                                          source_start: continuation.start, range_start: continuation.start)
            has_item_content ||= !continuation.text.empty?
            item_end = continuation.finish
            index += 1
          else
            break
          end
        end

        item_children = parse_fragment(fragments, preserve_list_indent: true)
        if task
          checkbox_start = content_start - (task[0].bytesize - task[2].bytesize)
          item_children.unshift(Node.new(type: :task_checkbox,
                                         attributes: { checked: attrs[:checked] }, children: [],
                                         range: checkbox_start...content_start, marker: task[1]))
        end
        items << make(:list_item, line.start, item_end, marker: marker, attributes: attrs, children: item_children)
      end
      list_type = ordered ? :ordered_list : :list
      [make(list_type, @lines[first].start, items.last.range.end, marker: list_marker_text,
            attributes: { ordered: ordered, start: initial[3] }, children: items), index]
    end

    def parse_link_definition(index)
      line = @lines[index]
      definition = @link_definition_lines.fetch(index)
      node = make(:link_definition, line.start, definition[:range].end, marker: "[", attributes: {
        label: definition[:label],
        normalized_label: definition[:normalized_label],
        destination: definition[:destination],
        title: definition[:title],
        destination_range: definition[:destination_range],
        title_range: definition[:title_range],
        effective: definition[:effective]
      })
      [node, definition[:last_index] + 1]
    end

    def parse_indented_code(index)
      first = index
      index += 1
      index += 1 while index < @lines.length && (indented_code_start?(@lines[index].text) || @lines[index].blank?)
      index -= 1 while index > first && @lines[index - 1].blank?
      last = @lines[index - 1]
      content = @lines[first...index].map { |line| strip_columns(line.text, 4) + line.ending }.join
      [make(:code_block, @lines[first].start, last.finish, marker: "    ",
            attributes: { info: "", fence: nil, text: content }), index]
    end

    def parse_html(index)
      first = index
      index += 1
      index += 1 while index < @lines.length && !@lines[index].blank?
      last = @lines[index - 1]
      [make(:html_block, @lines[first].start, last.finish, marker: nil,
            attributes: { text: @source.byteslice(@lines[first].start...last.finish) }), index]
    end

    def parse_comment_directive(index)
      line = @lines[index]
      match = /\A[ \t]*(<!--.*-->)[ \t]*\z/.match(line.text)
      raw = match[1]
      comment_start = line.start + byte_length(line.text[0...match.begin(1)])
      comment_range = comment_start...(comment_start + byte_length(raw))
      make(:directive, line.start, line.finish, marker: raw,
           attributes: { kind: :html_comment, values: Directive.parse(raw), comment_range: comment_range })
    end

    def parse_table(index)
      first = index
      head = table_cells(@lines[index])
      separator = table_cells(@lines[index + 1])
      aligns = separator.map do |cell|
        left, right = cell[:text].strip.start_with?(":"), cell[:text].strip.end_with?(":")
        left && right ? :center : (left ? :left : (right ? :right : nil))
      end
      separator_line = @lines[index + 1]
      rows = [table_row(@lines[index], head, :header, aligns),
              make(:table_separator, separator_line.start, separator_line.finish, marker: separator_line.text)]
      index += 2
      while index < @lines.length && @lines[index].text.include?("|") && !@lines[index].blank?
        rows << table_row(@lines[index], table_cells(@lines[index]), :body, aligns)
        index += 1
      end
      [make(:table, @lines[first].start, rows.last.range.end, marker: "|",
            attributes: { alignments: aligns }, children: rows), index]
    end

    def table_cells(line)
      text = line.text
      first = text.start_with?("|") ? 1 : 0
      last = text.end_with?("|") ? text.length - 1 : text.length
      cells = []
      start = first
      (first...last).each do |index|
        next unless text[index] == "|"

        cells << cell_data(text, start, index)
        start = index + 1
      end
      cells << cell_data(text, start, last)
      cells
    end

    def cell_data(text, first, last)
      raw = text[first...last]
      leading = raw[/\A[ \t]*/].to_s.length
      trailing = raw[/[ \t]*\z/].to_s.length
      from = first + leading
      to = [from, last - trailing].max
      { text: text[from...to], first: from, last: to }
    end

    def table_row(line, cells, kind, aligns)
      children = cells.each_with_index.map do |cell, index|
        start = line.start + byte_length(line.text[0...cell[:first]])
        finish = line.start + byte_length(line.text[0...cell[:last]])
        make(:table_cell, start, finish, marker: "|", attributes: { alignment: aligns[index] },
             children: inline_nodes(cell[:text], start))
      end
      make(:table_row, line.start, line.finish, marker: "|", attributes: { kind: kind }, children: children)
    end

    def parse_footnote(index)
      line = @lines[index]
      match = /\A {0,3}\[\^([^\]]+)\]:[ \t]*(.*)\z/.match(line.text)
      start = line.start + byte_length(line.text[0...match.begin(2)])
      finish = start + byte_length(match[2])
      [make(:footnote_definition, line.start, line.finish, marker: "[^#{match[1]}]:",
            attributes: { identifier: match[1], content_range: start...finish },
            children: inline_nodes(match[2], start)), index + 1]
    end

    def parse_heading(index)
      line = @lines[index]
      match = /\A {0,3}(\#{1,6})(?:[ \t]+|$)(.*)\z/.match(line.text)
      content = match[2].sub(/[ \t]+#+[ \t]*\z/, "")
      marker_start = line.start + byte_length(line.text[0...match.begin(1)])
      char_offset = match.begin(2)
      start = line.start + byte_length(line.text[0...char_offset])
      finish = start + byte_length(content)
      make(:heading, line.start, line.finish, marker: match[1],
           attributes: { level: match[1].length, content_range: start...finish,
                         marker_range: marker_start...(marker_start + byte_length(match[1])), style: :atx },
           children: inline_nodes(content, start))
    end

    def parse_paragraph(index)
      first = index
      index += 1
      index += 1 while index < @lines.length && !@lines[index].blank? &&
        !setext_level(@lines[index].text) && !interrupting?(@lines[index].text)
      if index < @lines.length && setext_level(@lines[index].text)
        last = @lines[index]
        content_line = @lines[index - 1]
        content = @source.byteslice(@lines[first].start...content_line.finish).sub(/(?:\r\n|\r|\n)\z/, "")
        finish = @lines[first].start + byte_length(content)
        level = setext_level(last.text)
        marker_start = last.start + byte_length(last.text[/\A */].to_s)
        marker_end = last.start + byte_length(last.text.rstrip)
        node = make(:heading, @lines[first].start, last.finish, marker: last.text.strip,
                    attributes: { level: level, content_range: @lines[first].start...finish,
                                  marker_range: marker_start...marker_end, style: :setext },
                    children: inline_nodes(content, @lines[first].start))
        return [node, index + 1]
      end
      last = @lines[index - 1]
      content = @source.byteslice(@lines[first].start...last.finish).sub(/(?:\r\n|\r|\n)\z/, "")
      start = @lines[first].start
      [make(:paragraph, start, last.finish,
            attributes: { content_range: start...(start + byte_length(content)) },
            children: inline_nodes(content, start)), index]
    end

    def make(type, first, last, marker: nil, attributes: {}, children: [])
      Node.new(type: type, range: first...last, marker: marker, attributes: attributes, children: children)
    end

    def inline_nodes(text, offset)
      InlineParser.new(text, offset, gfm: @gfm, references: @link_definitions).parse
    end

    def parse_fragment(lines, preserve_list_indent: false)
      source = +""
      starts = []
      ends = []
      list_starts = {}
      lines.each do |line|
        offset = source.bytesize
        starts[offset] = line.source_start
        ends[offset] ||= offset.zero? ? line.source_start : ends[offset - 1]
        list_starts[offset] = line.range_start
        append_fragment_text(source, line.text, line.source_start, starts, ends)
        append_fragment_text(source, line.ending, line.source_start + line.text.bytesize, starts, ends)
      end
      starts[0] ||= lines.first&.source_start || 0
      ends[0] ||= starts[0]

      parser = self.class.new(source, gfm: @gfm, front_matter: false,
                              inherited_link_definitions: @link_definitions)
      root, = parser.parse
      external_range_ids = @link_definitions.values.flat_map do |definition|
        definition.values_at(:range, :destination_range, :title_range)
      end.compact.map(&:object_id)
      root.children.map do |node|
        remap_fragment_node(node, starts, ends, list_starts, external_range_ids, preserve_list_indent)
      end
    end

    def append_fragment_text(source, text, source_start, starts, ends)
      offset = source.bytesize
      starts[offset] ||= source_start
      ends[offset] ||= source_start
      source << text
      (1..text.bytesize).each do |length|
        starts[offset + length] = source_start + length
        ends[offset + length] = source_start + length
      end
    end

    def remap_fragment_node(node, starts, ends, list_starts, external_range_ids, preserve_list_indent)
      children = node.children.map do |child|
        remap_fragment_node(child, starts, ends, list_starts, external_range_ids, preserve_list_indent)
      end
      range = remap_fragment_range(node.range, starts, ends)
      if preserve_list_indent && %i[list ordered_list].include?(node.type) && list_starts.key?(node.range.begin)
        range = list_starts.fetch(node.range.begin)...range.end
      end
      attributes = remap_fragment_value(node.attributes, starts, ends, external_range_ids)
      Node.new(type: node.type, attributes: attributes, children: children, range: range, marker: node.marker)
    end

    def remap_fragment_value(value, starts, ends, external_range_ids)
      case value
      when Range
        external_range_ids.include?(value.object_id) ? value : remap_fragment_range(value, starts, ends)
      when Array
        value.map { |item| remap_fragment_value(item, starts, ends, external_range_ids) }
      when Hash
        value.to_h do |key, item|
          [key, remap_fragment_value(item, starts, ends, external_range_ids)]
        end
      else
        value
      end
    end

    def remap_fragment_range(range, starts, ends)
      (starts[range.begin] || range.begin)...(ends[range.end] || range.end)
    end

    def paragraph_continuation?(text)
      !text.match?(/\A[ \t]*\z/) && !text.start_with?("    ", "\t") && !interrupting?(text)
    end

    def indented_code_start?(text)
      indentation(text[/\A[ \t]*/].to_s) >= 4
    end

    def strip_columns(text, columns)
      index = 0
      column = 0
      while index < text.length && column < columns && text[index].match?(/[ \t]/)
        if text[index] == "\t"
          next_column = (column / 4 + 1) * 4
          return (" " * (next_column - columns)) + text[(index + 1)..].to_s if next_column > columns

          column = next_column
        else
          column += 1
        end
        index += 1
      end
      text[index..].to_s
    end

    def strip_indent(line, columns)
      index = 0
      column = 0
      while index < line.text.length && column < columns && line.text[index].match?(/[ \t]/)
        column = line.text[index] == "\t" ? (column / 4 + 1) * 4 : column + 1
        index += 1
      end
      [line.text[index..].to_s, line.start + byte_length(line.text[0...index])]
    end

    def collect_link_definitions
      definitions = {}
      definition_lines = {}
      fence = nil
      html_block = false
      previous_definition_end = nil
      front_matter_end = if @front_matter && @lines.first&.text == "---"
        (1...@lines.length).find { |index| ["---", "..."].include?(@lines[index].text) }
      end
      index = 0
      while index < @lines.length
        if front_matter_end && index <= front_matter_end
          index += 1
          next
        end
        line = @lines[index]
        if fence
          fence = nil if line.text.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*\z/)
          index += 1
          next
        end

        if (opening = /\A {0,3}(`{3,}|~{3,})/.match(line.text))
          fence = opening[1]
          index += 1
          next
        end
        if html_block
          html_block = false if line.blank?
          index += 1
          next
        end
        if !directive_comment(line.text) && html_block_start?(line.text)
          html_block = true
          index += 1
          next
        end
        if indented_code_start?(line.text) || (@gfm && line.text.match?(/\A {0,3}\[\^[^\]]+\]:/))
          index += 1
          next
        end
        if index.positive? && !@lines[index - 1].blank? && previous_definition_end != index - 1 &&
          !link_definition_block_boundary?(@lines[index - 1].text)
          index += 1
          next
        end

        definition = link_definition_at(index)
        unless definition
          index += 1
          next
        end

        normalized = normalize_reference_label(definition[:label])
        definition[:normalized_label] = normalized
        definition[:effective] = !definitions.key?(normalized)
        definitions[normalized] ||= definition
        definition_lines[index] = definition
        previous_definition_end = definition[:last_index]
        index = definition[:last_index] + 1
      end
      [definitions.freeze, definition_lines.freeze]
    end

    def link_definition_at(index)
      line = @lines[index]
      prefix = LINK_DEFINITION_START.match(line.text)
      if prefix
        label = prefix[1]
        content = prefix[2]
        content_index = prefix.begin(2)
        destination_line = index
      else
        first_label = /\A {0,3}\[([^\]\n]+)\z/.match(line.text)
        continuation = @lines[index + 1]
        continuation_prefix = continuation && /\A {0,3}([^\[\]\n]+)\]:[ \t]*(.*)\z/.match(continuation.text)
        return unless first_label && continuation_prefix

        label = "#{first_label[1]} #{continuation_prefix[1]}"
        content = continuation_prefix[2]
        content_index = continuation_prefix.begin(2)
        destination_line = index + 1
      end
      if content.strip.empty?
        destination_line += 1
        return if destination_line >= @lines.length || @lines[destination_line].blank?

        content = @lines[destination_line].text
        content_index = 0
        content_index += 1 while content[content_index]&.match?(/[ \t]/)
        content = content[content_index..]
      end

      destination_match = LINK_DESTINATION.match(content)
      return unless destination_match

      raw_destination = destination_match[1]
      raw_destination_value = raw_destination.start_with?("<") ? raw_destination[1...-1] : raw_destination
      destination = unescape_punctuation(raw_destination_value)
      destination_start_index = content_index + destination_match.begin(1)
      destination_start = @lines[destination_line].start + byte_length(@lines[destination_line].text[0...destination_start_index])
      destination_start += 1 if raw_destination.start_with?("<")
      destination_range = destination_start...(destination_start + byte_length(raw_destination_value))
      tail_start = content_index + destination_match.end(1)
      tail = destination_match[2]
      last_index = destination_line
      title = nil
      title_range = nil

      unless tail.strip.empty?
        spacing = tail[/\A[ \t]*/].to_s.length
        return if spacing.zero?

        title_start = tail_start + spacing
        title_data = link_title_at(destination_line, title_start)
        return unless title_data

        title, title_range, last_index = title_data
      else
        next_index = destination_line + 1
        if next_index < @lines.length && !@lines[next_index].blank?
          leading = @lines[next_index].text[/\A[ \t]*/].to_s.length
          title_data = link_title_at(next_index, leading)
          if title_data
            title, title_range, last_index = title_data
          end
        end
      end

      {
        label: label, destination: destination, title: title,
        range: line.start...@lines[last_index].finish,
        destination_range: destination_range, title_range: title_range,
        last_index: last_index
      }
    end

    def link_title_at(line_index, character_index)
      opener = @lines[line_index].text[character_index]
      closer = { "\"" => "\"", "'" => "'", "(" => ")" }[opener]
      return unless closer

      title_start = @lines[line_index].start + byte_length(@lines[line_index].text[0...(character_index + 1)])
      index = line_index
      position = character_index + 1
      loop do
        line = @lines[index]
        while position < line.text.length
          if line.text[position] == closer && !escaped_in_line?(line.text, position)
            return unless line.text[(position + 1)..].match?(/\A[ \t]*\z/)

            title_end = line.start + byte_length(line.text[0...position])
            raw_title = @source.byteslice(title_start...title_end)
            return [unescape_punctuation(raw_title), title_start...title_end, index]
          end
          position += 1
        end
        index += 1
        return if index >= @lines.length || @lines[index].blank?

        position = 0
      end
    end

    def escaped_in_line?(text, index)
      slashes = 0
      index -= 1
      while index >= 0 && text[index] == "\\"
        slashes += 1
        index -= 1
      end
      slashes.odd?
    end

    def link_definition_block_boundary?(text)
      text.match?(/\A {0,3}(?:\#{1,6}(?:[ \t]|$)|>|`{3,}|~{3,}|(?:[-+*]|\d{1,9}[.)])[ \t]+|(?:[-*_][ \t]*){3,}|<(?!--)|<\/?(?:address|article|aside|blockquote|div|h[1-6]|hr|ol|p|pre|section|table|ul)(?:\s|\x2f?>))/i) ||
        text.match?(/\A {0,3}(?:=+|\*{3,}|-{3,})[ \t]*\z/)
    end

    def normalize_reference_label(label)
      label.gsub(/[[:space:]]+/, " ").strip.downcase(:fold)
    end

    def unescape_punctuation(text)
      text&.gsub(/\\([[:punct:]])/, "\\1")
    end

    def list_marker(text, max_indent: 3)
      match = /\A([ \t]*)([-+*]|(\d{1,9}[.)]))(?=[ \t]|\z)[ \t]*/.match(text)
      return nil unless match
      indent = indentation(match[1])
      return nil if max_indent && indent > max_indent

      [indent, match[2], !match[3].nil?, match[3]&.to_i || 0]
    end

    def same_list?(left, right)
      return false unless left && left[0] == right[0] && left[2] == right[2]

      left[2] ? left[1][-1] == right[1][-1] : left[1] == right[1]
    end

    def indentation(whitespace)
      whitespace.each_char.reduce(0) { |column, char| char == "\t" ? (column / 4 + 1) * 4 : column + 1 }
    end

    def interrupting?(text)
      text.match?(/\A {0,3}(?:\#{1,6}(?:[ \t]|$)|>|`{3,}|~{3,}|:::\s*(?:\S|$)|(?:[-+*]|\d{1,9}[.)])[ \t]+|(?:[-*_][ \t]*){3,}|<(?!--)|<\/?(?:address|article|aside|base|blockquote|body|caption|center|col|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|meta|nav|ol|optgroup|option|p|pre|script|section|source|style|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\s|\x2f?>))/i)
    end

    def thematic_break?(text)
      text.match?(/\A {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})\z/)
    end

    def setext_level(text)
      return 1 if text.match?(/\A {0,3}=+[ \t]*\z/)
      return 2 if text.match?(/\A {0,3}-+[ \t]*\z/)

      nil
    end

    def table_separator?(text)
      text && text.include?("|") && table_cells(Line.new(text: text)).all? { |cell| cell[:text].strip.match?(/\A:?-{3,}:?\z/) }
    end

    def html_block_start?(text)
      text.match?(/\A {0,3}(?:<!--|<\?|<!\[CDATA\[|<![A-Z]|<\/?(?:address|article|aside|base|blockquote|body|caption|center|col|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|meta|nav|ol|optgroup|option|p|pre|script|section|source|style|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul)(?:\s|\x2f?>))/i) ||
        text.match?(/\A {0,3}<\/?[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[^<>]*?)?\/?>(?:[ \t]*)\z/)
    end

    def directive_comment(text)
      match = /\A[ \t]*(<!--.*-->)[ \t]*\z/.match(text)
      match && Directive.parse(match[1])
    end

    def byte_length(text)
      text.to_s.bytesize
    end
  end
end

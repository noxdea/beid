# frozen_string_literal: true

module Beid
  class Parser
    LINK_DEFINITION_START = /\A {0,3}\[([^\]\n]+)\]:[ \t]*(.*)\z/
    LINK_DESTINATION = /\A(<[^>\n]*>|(?:\\.|[^\s])+)(.*)\z/

    Line = Struct.new(:text, :ending, :start, :finish, keyword_init: true) do
      def blank?
        text.match?(/\A[ \t]*\z/)
      end
    end

    def initialize(source, gfm: true, front_matter: true)
      @source, @gfm, @front_matter = source, gfm, front_matter
      @lines = source.valid_encoding? ? lines_for(source) : []
      @link_definitions, @link_definition_lines = collect_link_definitions
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
      return parse_list(index) if list_marker(text)
      return parse_indented_code(index) if text.start_with?("    ", "\t")
      return [parse_comment_directive(index), index + 1] if directive_comment(text)
      return parse_html(index) if html_block_start?(text)
      return parse_link_definition(index) if @link_definition_lines.key?(index)
      return parse_table(index) if @gfm && table_separator?(@lines[index + 1]&.text) && text.include?("|")
      return parse_footnote(index) if @gfm && text.match?(/\A {0,3}\[\^[^\]]+\]:/)
      return [parse_heading(index), index + 1] if (match = /\A {0,3}(\#{1,6})(?:[ \t]+|$)(.*)\z/.match(text))
      return [make(:thematic_break, line.start, line.finish, marker: text.strip), index + 1] if thematic_break?(text)

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
      [make(:code_block, opener.start, last.finish, marker: fence,
            attributes: { info: info, fence: fence, closed: !close.nil? }), finish_index]
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
      index += 1
      index += 1 while index < @lines.length && @lines[index].text.match?(/\A {0,3}>/)
      last = @lines[index - 1]
      children = []
      @lines[first...index].each do |line|
        match = /\A {0,3}> ?(.*)\z/.match(line.text)
        next unless match

        start = line.start + byte_length(line.text[0...match.begin(1)])
        finish = start + byte_length(match[1])
        children.concat(inline_nodes(match[1], start))
      end
      [make(:block_quote, @lines[first].start, last.finish, marker: ">", children: children), index]
    end

    def parse_list(index, nested: false)
      first = index
      initial = list_marker(@lines[index].text, max_indent: nested ? nil : 3)
      base_indent, list_marker_text, ordered = initial
      items = []
      while index < @lines.length
        current = list_marker(@lines[index].text, max_indent: nested ? nil : 3)
        break unless same_list?(current, initial)

        line = @lines[index]
        marker_match = /\A[ \t]*(?:([-+*])|(\d{1,9}[.)]))[ \t]+(.*)\z/.match(line.text)
        marker = marker_match[1] || marker_match[2]
        content = marker_match[3]
        content_start = line.start + byte_length(line.text[0...marker_match.begin(3)])
        content_finish = content_start + byte_length(content)
        task = @gfm && /\A\[([ xX])\](?:[ \t]+|$)(.*)\z/.match(content)
        if task
          content_start += byte_length(content[0...task.begin(2)])
          content, content_finish = task[2], content_start + byte_length(task[2])
        end
        attrs = { content_range: content_start...content_finish, ordered: ordered,
                  start: marker[/\A\d+/]&.to_i, task: !task.nil?, checked: task && task[1].downcase == "x" }
        item_children = inline_nodes(content, content_start)
        item_children.unshift(Node.new(type: :task_checkbox,
                                       attributes: { checked: attrs[:checked] }, children: [],
                                       range: (content_start - (task[0].bytesize - task[2].bytesize))...content_start,
                                       marker: task[1])) if task
        item_end = line.finish
        index += 1
        while index < @lines.length
          if @lines[index].blank?
            next_index = index + 1
            next_index += 1 while next_index < @lines.length && @lines[next_index].blank?
            marker_after_blank = list_marker(@lines[next_index]&.text.to_s, max_indent: nil)
            if marker_after_blank && marker_after_blank[0] > base_indent
              index = next_index
              child_list, index = parse_list(index, nested: true)
              item_children << child_list
              item_end = child_list.range.end
              next
            end
            break
          end

          child_marker = list_marker(@lines[index].text, max_indent: nil)
          if child_marker && child_marker[0] > base_indent
            child_list, index = parse_list(index, nested: true)
            item_children << child_list
            item_end = child_list.range.end
          elsif continuation_line?(@lines[index], base_indent)
            item_end = @lines[index].finish
            index += 1
          else
            break
          end
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
      index += 1 while index < @lines.length && (@lines[index].text.start_with?("    ", "\t") || @lines[index].blank?)
      index -= 1 while index > first && @lines[index - 1].blank?
      last = @lines[index - 1]
      [make(:code_block, @lines[first].start, last.finish, marker: "    ", attributes: { info: "", fence: nil }), index]
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
        if line.text.start_with?("    ", "\t") || (@gfm && line.text.match?(/\A {0,3}\[\^[^\]]+\]:/))
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
      return unless prefix

      content = prefix[2]
      content_index = prefix.begin(2)
      destination_line = index
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
        label: prefix[1], destination: destination, title: title,
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
      unescape_punctuation(label).gsub(/[[:space:]]+/, " ").strip.downcase(:fold)
    end

    def unescape_punctuation(text)
      text&.gsub(/\\([[:punct:]])/, "\\1")
    end

    def list_marker(text, max_indent: 3)
      match = /\A([ \t]*)([-+*]|(\d{1,9}[.)]))[ \t]+/.match(text)
      return nil unless match
      indent = indentation(match[1])
      return nil if max_indent && indent > max_indent

      [indent, match[2], !match[3].nil?, match[3]&.to_i || 0]
    end

    def same_list?(left, right)
      return false unless left && left[0] == right[0] && left[2] == right[2]

      left[2] ? left[1][-1] == right[1][-1] : left[1] == right[1]
    end

    def continuation_line?(line, indent)
      return false if line.blank?
      marker = list_marker(line.text, max_indent: nil)
      return marker && marker[0] > indent if marker

      whitespace = line.text[/\A[ \t]*/].to_s
      indentation(whitespace) >= indent + 2 && line.text.length > whitespace.length
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

# frozen_string_literal: true

module Beid
  class InlineParser
    TOKEN = /(`+)(.+?)\1|(!?)\[([^\]]*)\]\(([^\s()]*(?:\([^()]*\)[^\s()]*)*)(?:[ \t]+(?:"([^"]*)"|'([^']*)'))?\)|(\*\*|__|\*|_|~~)(?=\S)(.+?)\8/m
    AUTOLINK = /<([A-Za-z][A-Za-z0-9.+-]{1,31}:[^ <>]*)>|<([A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)>/
    HTML_INLINE = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<![A-Z][^>]*>|<\/[A-Za-z][A-Za-z0-9-]*[ \t\n]*>|<[A-Za-z][A-Za-z0-9-]*(?:[ \t\n]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t\n]*=[ \t\n]*(?:[^ \t\n\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*[ \t\n]*\/?>/
    REFERENCE_START = /!?\[/
    Reference = Struct.new(:start, :finish, :image, :label, :label_start, :label_end,
                           :reference_label, :definition, keyword_init: true)
    CodeRun = Struct.new(:start, :finish, :length, keyword_init: true)
    CodeSpan = Struct.new(:start, :finish, :marker, :text, keyword_init: true)
    Break = Struct.new(:start, :finish, :type, :marker, keyword_init: true)
    DelimiterMatch = Struct.new(:start, :finish, :marker, :inner_start, :inner_finish, keyword_init: true)
    InlineLink = Struct.new(:start, :finish, :image, :label, :label_start, :label_finish,
                            :destination, :destination_range, :title, :title_range, keyword_init: true)

    def initialize(source, base_offset, gfm: true, references: {})
      @source, @base_offset, @gfm, @references = source, base_offset, gfm, references
      @code_runs = code_runs
      @code_closers = {}
      next_run_by_length = {}
      @code_runs.reverse_each do |run|
        @code_closers[run.start] = next_run_by_length[run.length]
        next_run_by_length[run.length] = run
      end
    end

    def parse
      return [] unless @source && !@source.empty? && @source.valid_encoding?

      nodes = []
      cursor = 0
      while cursor < @source.length
        match = next_inline_match(cursor)
        inline_link = next_inline_link(cursor)
        code_span = next_code_span(cursor)
        line_break = next_line_break(cursor)
        html_inline = next_html_inline(cursor)
        footnote = /\[\^([^\]]+)\]/.match(@source, cursor) if @gfm
        autolink = next_autolink(cursor)
        if match.is_a?(MatchData) && autolink && ((match[3] && autolink.begin(0) < match.end(0) && autolink.end(0) > match.end(0)) ||
          (match[8] && autolink.begin(0) <= match.end(9) && match.end(9) < autolink.end(0)))
          match = nil
        elsif match.is_a?(DelimiterMatch) && autolink &&
          autolink.begin(0) <= match.inner_finish && match.inner_finish < autolink.end(0)
          match = nil
        end
        if inline_link && autolink && inline_link.start < autolink.begin(0) &&
          autolink.begin(0) < inline_link.finish && inline_link.finish < autolink.end(0)
          inline_link = nil
        end
        if inline_link && code_span && inline_link.start < code_span.start &&
          code_span.start <= inline_link.label_finish && inline_link.label_finish < code_span.finish
          inline_link = nil
        end
        if inline_link && html_inline && inline_link.start < html_inline.begin(0) &&
          html_inline.begin(0) < inline_link.finish && inline_link.finish < html_inline.end(0)
          inline_link = nil
        end
        if inline_link && match.is_a?(DelimiterMatch) && match.start < inline_link.start &&
          inline_link.start < match.inner_finish && match.inner_finish <= inline_link.label_finish
          match = nil
        end
        reference = next_reference(cursor)
        if match.is_a?(MatchData) && match[8] && reference && match.begin(0) < reference.start &&
          match.end(9) > reference.start && match.end(9) < reference.finish
          match = nil
        elsif match.is_a?(DelimiterMatch) && reference && match.start < reference.start &&
          match.inner_finish > reference.start && match.inner_finish < reference.finish
          match = nil
        end
        if reference && code_span && reference.start < code_span.start &&
          code_span.start < reference.finish && reference.finish < code_span.finish
          reference = nil
        end
        if reference && html_inline && reference.start < html_inline.begin(0) &&
          html_inline.begin(0) < reference.finish && reference.finish < html_inline.end(0)
          reference = nil
        end
        candidates = [[:inline_link, inline_link], [:inline, match], [:code, code_span], [:break, line_break],
                      [:html, html_inline], [:footnote, footnote],
                      [:autolink, autolink], [:reference, reference]]
          .compact.reject { |_kind, candidate| candidate.nil? }
        kind, candidate = candidates.min_by { |candidate_kind, value| [candidate_start(candidate_kind, value), candidate_priority(candidate_kind)] }
        start = candidate && candidate_start(kind, candidate)
        unless candidate && start == cursor
          next_cursor = start || @source.length
          nodes << text_node(cursor, next_cursor)
          cursor = next_cursor
          next
        end

        if kind == :footnote
          match = candidate
          nodes << node(:footnote_reference, cursor, match.end(0), "[^",
                        { identifier: match[1] })
        elsif kind == :break
          nodes << node(candidate.type, candidate.start, candidate.finish, candidate.marker)
        elsif kind == :html
          nodes << node(:html_inline, candidate.begin(0), candidate.end(0), nil, text: candidate[0])
        elsif kind == :inline_link
          image = candidate.image
          children = if image
            []
          else
            InlineParser.new(candidate.label, @base_offset + byte_offset(candidate.label_start),
                             gfm: @gfm, references: @references).parse
          end
          nodes << node(image ? :image : :link, candidate.start, candidate.finish, image ? "![" : "[", {
            label: candidate.label,
            destination: candidate.destination,
            title: candidate.title,
            destination_range: range_for_offsets(*candidate.destination_range),
            title_range: candidate.title_range && range_for_offsets(*candidate.title_range),
            label_range: range_for_offsets(candidate.label_start, candidate.label_finish)
          }, children)
        elsif kind == :code
          nodes << node(:code_span, cursor, candidate.finish, candidate.marker, text: candidate.text)
        elsif candidate.is_a?(DelimiterMatch)
          body = @source[candidate.inner_start...candidate.inner_finish]
          type = case candidate.marker
          when "**", "__" then :strong
          when "~~" then @gfm ? :strikethrough : nil
          else :emphasis
          end
          if type
            children = InlineParser.new(body, @base_offset + byte_offset(candidate.inner_start),
                                        gfm: @gfm, references: @references).parse
            nodes << node(type, candidate.start, candidate.finish, candidate.marker, { text: body }, children)
          else
            nodes << text_node(candidate.start, candidate.finish)
          end
        elsif kind == :autolink
          nodes << parse_autolink(candidate)
        elsif kind == :reference
          nodes << parse_reference(candidate)
        elsif match[3]
          match = candidate
          image = match[3] == "!"
          label = match[4]
          destination = unescape_punctuation(match[5])
          title = unescape_punctuation(match[6] || match[7])
          title_range = if match[6]
            range_for_capture(6, match)
          elsif match[7]
            range_for_capture(7, match)
          end
          type = image ? :image : :link
          children = image ? [] : InlineParser.new(label, @base_offset + byte_offset(cursor) + 1, gfm: @gfm).parse
          nodes << node(type, cursor, match.end(0), image ? "![" : "[", {
            label: label, destination: destination, title: title,
            destination_range: range_for_capture(5, match),
            title_range: title_range,
            label_range: range_for_capture(4, match)
          }, children)
        else
          match = candidate
          marker = match[8]
          next_cursor = match.end(0)
          type = case marker
          when "**", "__" then :strong
          when "~~" then @gfm ? :strikethrough : nil
          else :emphasis
          end
          if type
            inner_begin = match.begin(9)
            inner_end = match.end(9)
            children = InlineParser.new(@source[inner_begin...inner_end], @base_offset + byte_offset(inner_begin), gfm: @gfm).parse
            nodes << node(type, cursor, next_cursor, marker, { text: @source[inner_begin...inner_end] }, children)
          else
            nodes << text_node(cursor, next_cursor)
          end
        end
        cursor = %i[inline_link reference code break].include?(kind) || candidate.is_a?(DelimiterMatch) ? candidate.finish : candidate.end(0)
      end
      nodes
    end

    private

    def candidate_start(kind, candidate)
      return candidate.start if %i[inline_link reference code break].include?(kind) || candidate.is_a?(DelimiterMatch)

      candidate.begin(0)
    end

    def candidate_priority(kind)
      { inline_link: 0, inline: 1, code: 2, break: 3, html: 4, footnote: 5, autolink: 6, reference: 7 }.fetch(kind)
    end

    def next_inline_match(cursor)
      match = TOKEN.match(@source, cursor)
      while match
        if match[1]
          next_start = match.begin(1)
          next_start += 1 while next_start < @source.length && @source[next_start] == "`"
          match = TOKEN.match(@source, next_start)
        elsif match[8]
          delimiter_match = find_delimiter_match(match)
          return delimiter_match if delimiter_match

          match = TOKEN.match(@source, match.begin(8) + match[8].length)
        elsif match[3]
          # Direct links are parsed by inline_link_at so malformed link syntax
          # cannot be accepted by the older, more permissive token expression.
          match = TOKEN.match(@source, match.begin(0) + 1)
        elsif escaped?(match.begin(0))
          match = TOKEN.match(@source, match.end(0))
        else
          break
        end
      end
      match
    end

    def next_inline_link(cursor)
      search = cursor
      while (start = @source.index(REFERENCE_START, search))
        image = @source[start] == "!"
        bracket = start + (image ? 1 : 0)
        closing = closing_bracket(bracket)
        if closing
          link = inline_link_at(start, image, bracket, closing)
          return link if link && (image || !nested_inline_link?(bracket + 1, closing))
        end
        search = start + 1
      end
      nil
    end

    def inline_link_at(start, image, bracket, closing)
      opening_paren = closing + 1
      return unless @source[opening_paren] == "("

      cursor = skip_link_whitespace(opening_paren + 1)
      destination, destination_range, cursor = link_destination(cursor)
      return unless destination_range

      whitespace_end = skip_link_whitespace(cursor)
      title = nil
      title_range = nil
      if whitespace_end > cursor && ["\"", "'", "("].include?(@source[whitespace_end])
        title_data = link_title(whitespace_end)
        return unless title_data

        title, title_range, cursor = title_data
        cursor = skip_link_whitespace(cursor)
      else
        cursor = whitespace_end
      end
      return unless @source[cursor] == ")"

      InlineLink.new(start: start, finish: cursor + 1, image: image,
                     label: @source[(bracket + 1)...closing], label_start: bracket + 1,
                     label_finish: closing, destination: unescape_punctuation(destination),
                     destination_range: destination_range, title: title && unescape_punctuation(title),
                     title_range: title_range)
    end

    def link_destination(cursor)
      if @source[cursor] == "<"
        destination_start = cursor + 1
        index = destination_start
        while index < @source.length
          character = @source[index]
          return unless character && !character.match?(/[\r\n]/)
          return if character == "<" && !escaped?(index)
          return if character == ">" && escaped?(index)
          break if character == ">"

          index += 1
        end
        return unless @source[index] == ">"

        return [@source[destination_start...index], [destination_start, index], index + 1]
      end

      start = cursor
      index = cursor
      depth = 0
      while index < @source.length
        character = @source[index]
        break if character.match?(/[ \t\r\n]/)
        if character == "\\" && index + 1 < @source.length
          index += 2
          next
        elsif character == "<"
          return
        elsif character == "("
          depth += 1
          return if depth > 32
        elsif character == ")"
          break if depth.zero?

          depth -= 1
        end
        index += 1
      end
      return unless depth.zero?

      [@source[start...index], [start, index], index]
    end

    def link_title(cursor)
      opening = @source[cursor]
      closer = { "\"" => "\"", "'" => "'", "(" => ")" }[opening]
      return unless closer

      start = cursor + 1
      index = start
      depth = 1
      while index < @source.length
        character = @source[index]
        if character == "\\" && index + 1 < @source.length
          index += 2
          next
        elsif character == closer
          if opening != "(" || (depth -= 1).zero?
            return [@source[start...index], [start, index], index + 1]
          end
        elsif opening == "(" && character == "("
          depth += 1
        end
        index += 1
      end
      nil
    end

    def nested_inline_link?(start, finish)
      search = start
      while (nested_start = @source.index(REFERENCE_START, search))
        break if nested_start >= finish

        next_search = nested_start + 1
        if @source[nested_start] != "!" && (nested_start.zero? || @source[nested_start - 1] != "!")
          closing = closing_bracket(nested_start)
          if closing && closing < finish
            return true if inline_link_at(nested_start, false, nested_start, closing)

            suffix = closing + 1
            if @source[suffix] == "["
              reference_end = closing_bracket(suffix)
              if reference_end && reference_end < finish
                label = @source[(suffix + 1)...reference_end]
                label = @source[(nested_start + 1)...closing] if label.empty?
                return true if @references.key?(normalize_reference_label(label))
              end
            else
              label = @source[(nested_start + 1)...closing]
              return true if @references.key?(normalize_reference_label(label))
            end
          end
        end
        search = next_search
      end
      false
    end

    def skip_link_whitespace(index)
      index += 1 while index < @source.length && @source[index].match?(/[ \t\r\n]/)
      index
    end

    def find_delimiter_match(match)
      marker = match[8]
      opening_start = match.begin(8)
      return if escaped?(opening_start)
      opening_length = delimiter_run_length(opening_start, marker[0])
      opening_marker = marker[0] * opening_length
      return unless can_open_delimiter?(opening_start, opening_marker)

      search = opening_start + opening_length
      ignored = [next_code_span(search), next_html_inline(search)].compact.map do |span|
        span.respond_to?(:start) ? (span.start...span.finish) : (span.begin(0)...span.end(0))
      end
      nested_openers = 0
      while (closing_start = @source.index(marker[0], search))
        closing_length = delimiter_run_length(closing_start, marker[0])
        if ignored.any? { |range| range.cover?(closing_start) }
          span = ignored.find { |range| range.cover?(closing_start) }
          search = span.end
          next
        end
        if !escaped?(closing_start)
          closing_marker = marker[0] * closing_length
          can_open = can_open_delimiter?(closing_start, closing_marker)
          can_close = can_close_delimiter?(closing_start, closing_marker)
          if can_open && !can_close
            nested_openers += 1
          elsif can_close && nested_openers.positive?
            nested_openers -= 1
          elsif can_close && closing_start > opening_start + opening_length - 1 &&
              !rule_of_three?(opening_start, closing_start, marker[0])
            match_data = delimiter_pair(opening_start, opening_length, closing_start, closing_length, marker)
            return match_data if match_data
          end
        end
        search = closing_start + [closing_length, 1].max
      end
      nil
    end

    def delimiter_pair(opening_start, opening_length, closing_start, closing_length, marker)
      if marker == "~~"
        return unless opening_length == 2 && closing_length == 2

        return DelimiterMatch.new(start: opening_start, finish: closing_start + 2,
                                  marker: marker, inner_start: opening_start + 2,
                                  inner_finish: closing_start)
      end

      width = if opening_length >= 2 && closing_length >= 2
        opening_length.odd? && closing_length.odd? ? 1 : 2
      elsif opening_length >= 2
        1
      else
        1
      end
      start = opening_start
      if width == 1 && opening_length >= 3 && closing_length >= 2 && closing_length.even?
        start += 1
        width = 2
      end
      return if opening_length - (start - opening_start) < width || closing_length < width

      close = closing_start
      close += closing_length - width if width == 1 && opening_length >= 3 && closing_length >= 3
      tag = marker[0] * width
      DelimiterMatch.new(start: start, finish: close + width, marker: tag,
                         inner_start: start + width, inner_finish: close)
    end

    def can_open_delimiter?(start, marker)
      before = start.positive? ? @source[start - 1] : nil
      after = @source[start + marker.length]
      left, right = flanking?(before, after)
      left && (marker[0] != "_" || !right || punctuation?(before))
    end

    def can_close_delimiter?(start, marker)
      before = start.positive? ? @source[start - 1] : nil
      after = @source[start + marker.length]
      left, right = flanking?(before, after)
      right && (marker[0] != "_" || !left || punctuation?(after))
    end

    def flanking?(before, after)
      before_space = before.nil? || before.match?(/\p{Space}/)
      after_space = after.nil? || after.match?(/\p{Space}/)
      before_punctuation = punctuation?(before)
      after_punctuation = punctuation?(after)
      left = !after_space && (!after_punctuation || before_space || before_punctuation)
      right = !before_space && (!before_punctuation || after_space || after_punctuation)
      [left, right]
    end

    def punctuation?(character)
      character && character.match?(/[\p{P}\p{S}]/)
    end

    def rule_of_three?(opening_start, closing_start, marker)
      opening_length = delimiter_run_length(opening_start, marker[0])
      closing_length = delimiter_run_length(closing_start, marker[0])
      opening_can_close = can_close_delimiter?(opening_start, marker[0] * opening_length)
      closing_can_open = can_open_delimiter?(closing_start, marker[0] * closing_length)
      (opening_can_close || closing_can_open) && ((opening_length + closing_length) % 3).zero? &&
        (opening_length % 3 != 0 || closing_length % 3 != 0)
    end

    def delimiter_run_length(start, character)
      finish = start
      finish += 1 while finish < @source.length && @source[finish] == character && !escaped?(finish)
      finish - start
    end

    def next_autolink(cursor)
      match = AUTOLINK.match(@source, cursor)
      while match && escaped?(match.begin(0))
        match = AUTOLINK.match(@source, match.end(0))
      end
      match
    end

    def next_html_inline(cursor)
      match = HTML_INLINE.match(@source, cursor)
      while match && escaped?(match.begin(0))
        match = HTML_INLINE.match(@source, match.end(0))
      end
      match
    end

    def next_line_break(cursor)
      search = cursor
      while (newline = /\r\n|\r|\n/.match(@source, search))
        newline_start = newline.begin(0)
        slash_count = 0
        slash_index = newline_start - 1
        while slash_index >= cursor && @source[slash_index] == "\\"
          slash_count += 1
          slash_index -= 1
        end
        if slash_count.odd?
          start = newline_start - 1
          marker = "\\"
          type = :linebreak
        else
          space_index = newline_start - 1
          space_index -= 1 while space_index >= cursor && @source[space_index].match?(/[ \t]/)
          spaces = newline_start - space_index - 1
          start = spaces >= 2 ? newline_start - spaces : newline_start
          marker = spaces >= 2 ? @source[start...newline_start] : nil
          type = spaces >= 2 ? :linebreak : :softbreak
        end
        return Break.new(start: start, finish: newline.end(0), type: type, marker: marker) if start >= cursor

        search = newline.end(0)
      end
      nil
    end

    def next_code_span(cursor)
      index = @code_runs.bsearch_index { |run| run.start >= cursor } || @code_runs.length
      while index < @code_runs.length
        opening = @code_runs[index]
        if escaped?(opening.start)
          index += 1
          next
        end
        closing = @code_closers[opening.start]
        if closing
          text = @source[opening.finish...closing.start].gsub(/\r\n|\r|\n/, " ")
          text = text[1...-1] if text.start_with?(" ") && text.end_with?(" ") && !text.match?(/\A +\z/)
          marker = @source[opening.start...opening.finish]
          return CodeSpan.new(start: opening.start, finish: closing.finish, marker: marker, text: text)
        end
        index += 1
      end
      nil
    end

    def code_runs
      runs = []
      index = 0
      while (start = @source.index("`", index))
        finish = start + 1
        finish += 1 while finish < @source.length && @source[finish] == "`"
        runs << CodeRun.new(start: start, finish: finish, length: finish - start)
        index = finish
      end
      runs
    end

    def parse_autolink(match)
      label = match[1] || match[2]
      first, last = match.begin(0), match.end(0)
      label_first, label_last = match.begin(0) + 1, match.end(0) - 1
      destination = match[2] ? "mailto:#{label}" : label
      child = node(:text, label_first, label_last, nil, text: label, literal: true)
      node(:link, first, last, "<", {
        label: label, destination: destination, title: nil, autolink: true,
        destination_range: range_for_offsets(label_first, label_last)
      }, [child])
    end

    def parse_reference(reference)
      definition = reference.definition
      type = reference.image ? :image : :link
      children = if reference.image
        []
      else
        InlineParser.new(reference.label, @base_offset + byte_offset(reference.label_start),
                         gfm: @gfm, references: @references).parse
      end
      node(type, reference.start, reference.finish, reference.image ? "![" : "[", {
        label: reference.label,
        destination: definition[:destination],
        title: definition[:title],
        reference_label: reference.reference_label,
        definition_range: definition[:range],
        destination_range: definition[:destination_range],
        label_range: range_for_offsets(reference.label_start, reference.label_end)
      }, children)
    end

    def next_reference(cursor)
      search = cursor
      while (start = @source.index(REFERENCE_START, search))
        image = @source[start] == "!"
        bracket = start + (image ? 1 : 0)
        unless @source[bracket] == "[" && !escaped?(start)
          search = start + 1
          next
        end

        label_start = bracket + 1
        label_end = closing_bracket(bracket)
        unless label_end && label_end > label_start
          search = start + 1
          next
        end

        label = @source[label_start...label_end]
        suffix = reference_suffix_start(label_end + 1)
        if @source[suffix] == "["
          reference_end = closing_bracket(suffix)
          unless reference_end
            search = start + 1
            next
          end
          reference_label = @source[(suffix + 1)...reference_end]
          reference_label = label if reference_label.empty?
          finish = reference_end + 1
        else
          reference_label = label
          finish = label_end + 1
        end

        autolink = AUTOLINK.match(@source, start)
        if autolink && autolink.begin(0) < finish && autolink.end(0) > finish
          search = start + 1
          next
        end

        if !image && nested_inline_link?(label_start, label_end)
          search = start + 1
          next
        end

        definition = @references[normalize_reference_label(reference_label)]
        return Reference.new(start: start, finish: finish, image: image, label: label,
                             label_start: label_start, label_end: label_end,
                             reference_label: reference_label, definition: definition) if definition

        search = start + 1
      end
      nil
    end

    def closing_bracket(opening)
      depth = 0
      index = opening
      while index < @source.length
        if escaped?(index)
          index += 1
          next
        end
        depth += 1 if @source[index] == "["
        if @source[index] == "]"
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end
      nil
    end

    def escaped?(index)
      slashes = 0
      index -= 1
      while index >= 0 && @source[index] == "\\"
        slashes += 1
        index -= 1
      end
      slashes.odd?
    end

    def reference_suffix_start(index)
      index
    end

    def normalize_reference_label(label)
      label.gsub(/[[:space:]]+/, " ").strip.downcase(:fold)
    end

    def unescape_punctuation(text)
      text&.gsub(/\\([[:punct:]])/, "\\1")
    end

    def text_node(first, last)
      text = unescape_punctuation(@source[first...last])
      node(:text, first, last, nil, text: text)
    end

    def node(type, first, last, marker, attributes = {}, children = [])
      Node.new(type: type, attributes: attributes, children: children,
               range: (@base_offset + byte_offset(first))...(@base_offset + byte_offset(last)), marker: marker)
    end

    def byte_offset(character_offset)
      @source[0...character_offset].bytesize
    end

    def range_for_capture(index, match)
      range_for_offsets(match.begin(index), match.end(index))
    end

    def range_for_offsets(first, last)
      first = @base_offset + byte_offset(first)
      last = @base_offset + byte_offset(last)
      first...last
    end
  end
end

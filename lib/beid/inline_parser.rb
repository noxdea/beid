# frozen_string_literal: true

module Beid
  class InlineParser
    TOKEN = /(`+)(.+?)\1|(!?)\[([^\]]*)\]\(([^\s()]*(?:\([^()]*\)[^\s()]*)*)(?:[ \t]+(?:"([^"]*)"|'([^']*)'))?\)|(\*\*|__|\*|_|~~)(?=\S)(.+?)\8(?![\p{Word}])/m
    AUTOLINK = /<([A-Za-z][A-Za-z0-9.+-]{1,31}:[^ <>]*)>|<([A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)>/
    REFERENCE_START = /!?\[/
    Reference = Struct.new(:start, :finish, :image, :label, :label_start, :label_end,
                           :reference_label, :definition, keyword_init: true)
    CodeRun = Struct.new(:start, :finish, :length, keyword_init: true)
    CodeSpan = Struct.new(:start, :finish, :marker, :text, keyword_init: true)

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
        code_span = next_code_span(cursor)
        footnote = /\[\^([^\]]+)\]/.match(@source, cursor) if @gfm
        autolink = AUTOLINK.match(@source, cursor)
        if match && autolink && ((match[3] && autolink.begin(0) < match.end(0) && autolink.end(0) > match.end(0)) ||
          (match[8] && autolink.begin(0) <= match.end(9) && match.end(9) < autolink.end(0)))
          match = nil
        end
        reference = next_reference(cursor)
        if match && match[8] && reference && match.begin(0) < reference.start &&
          match.end(9) > reference.start && match.end(9) < reference.finish
          match = nil
        end
        candidates = [[:inline, match], [:code, code_span], [:footnote, footnote],
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
        elsif kind == :code
          nodes << node(:code_span, cursor, candidate.finish, candidate.marker, text: candidate.text)
        elsif kind == :autolink
          nodes << parse_autolink(candidate)
        elsif kind == :reference
          nodes << parse_reference(candidate)
        elsif match[3]
          match = candidate
          image = match[3] == "!"
          label, destination, title = match[4], match[5], match[6] || match[7]
          type = image ? :image : :link
          children = image ? [] : InlineParser.new(label, @base_offset + byte_offset(cursor) + 1, gfm: @gfm).parse
          nodes << node(type, cursor, match.end(0), image ? "![" : "[", {
            label: label, destination: destination, title: title,
            destination_range: range_for_capture(5, match),
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
        cursor = %i[reference code].include?(kind) ? candidate.finish : candidate.end(0)
      end
      nodes
    end

    private

    def candidate_start(kind, candidate)
      %i[reference code].include?(kind) ? candidate.start : candidate.begin(0)
    end

    def candidate_priority(kind)
      { inline: 0, code: 1, footnote: 2, autolink: 3, reference: 4 }.fetch(kind)
    end

    def next_inline_match(cursor)
      match = TOKEN.match(@source, cursor)
      while match && match[1]
        next_start = match.begin(1)
        next_start += 1 while next_start < @source.length && @source[next_start] == "`"
        match = TOKEN.match(@source, next_start)
      end
      match
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
      child = node(:text, label_first, label_last, nil, text: label)
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
      whitespace = /\A[ \t]*(?:(?:\r\n|\r|\n)[ \t]*)?/.match(@source[index..])
      index + whitespace[0].length
    end

    def normalize_reference_label(label)
      label.gsub(/\\([[:punct:]])/, "\\1").gsub(/[[:space:]]+/, " ").strip.downcase(:fold)
    end

    def text_node(first, last)
      node(:text, first, last, nil, text: @source[first...last])
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

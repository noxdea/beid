# frozen_string_literal: true

module Beid
  class InlineParser
    TOKEN = /(`+)(.+?)\1|(!?)\[([^\]]*)\]\(([^\s()]*(?:\([^()]*\)[^\s()]*)*)(?:[ \t]+(?:"([^"]*)"|'([^']*)'))?\)|(\*\*|__|\*|_|~~)(?=\S)(.+?)\8(?!\S)/m

    def initialize(source, base_offset, gfm: true)
      @source, @base_offset, @gfm = source, base_offset, gfm
    end

    def parse
      return [] unless @source && !@source.empty? && @source.valid_encoding?

      nodes = []
      cursor = 0
      while cursor < @source.length
        match = TOKEN.match(@source, cursor)
        footnote = /\[\^([^\]]+)\]/.match(@source, cursor) if @gfm
        if footnote && (!match || footnote.begin(0) < match.begin(0))
          match = footnote
          footnote = match
        end
        unless match && match.begin(0) == cursor
          next_cursor = match ? match.begin(0) : @source.length
          nodes << text_node(cursor, next_cursor)
          cursor = next_cursor
          next
        end

        if footnote && match.equal?(footnote)
          nodes << node(:footnote_reference, cursor, match.end(0), "[^",
                        { identifier: match[1] })
        elsif match[1]
          marker = match[1]
          nodes << node(:code_span, cursor, match.end(0), marker, text: match[2])
        elsif match[3]
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
        cursor = match.end(0)
      end
      nodes
    end

    private

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
      first = @base_offset + byte_offset(match.begin(index))
      last = @base_offset + byte_offset(match.end(index))
      first...last
    end
  end
end

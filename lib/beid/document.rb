# frozen_string_literal: true

module Beid
  class Document
    attr_reader :source, :root, :front_matter, :options, :diagnostics

    def self.parse(text, gfm: true, front_matter: true)
      raise TypeError, "source must be a String" unless text.is_a?(String)

      source = text.dup.freeze
      options = { gfm: gfm, front_matter: front_matter }.freeze
      root, raw_front_matter, diagnostics = Parser.new(source, **options).parse
      new(source, root, raw_front_matter, options, diagnostics)
    end

    def initialize(source, root, front_matter, options, diagnostics)
      @source, @root, @front_matter = source, root, front_matter&.freeze
      @options, @diagnostics = options, diagnostics.freeze
      @nodes = {}
      walk(@root) { |node| @nodes[node.object_id] = node }
    end

    def nodes_at(offset)
      check_offset(offset)
      return [@root] if @source.empty? && offset.zero?
      return [] unless @root.range.cover?(offset)

      result = [@root]
      current = @root
      loop do
        child = current.children.find { |entry| entry.range.cover?(offset) }
        break unless child

        result << child
        current = child
      end
      result
    end

    def node_at(offset)
      nodes_at(offset).last
    rescue RangeError
      nil
    end

    def range_of(node)
      raise TypeError, "node must be a Beid::Node" unless node.is_a?(Node)
      raise ArgumentError, "node does not belong to this document" unless @nodes[node.object_id].equal?(node)

      node.range
    end

    # Returns zero-based [line, Unicode-codepoint column] for a UTF-8 byte offset.
    def position_at(offset)
      check_offset(offset)
      raise EncodingError, "positions require valid UTF-8" unless @source.valid_encoding?

      line_index = line_index_at(offset)
      start = line_starts[line_index]
      prefix = @source.byteslice(start...offset).to_s.sub(/(?:\r\n|\r|\n)\z/, "")
      [line_index, prefix.length]
    end

    # Returns zero-based LSP [line, UTF-16 code-unit column].
    def utf16_position_at(offset)
      line, = position_at(offset)
      start = line_starts[line]
      prefix = @source.byteslice(start...offset).to_s.sub(/(?:\r\n|\r|\n)\z/, "")
      [line, prefix.encode("UTF-16LE").bytesize / 2]
    end

    def valid?
      @source.valid_encoding? && @diagnostics.empty?
    end

    def to_s
      @source
    end

    def include_node?(node)
      node.is_a?(Node) && @nodes[node.object_id].equal?(node)
    end

    private

    def walk(node, &block)
      yield node
      node.children.each { |child| walk(child, &block) }
    end

    def check_offset(offset)
      unless offset.is_a?(Integer) && (0..@source.bytesize).cover?(offset)
        raise RangeError, "Byte offset is outside the document"
      end
      if @source.valid_encoding? && offset < @source.bytesize && (@source.getbyte(offset) & 0xc0) == 0x80
        raise RangeError, "Byte offset splits a UTF-8 character"
      end
    end

    def line_index_at(offset)
      (line_starts.bsearch_index { |start| start > offset } || line_starts.length) - 1
    end

    def line_starts
      @line_starts ||= begin
        starts = [0]
        @source.b.to_enum(:scan, /\r\n|\r|\n/n).each { starts << Regexp.last_match.end(0) }
        starts
      end
    end
  end
end

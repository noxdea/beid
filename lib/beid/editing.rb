# frozen_string_literal: true

module Beid
  module Editing
    def self.replace(document, node, markdown)
      document.range_of(node)
      raise TypeError, "markdown must be a String" unless markdown.is_a?(String)
      terminator = document.source.byteslice(node.range.end - 2...node.range.end).to_s
      terminator = document.source.byteslice(node.range.end - 1...node.range.end).to_s unless ["\r\n", "\n", "\r"].include?(terminator)
      markdown += terminator if !markdown.empty? && ["\r\n", "\n", "\r"].include?(terminator) && !markdown.end_with?("\r", "\n")
      edit_range(document, node, node.range, markdown)
    end

    def self.replace_text(document, node, text)
      raise TypeError, "text must be a String" unless text.is_a?(String)
      if node.type == :code_span
        marker_size = [node.marker.length, text.scan(/`+/).map(&:length).max.to_i + 1].max
        marker = "`" * marker_size
        return edit(document, node, "#{marker}#{text}#{marker}")
      end
      range = case node.type
      when :text
        document.range_of(node)
      when :heading, :paragraph, :footnote_definition
        node.attributes.fetch(:content_range)
      when :link, :image
        node.attributes.fetch(:label_range)
      when :emphasis, :strong, :strikethrough
        node.range.begin + node.marker.bytesize...(node.range.end - node.marker.bytesize)
      else
        raise ArgumentError, "#{node.type} does not have replaceable text"
      end
      edit_range(document, node, range, escape_text(text))
    end

    def self.insert_after(document, node, markdown)
      insert(document, node, markdown, after: true)
    end

    def self.insert_before(document, node, markdown)
      insert(document, node, markdown, after: false)
    end

    def self.remove(document, node)
      edit(document, node, "")
    end

    def self.set_attribute(document, node, key, value)
      document.range_of(node)
      case [node.type, key.to_sym]
      when [:heading, :level]
        level = Integer(value)
        raise ArgumentError, "heading level must be between 1 and 6" unless (1..6).cover?(level)

        if node.attributes[:style] == :atx
          range = node.attributes.fetch(:marker_range)
          edit_range(document, node, range, "#" * level)
        else
          edit_range(document, node, node.attributes.fetch(:marker_range), (level == 1 ? "=" : "-") * [node.marker.length, 3].max)
        end
      when [:link, :destination], [:image, :destination]
        edit_range(document, node, node.attributes.fetch(:destination_range), escape_destination(value.to_s))
      else
        raise ArgumentError, "unsupported attribute #{key.inspect} for #{node.type}"
      end
    end

    def self.set_directive(document, node, key, value)
      document.range_of(node)
      raise ArgumentError, "node is not an HTML directive" unless node.type == :directive && node.attributes[:kind] == :html_comment

      values = Directive.parse(document.source.byteslice(node.range)) || {}
      values[key.to_s] = value.to_s
      edit_range(document, node, node.attributes.fetch(:comment_range), Directive.render(values))
    end

    def self.move(document, node, before: nil, after: nil)
      document.range_of(node)
      raise ArgumentError, "specify exactly one of before or after" unless (!!before ^ !!after)
      target = before || after
      target_range = document.range_of(target)
      source_range = node.range
      raise ArgumentError, "cannot move a node relative to itself" if node.equal?(target)
      raise ArgumentError, "move ranges overlap" if source_range.begin < target_range.end && target_range.begin < source_range.end

      source = document.source.b
      moved = source.byteslice(source_range)
      remainder = source.byteslice(0...source_range.begin) + source.byteslice(source_range.end..-1).to_s
      destination = before ? target_range.begin : target_range.end
      destination -= source_range.size if source_range.end <= destination
      result = remainder.byteslice(0...destination) + moved + remainder.byteslice(destination..-1).to_s
      parse_result(document, result)
    end

    def self.insert(document, node, markdown, after:)
      document.range_of(node)
      raise TypeError, "markdown must be a String" unless markdown.is_a?(String)
      markdown = adapt_list_marker(markdown, node.marker) if node.type == :list_item
      source = document.source.b
      range = node.range
      newline = newline_for(document.source)
      if after
        offset = range.end
        if node.type == :list_item
          item = source.byteslice(range)
          prefix = item.end_with?("\r", "\n") ? "" : newline
          insertion = prefix + markdown + (offset < source.bytesize ? newline : "")
        else
          insertion = newline + markdown
          insertion += newline if offset < source.bytesize
        end
      else
        offset = range.begin
        insertion = if node.type == :list_item
          markdown + newline
        else
          markdown + newline * 2
        end
      end
      result = source.byteslice(0...offset) + insertion.b + source.byteslice(offset..-1).to_s
      parse_result(document, result)
    end

    def self.edit(document, node, markdown)
      document.range_of(node)
      raise TypeError, "markdown must be a String" unless markdown.is_a?(String)
      edit_range(document, node, node.range, markdown)
    end

    def self.edit_range(document, node, range, replacement)
      document.range_of(node)
      unless range.is_a?(Range) && range.begin >= node.range.begin && range.end <= node.range.end
        raise ArgumentError, "edit range must be within the node"
      end

      source = document.source.b
      result = source.byteslice(0...range.begin) + replacement.b + source.byteslice(range.end..-1).to_s
      parse_result(document, result)
    end

    def self.parse_result(document, source)
      result = Document.parse(source.force_encoding(document.source.encoding), **document.options)
      raise Error, "edit produced invalid Markdown" unless result.valid?

      result
    end
    private_class_method :parse_result

    def self.escape_text(text)
      text.gsub(/([\\`*_{}\[\]<>!])/) { |character| "\\#{character}" }
    end
    private_class_method :escape_text

    def self.escape_destination(value)
      raise ArgumentError, "destination cannot contain newlines or angle brackets" if value.match?(/[\r\n<>]/)

      value.gsub(/([\\() ])/) { |character| "\\#{character}" }
    end
    private_class_method :escape_destination

    def self.adapt_list_marker(markdown, marker)
      return markdown unless marker && (match = /\A( {0,3})(?:[-+*]|\d{1,9}[.)])(?=[ \t])/.match(markdown))

      markdown.sub(/\A( {0,3})(?:[-+*]|\d{1,9}[.)])(?=[ \t])/, "\\1#{marker}")
    end
    private_class_method :adapt_list_marker

    def self.newline_for(source)
      source[/\r\n|\n|\r/] || "\n"
    end
    private_class_method :newline_for
  end
end

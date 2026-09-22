# frozen_string_literal: true

module Beid
  module Directive
    PATTERN = /\A<!--[ \t]*([A-Za-z][A-Za-z0-9_-]*)[ \t]*:[ \t]*(.*?)[ \t]*-->\z/m

    def self.parse(html_comment)
      match = PATTERN.match(html_comment)
      return nil unless match

      { match[1] => match[2] }
    end

    def self.render(values)
      raise TypeError, "directive must be a Hash" unless values.is_a?(Hash)
      raise ArgumentError, "one key-value pair per comment is supported" unless values.length == 1

      fields = values.map do |key, value|
        key = key.to_s
        value = value.to_s
        raise ArgumentError, "invalid directive key" unless key.match?(/\A[A-Za-z][A-Za-z0-9_-]*\z/)
        raise ArgumentError, "directive value cannot contain a comment terminator or newline" if value.include?("-->") || value.match?(/[\r\n]/)

        "#{key}: #{value}"
      end
      "<!-- #{fields.join("; ")} -->"
    end
  end
end

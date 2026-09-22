# frozen_string_literal: true

module Beid
  Node = Struct.new(:type, :attributes, :children, :range, :marker, keyword_init: true) do
    def initialize(type:, attributes: {}, children: [], range:, marker: nil)
      super(type: type, attributes: freeze_value(attributes), children: children.freeze,
            range: range, marker: marker&.freeze)
      freeze
    end

    def text
      attributes[:text]
    end

    private

    def freeze_value(value)
      case value
      when Hash
        value.each { |key, item| freeze_value(key); freeze_value(item) }
      when Array
        value.each { |item| freeze_value(item) }
      end
      value.freeze
    end
  end
end

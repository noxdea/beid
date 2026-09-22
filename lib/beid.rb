# frozen_string_literal: true

require_relative "beid/version"
require_relative "beid/node"
require_relative "beid/directive"
require_relative "beid/inline_parser"
require_relative "beid/parser"
require_relative "beid/document"
require_relative "beid/editing"

module Beid
  class Error < StandardError; end
end

# frozen_string_literal: true

require_relative "lib/beid/version"

Gem::Specification.new do |spec|
  spec.name = "beid"
  spec.version = Beid::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Source-preserving Markdown parser and editor"
  spec.description = "Parse Markdown into source-positioned nodes and edit byte ranges without rewriting untouched syntax."
  spec.homepage = "https://github.com/noxdea/beid"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Ship runtime code, signatures, and user-facing documentation only.
  spec.files = Dir.chdir(__dir__) do
    Dir["{lib,sig,docs}/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |path| File.file?(path) }
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end

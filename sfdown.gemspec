# frozen_string_literal: true

require_relative "lib/sfdown/version"

Gem::Specification.new do |spec|
  spec.name    = "sfdown"
  spec.version = Sfdown::VERSION
  spec.authors = ["edelkas"]
  spec.email   = ["edlucasma@gmail.com"]

  spec.summary     = "SourceForge project downloader."
  spec.description = "Clones a SourceForge project's directory tree and downloads " \
                     "its files by scraping the Files pages (SourceForge has no " \
                     "official API). Runs in two stages - map the tree, then " \
                     "download - with a live status bar and optional JSON metadata. " \
                     "Supports concurrency, file integrity verification (MD5 / SHA1) " \
                     "and file deduplication."
  spec.homepage = "https://github.com/edelkas/sfdown"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "DOC.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir        = "exe"
  spec.executables   = ["sfdown"]
  spec.require_paths = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.11"
end

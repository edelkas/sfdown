#!/usr/bin/env ruby
# frozen_string_literal: true

# sfdown — SourceForge project downloader.
# Clones a project's directory tree and downloads its files by scraping the
# SF "Files" pages. See CLAUDE.md for the full plan.

require "optparse"

# Parsed CLI configuration.
Config = Struct.new(
  :project, :concurrent, :metadata, :no, :output, :timeout, :sleep,
  keyword_init: true
)

module Options
  DEFAULTS = {
    concurrent: 1,
    metadata: false,
    no: false,
    output: ".",
    timeout: 5,
    sleep: 0.0
  }.freeze

  # Build the OptionParser and the options hash it fills.
  def self.parser(opts)
    OptionParser.new do |o|
      o.banner = "Usage: ruby sfdown.rb project_name [-mn] " \
                 "[-c concurrent] [-o output] [-t timeout] [-s sleep]"

      o.on("-c", "--concurrent N", Integer, "Number of parallel downloads (default 1)") do |v|
        raise OptionParser::InvalidArgument, "#{v} (must be >= 1)" if v < 1

        opts[:concurrent] = v
      end
      o.on("-m", "--metadata", "Save metadata to disk at project's root") { opts[:metadata] = true }
      o.on("-n", "--no", "Only fetch directory tree structure and file metadata, not files") { opts[:no] = true }
      o.on("-o", "--output PATH", String, "Path to store project's root (default current dir)") { |v| opts[:output] = v }
      o.on("-t", "--timeout SECS", Integer, "Timeout for each GET request (default 5)") do |v|
        raise OptionParser::InvalidArgument, "#{v} (must be > 0)" if v <= 0

        opts[:timeout] = v
      end
      o.on("-s", "--sleep SECS", Float, "Wait in-between requests (default 0)") do |v|
        raise OptionParser::InvalidArgument, "#{v} (must be >= 0)" if v.negative?

        opts[:sleep] = v
      end
    end
  end

  # Parse argv into a Config, or print the banner and exit non-zero on misuse.
  def self.parse(argv)
    opts = DEFAULTS.dup
    parser = parser(opts)
    rest = parser.parse(argv)

    raise OptionParser::ParseError, "missing project_name" if rest.empty?
    raise OptionParser::ParseError, "unexpected arguments: #{rest[1..].join(' ')}" if rest.size > 1

    Config.new(project: rest.first, **opts)
  rescue OptionParser::ParseError => e
    warn "Error: #{e.message}\n\n"
    warn parser
    exit 1
  end
end

def main(argv)
  config = Options.parse(argv)
  # Milestone 1: confirm parsing. Later milestones drive the actual download.
  puts config.to_h.inspect
end

main(ARGV) if $PROGRAM_NAME == __FILE__

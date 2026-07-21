#!/usr/bin/env ruby
# frozen_string_literal: true

# sfdown — SourceForge project downloader.
# Clones a project's directory tree and downloads its files by scraping the
# SF "Files" pages. See CLAUDE.md for the full plan.

require "optparse"
require "net/http"
require "uri"
require "json"
require "time"
require "nokogiri"

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

# SourceForge URL templates (see DOC.md).
module Sf
  BASE = "https://sourceforge.net"
  DOWNLOADS = "https://downloads.sourceforge.net"

  module_function

  # Percent-encode a single path segment, byte-wise (keeps UTF-8 safe; space -> %20).
  def encode_segment(name)
    name.b.gsub(%r{[^A-Za-z0-9\-_.~]}n) { |c| format("%%%02X", c.ord) }
  end

  def encode_path(path)
    path.split("/").map { |s| encode_segment(s) }.join("/")
  end

  # Directory page URL; path is the full path relative to the project root ("" = root).
  def dir_url(project, path = "")
    suffix = path.empty? ? "" : "#{encode_path(path)}/"
    "#{BASE}/projects/#{encode_segment(project)}/files/#{suffix}"
  end

  # Direct file download URL (redirects to a mirror).
  def file_url(project, full_path)
    "#{DOWNLOADS}/project/#{encode_segment(project)}/#{encode_path(full_path)}"
  end
end

# One tree entry (folder or file).
Node = Struct.new(:name, :type, :path, :timestamp, :size, :downloads, :children, keyword_init: true) do
  def dir? = type == :d
  def file? = type == :f
end

# HTTP GET/download with timeout, redirect-following and per-request sleep.
class Http
  Error = Class.new(StandardError)
  MAX_REDIRECTS = 10

  def initialize(timeout: 5, sleep: 0)
    @timeout = timeout
    @sleep = sleep
  end

  # GET url (following redirects), returning the response body.
  def get(url)
    with_sleep { with_response(url) { |res| res.body } }
  end

  # Stream url to dest in chunks (never buffered whole); yields each chunk's bytesize.
  def download(url, dest)
    with_sleep do
      with_response(url) do |res|
        File.open(dest, "wb") do |f|
          res.read_body do |chunk|
            f.write(chunk)
            yield chunk.bytesize if block_given?
          end
        end
      end
    end
  end

  private

  # Sleep once per logical fetch (not per redirect hop).
  def with_sleep
    yield
  ensure
    sleep(@sleep) if @sleep.positive?
  end

  def with_response(url, limit = MAX_REDIRECTS, &block)
    uri = url.is_a?(URI) ? url : URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(Net::HTTP::Get.new(uri)) do |res|
        case res
        when Net::HTTPRedirection
          raise Error, "too many redirects for #{url}" if limit <= 0

          return with_response(URI.join(uri.to_s, res["location"]), limit - 1, &block)
        when Net::HTTPSuccess
          return block.call(res)
        else
          raise Error, "HTTP #{res.code} #{res.message} for #{uri}"
        end
      end
    end
  end
end

# Turns a directory page's HTML into child Nodes, merging table rows with
# the net.sf.files JS object.
class Parser
  UNITS = { "b" => 1, "kb" => 1024, "mb" => 1024**2, "gb" => 1024**3, "tb" => 1024**4 }.freeze

  def initialize(project)
    @project = project
  end

  # Parse HTML into child Nodes. parent_path is the directory's full path ("" = root).
  def parse(html, parent_path = "")
    doc = Nokogiri::HTML(html)
    meta = extract_metadata(html)
    doc.css("table#files_list > tbody > tr").filter_map { |row| node_from_row(row, parent_path, meta) }
  end

  private

  def node_from_row(row, parent_path, meta)
    name = row["title"].to_s
    return nil if name.empty?

    type = row["class"].to_s.split.include?("folder") ? :d : :f
    path = parent_path.empty? ? name : "#{parent_path}/#{name}"
    info = meta[name] || {}

    Node.new(
      name: name,
      type: type,
      path: path,
      timestamp: parse_time(row),
      size: type == :f ? parse_size(cell_text(row, "files_size_h")) : 0,
      downloads: downloads_for(row, info),
      children: []
    )
  end

  def cell(row, header)
    row.at_css(%([headers="#{header}"]))
  end

  def cell_text(row, header)
    cell(row, header)&.text.to_s.strip
  end

  def parse_time(row)
    full = cell(row, "files_date_h")&.at_css("abbr")&.[]("title")
    full && !full.empty? ? Time.parse(full).utc : nil
  rescue ArgumentError
    nil
  end

  # "1.7 MB" / "602.1 kB" -> bytes (approximate; SF exposes no exact byte count).
  def parse_size(text)
    m = text.to_s.match(/([\d.]+)\s*([kmgt]?b|bytes?)/i) or return 0

    unit = m[2].downcase
    unit = "b" if unit.start_with?("byte")
    (m[1].to_f * (UNITS[unit] || 1)).round
  end

  # Prefer the JS object's total downloads; fall back to the HTML weekly count.
  def downloads_for(row, info)
    return info["downloads"] if info["downloads"].is_a?(Integer)

    count = cell(row, "files_downloads_h")&.at_css("span.count")&.text
    count ? count.delete(",").to_i : 0
  end

  # Extract and JSON-parse the `net.sf.files = { ... }` object literal.
  def extract_metadata(html)
    idx = html.index("net.sf.files") or return {}
    start = html.index("{", idx) or return {}
    finish = matching_brace(html, start) or return {}

    JSON.parse(html[start..finish])
  rescue JSON::ParserError
    {}
  end

  # Index of the brace matching the one at `start`, honoring string literals.
  def matching_brace(str, start)
    depth = 0
    in_str = false
    esc = false
    (start...str.length).each do |i|
      c = str[i]
      if in_str
        if esc then esc = false
        elsif c == "\\" then esc = true
        elsif c == '"' then in_str = false
        end
      elsif c == '"' then in_str = true
      elsif c == "{" then depth += 1
      elsif c == "}"
        depth -= 1
        return i if depth.zero?
      end
    end
    nil
  end
end

# Stage 1: walk the directory tree from the root, building the in-memory Node
# tree. Network only — never touches the filesystem. Sequential for now
# (concurrency arrives in a later milestone).
class Mapper
  attr_reader :folders, :files, :total_size, :failures

  def initialize(project, http, parser)
    @project = project
    @http = http
    @parser = parser
    @folders = 0
    @files = 0
    @total_size = 0
    @failures = 0
  end

  # Build and return the synthetic root Node with the whole tree mapped.
  # Yields each directory Node right after its page is parsed (progress hook).
  def map(&on_page)
    @on_page = on_page
    root = Node.new(name: @project, type: :d, path: "", timestamp: nil, size: 0, downloads: 0, children: [])
    walk(root)
    aggregate(root)
    # Root timestamp isn't provided by SF; use the newest child's.
    root.timestamp = root.children.map(&:timestamp).compact.max
    root
  end

  private

  def walk(node)
    begin
      html = @http.get(Sf.dir_url(@project, node.path))
      node.children = @parser.parse(html, node.path)
    rescue Http::Error => e
      @failures += 1
      warn "WARN: failed to map #{node.path.empty? ? '(root)' : node.path}: #{e.message}"
      node.children = []
    end
    @on_page&.call(node)

    node.children.each do |child|
      if child.dir?
        @folders += 1
        walk(child)
      else
        @files += 1
        @total_size += child.size
      end
    end
  end

  # Post-order pass: recompute folder size/downloads from their leaves.
  def aggregate(node)
    return if node.file?

    node.children.each { |c| aggregate(c) }
    node.size = node.children.sum(&:size)
    node.downloads = node.children.sum(&:downloads)
  end
end

# Debug helper: indented tree listing.
def dump_tree(node, depth = 0)
  puts "#{'  ' * depth}#{node.name}#{node.dir? ? '/' : ''}"
  node.children.each { |c| dump_tree(c, depth + 1) }
end

def main(argv)
  config = Options.parse(argv)
  http = Http.new(timeout: config.timeout, sleep: config.sleep)
  parser = Parser.new(config.project)
  mapper = Mapper.new(config.project, http, parser)

  start = Time.now
  # Temporary per-page progress; the StatusBar replaces this in a later milestone.
  mapper.map { |node| warn "Parsing #{node.path}/" }
  elapsed = Time.now - start

  puts format("Stage 1: %d folders, %d files, %d bytes in %.1fs%s",
              mapper.folders, mapper.files, mapper.total_size, elapsed,
              mapper.failures.positive? ? " (#{mapper.failures} failures)" : "")
end

main(ARGV) if $PROGRAM_NAME == __FILE__

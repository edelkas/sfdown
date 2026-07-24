# frozen_string_literal: true

# sfdown - SourceForge project downloader.
# Clones a project's directory tree and downloads its files by scraping the
# SF "Files" pages.

require "optparse"
require "net/http"
require "uri"
require "json"
require "time"
require "digest"
require "io/console"
require "fileutils"
require "nokogiri"

require_relative "sfdown/version"

module Sfdown
  # Parsed CLI configuration.
  Config = Struct.new(
    :project, :concurrent, :metadata, :no, :input, :output, :timeout, :sleep,
    keyword_init: true
  )

  module Options
    DEFAULTS = {
      concurrent: 1,
      metadata: false,
      no: false,
      input: nil,
      output: ".",
      timeout: 5,
      sleep: 0.0
    }.freeze

    # Build the OptionParser and the options hash it fills.
    def self.parser(opts)
      OptionParser.new do |o|
        o.banner = "sfdown v#{Sfdown::VERSION} (#{Sfdown::DATE})\n" \
                   "Usage: sfdown project_name [-mn] " \
                   "[-c concurrent] [-i input] [-o output] [-t timeout] [-s sleep]"

        o.on("-c", "--concurrent N", Integer, "Number of parallel network workers, both stages (default 1)") do |v|
          raise OptionParser::InvalidArgument, "#{v} (must be >= 1)" if v < 1

          opts[:concurrent] = v
        end
        o.on("-i", "--input PATH", String, "Bootstrap download from a metadata JSON file (skips mapping)") { |v| opts[:input] = v }
        o.on("-m", "--metadata", "Save metadata JSON file to disk at project's root") { opts[:metadata] = true }
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
  Node = Struct.new(:name, :type, :path, :timestamp, :size, :downloads, :md5, :sha1, :children, keyword_init: true) do
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

    # Stream url to dest in chunks (never buffered whole); yields each chunk (String).
    def download(url, dest)
      with_sleep do
        with_response(url) do |res|
          File.open(dest, "wb") do |f|
            res.read_body do |chunk|
              f.write(chunk)
              yield chunk if block_given?
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

  # Runs a fixed pool of worker threads over a Queue, one item per call, until
  # the queue is closed and drained.
  module Pool
    module_function

    def run(queue, workers, &blk)
      Array.new([workers, 1].max) do
        Thread.new do
          while (item = queue.pop)
            blk.call(item)
          end
        end
      end.each(&:join)
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
        md5: presence(info["md5"]),
        sha1: presence(info["sha1"]),
        children: []
      )
    end

    def presence(str)
      str && !str.empty? ? str : nil
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
  # tree. Network only, never touches the filesystem. Directory pages are fetched
  # by a pool of `concurrent` workers that enqueue subdirectories as they find
  # them; counters are mutex-guarded since the progress hook reads them.
  class Mapper
    # log: callback for non-fatal diagnostics (defaults to stderr; the CLI routes
    # it through StatusBar#log so the bar stays pinned at the bottom).
    def initialize(project, http, parser, concurrent: 1, log: ->(m) { warn m })
      @project = project
      @http = http
      @parser = parser
      @concurrent = concurrent
      @log = log
      @mutex = Mutex.new
      @queue = Queue.new
      @pending = 0
      @folders = 0
      @files = 0
      @total_size = 0
      @failures = 0
    end

    def folders = @mutex.synchronize { @folders }
    def files = @mutex.synchronize { @files }
    def total_size = @mutex.synchronize { @total_size }
    def failures = @mutex.synchronize { @failures }

    # Build and return the synthetic root Node with the whole tree mapped.
    # Yields each directory Node right after its page is parsed (progress hook).
    def map(&on_page)
      @on_page = on_page
      root = Node.new(name: @project, type: :d, path: "", timestamp: nil, size: 0, downloads: 0, children: [])
      enqueue(root)
      Pool.run(@queue, @concurrent) do |node|
        visit(node)
      ensure
        finish
      end
      aggregate(root)
      # Root timestamp isn't provided by SF; use the newest child's.
      root.timestamp = root.children.map(&:timestamp).compact.max
      root
    end

    private

    # Outstanding work is tracked explicitly: an empty queue doesn't mean we're
    # done (a busy worker may still enqueue children), so the queue is closed
    # only once the last visit completes, which is what stops the pool.
    def enqueue(node)
      @mutex.synchronize { @pending += 1 }
      @queue << node
    end

    def finish
      @mutex.synchronize do
        @pending -= 1
        @queue.close if @pending.zero?
      end
    end

    def visit(node)
      node.children = fetch_children(node)
      @mutex.synchronize do
        node.children.each do |child|
          if child.dir?
            @folders += 1
          else
            @files += 1
            @total_size += child.size
          end
        end
      end
      @on_page&.call(node) # outside the mutex: the hook reads the counters
      node.children.each { |child| enqueue(child) if child.dir? }
    end

    def fetch_children(node)
      @parser.parse(@http.get(Sf.dir_url(@project, node.path)), node.path)
    rescue Http::Error => e
      @mutex.synchronize { @failures += 1 }
      @log.call("WARN: failed to map #{node.path.empty? ? '(root)' : node.path}: #{e.message}")
      []
    end

    # Post-order pass: recompute folder size/downloads from their leaves.
    def aggregate(node)
      return if node.file?

      node.children.each { |c| aggregate(c) }
      node.size = node.children.sum(&:size)
      node.downloads = node.children.sum(&:downloads)
    end
  end

  # Stage 2: create the local tree and download files with a pool of `concurrent`
  # workers. Counters are mutex-guarded so the ticker thread can snapshot
  # progress while the workers advance it.
  class Downloader
    ILLEGAL = /[<>:"\\|?*\x00-\x1f]/.freeze # Windows-illegal chars (per path segment)

    attr_reader :total_files, :total_bytes

    # dest is the project root directory (<output>/<project>).
    def initialize(project, http, dest, concurrent: 1, log: ->(m) { warn m })
      @project = project
      @http = http
      @dest = dest
      @concurrent = concurrent
      @log = log
      @mutex = Mutex.new
      @files = []
      @total_files = 0
      @total_bytes = 0
      @files_done = 0
      @bytes_done = 0
      @failures = 0
      @mismatches = 0
      @current = ""
    end

    def files_done = @mutex.synchronize { @files_done }
    def bytes_done = @mutex.synchronize { @bytes_done }
    def failures = @mutex.synchronize { @failures }
    def mismatches = @mutex.synchronize { @mismatches }
    def current = @mutex.synchronize { @current }

    # Create every directory up front and collect the flat file list + totals.
    def prepare(root)
      FileUtils.mkdir_p(@dest)
      each_node(root) do |n|
        FileUtils.mkdir_p(local_path(n)) if n.dir? && !n.path.empty?
        @files << n if n.file?
      end
      @total_files = @files.size
      @total_bytes = @files.sum(&:size)
    end

    # The work list is fixed here (unlike stage 1), so the queue is filled and
    # closed up front and workers just drain it.
    def download_all
      return if @files.empty?

      queue = Queue.new
      @files.each { |f| queue << f }
      queue.close
      Pool.run(queue, [@concurrent, @files.size].min) { |node| download_one(node) }
    end

    # Apply folder timestamps last, deepest-first, writing files into a directory
    # bumps its mtime, so folders must be stamped after their contents are final.
    def apply_folder_times(root)
      dirs = []
      each_node(root) { |n| dirs << n if n.dir? }
      dirs.sort_by { |n| -n.path.count("/") }.each do |n|
        path = local_path(n)
        File.utime(n.timestamp, n.timestamp, path) if n.timestamp && File.directory?(path)
      end
    end

    private

    def download_one(node)
      @mutex.synchronize { @current = node.path }
      dest = local_path(node)
      algo, expected = expected_hash(node)
      digest = algo && Digest.const_get(algo).new
      @http.download(Sf.file_url(@project, node.path), dest) do |chunk|
        @mutex.synchronize { @bytes_done += chunk.bytesize }
        digest&.update(chunk)
      end
      File.utime(node.timestamp, node.timestamp, dest) if node.timestamp
      verify(node, digest.hexdigest, expected) if digest
      @mutex.synchronize { @files_done += 1 }
    rescue Http::Error => e
      @mutex.synchronize { @failures += 1 }
      @log.call("WARN: failed to download #{node.path}: #{e.message}")
    end

    # Strongest available checksum for integrity verification, or nil.
    def expected_hash(node)
      return ["SHA1", node.sha1] if node.sha1 && !node.sha1.empty?
      return ["MD5", node.md5] if node.md5 && !node.md5.empty?

      nil
    end

    def verify(node, actual, expected)
      return if actual.casecmp?(expected)

      @mutex.synchronize { @mismatches += 1 }
      @log.call("WARN: checksum mismatch for #{node.path} (expected #{expected}, got #{actual})")
    end

    def each_node(node, &blk)
      blk.call(node)
      node.children.each { |c| each_node(c, &blk) }
    end

    # Local path for a node; sanitizes each segment for the filesystem.
    def local_path(node)
      return @dest if node.path.empty?

      File.join(@dest, *node.path.split("/").map { |s| s.gsub(ILLEGAL, "_") })
    end
  end

  # Serializes the Node tree to metadata.json: recursive and filesystem-like,
  # enough to rebuild the tree and bootstrap stage 2 without re-scraping.
  module Metadata
    Error = Class.new(StandardError)

    module_function

    def to_h(node)
      h = {
        "name" => node.name,
        "type" => node.type.to_s,
        "size" => node.size,
        "downloads" => node.downloads,
        "timestamp" => node.timestamp&.strftime("%Y-%m-%d %H:%M:%S UTC")
      }
      if node.file?
        h["md5"] = node.md5 if node.md5
        h["sha1"] = node.sha1 if node.sha1
      end
      h["content"] = node.children.map { |c| to_h(c) }
      h
    end

    def write(root, path)
      File.write(path, JSON.pretty_generate(to_h(root)))
    end

    # Rebuild the root Node tree from a metadata file. Paths aren't stored in the
    # JSON, so they're reconstructed from the tree structure (root path = "").
    # Raises Metadata::Error on a structurally invalid document; lets
    # Errno::ENOENT / JSON::ParserError propagate to the caller.
    def read(file)
      data = JSON.parse(File.read(file))
      unless data.is_a?(Hash) && data["name"] && data["type"] == "d"
        raise Error, "not a valid sfdown metadata document (expected a directory root object)"
      end

      node_from(data, "")
    end

    def node_from(h, path)
      Node.new(
        name: h["name"],
        type: h["type"] == "d" ? :d : :f,
        path: path,
        timestamp: parse_ts(h["timestamp"]),
        size: h["size"] || 0,
        downloads: h["downloads"] || 0,
        md5: h["md5"],
        sha1: h["sha1"],
        children: Array(h["content"]).map { |c| node_from(c, join(path, c["name"])) }
      )
    end

    def join(parent, name)
      parent.empty? ? name.to_s : "#{parent}/#{name}"
    end

    def parse_ts(str)
      str && !str.empty? ? Time.parse(str).utc : nil
    rescue ArgumentError
      nil
    end
  end

  # Human-readable formatting for sizes and durations.
  module Fmt
    module_function

    UNITS = %w[B KB MB GB TB].freeze

    def size(bytes)
      v = bytes.to_f
      i = 0
      while v >= 1024 && i < UNITS.size - 1
        v /= 1024
        i += 1
      end
      i.zero? ? "#{bytes} B" : format("%.1f %s", v, UNITS[i])
    end

    def duration(secs)
      return format("%.1fs", secs) if secs < 60

      m, s = secs.round.divmod(60)
      h, m = m.divmod(60)
      h.zero? ? format("%dm%02ds", m, s) : format("%dh%02dm%02ds", h, m, s)
    end
  end

  # Two-line status region pinned to the bottom of the terminal, redrawn in
  # place with ANSI. Thread-safe: a mutex serializes updates, logs and teardown
  # so the ticker and log() never interleave. Assumes a VT-capable terminal.
  class StatusBar
    def initialize(out: $stdout, width: nil)
      @out = out
      @width = width
      @mutex = Mutex.new
      @top = ""
      @bottom = ""
      @drawn = false
      @out.sync = true
    end

    # Set both lines and redraw in place.
    def update(top, bottom)
      @mutex.synchronize do
        @top = top
        @bottom = bottom
        erase
        draw
      end
    end

    # Print a message above the bar (scrolls into history), then redraw the bar.
    def log(msg)
      @mutex.synchronize do
        erase
        @out.puts(msg)
        draw
      end
    end

    # Remove the bar entirely (on completion).
    def finish
      @mutex.synchronize { erase }
    end

    private

    # Park the cursor at the region's top-left and clear from there down.
    def erase
      return unless @drawn

      @out.print("\r\e[1A\e[J")
      @drawn = false
    end

    def draw
      @out.print("#{truncate(@top)}\n#{truncate(@bottom)}")
      @drawn = true
    end

    # Truncate to terminal width so a line never wraps (wrapping corrupts the
    # up-count on the next redraw).
    def truncate(line)
      w = width
      line.length > w ? line[0, w] : line
    end

    def width
      @width || IO.console&.winsize&.last || 80
    rescue StandardError
      80
    end
  end

  # Command-line interface: wires the stages together and drives the status bar.
  module CLI
    module_function

    # Debug helper: indented tree listing.
    def dump_tree(node, depth = 0)
      puts "#{'  ' * depth}#{node.name}#{node.dir? ? '/' : ''}"
      node.children.each { |c| dump_tree(c, depth + 1) }
    end

    # Stage-1 analytics line: starts with the stage number, ends with elapsed time.
    def stage1_line(mapper, elapsed)
      format("[1] folders: %d | files: %d | size: %s | elapsed: %s",
             mapper.folders, mapper.files, Fmt.size(mapper.total_size), Fmt.duration(elapsed))
    end

    # Stage-2 analytics line: elapsed is the global (both-stage) time, complemented
    # by an estimated total = elapsed + remaining_bytes / speed.
    def stage2_line(dl, global_elapsed, speed, total_est)
      format("[2] files: %d/%d | %s/%s | speed: %s/s | elapsed: %s / ~%s",
             dl.files_done, dl.total_files, Fmt.size(dl.bytes_done), Fmt.size(dl.total_bytes),
             Fmt.size(speed), Fmt.duration(global_elapsed), Fmt.duration(total_est))
    end

    def render_stage2(bar, dl, global_start, stage2_start)
      now = Time.now
      s2 = now - stage2_start
      speed = s2.positive? ? dl.bytes_done / s2 : 0
      remaining = [dl.total_bytes - dl.bytes_done, 0].max
      eta = speed.positive? ? remaining / speed : 0
      bar.update("Fetching #{dl.current}", stage2_line(dl, now - global_start, speed, (now - global_start) + eta))
    end

    # Drive stage 2: prepare the tree, download files while a ~1s ticker refreshes
    # the bar, apply folder timestamps, then log the stage summary.
    def run_stage2(downloader, root, bar, global_start)
      downloader.prepare(root)
      stage2_start = Time.now
      ticker = Thread.new do
        loop do
          render_stage2(bar, downloader, global_start, stage2_start)
          sleep 1
        end
      end

      downloader.download_all
      ticker.kill
      ticker.join
      render_stage2(bar, downloader, global_start, stage2_start) # final 100% frame
      downloader.apply_folder_times(root)

      s2 = Time.now - stage2_start
      avg = s2.positive? ? downloader.bytes_done / s2 : 0
      summary = format("Stage 2: %d/%d files, %s in %s (avg %s/s)",
                       downloader.files_done, downloader.total_files,
                       Fmt.size(downloader.bytes_done), Fmt.duration(s2), Fmt.size(avg))
      summary += " (#{downloader.failures} failures)" if downloader.failures.positive?
      summary += " (#{downloader.mismatches} checksum mismatches)" if downloader.mismatches.positive?
      bar.log(summary)
    end

    # Stage 1: map the tree over the network, logging the summary.
    def run_stage1(config, http, bar, start)
      parser = Parser.new(config.project)
      mapper = Mapper.new(config.project, http, parser, concurrent: config.concurrent, log: bar.method(:log))
      root = mapper.map do |node|
        bar.update("Parsing #{node.path}/", stage1_line(mapper, Time.now - start))
      end

      summary = format("Stage 1: %d folders, %d files, %s total in %s",
                       mapper.folders, mapper.files, Fmt.size(mapper.total_size),
                       Fmt.duration(Time.now - start))
      summary += " (#{mapper.failures} failures)" if mapper.failures.positive?
      bar.log(summary)
      root
    end

    # Bootstrap: rebuild the tree from a metadata file instead of mapping.
    def load_metadata(config, bar)
      root = Metadata.read(config.input)
      bar.log("Loaded metadata from #{config.input}: #{count_files(root)} files")
      root
    rescue Errno::ENOENT
      abort "Error: metadata file not found: #{config.input}"
    rescue JSON::ParserError => e
      abort "Error: invalid metadata JSON in #{config.input}: #{e.message}"
    rescue Metadata::Error => e
      abort "Error: #{e.message}"
    end

    def count_files(node)
      node.file? ? 1 : node.children.sum { |c| count_files(c) }
    end

    def main(argv)
      config = Options.parse(argv)
      http = Http.new(timeout: config.timeout, sleep: config.sleep)
      bar = StatusBar.new
      start = Time.now

      root = config.input ? load_metadata(config, bar) : run_stage1(config, http, bar, start)

      dest = File.join(config.output, config.project)
      if config.metadata
        FileUtils.mkdir_p(dest)
        path = File.join(dest, "metadata.json")
        Metadata.write(root, path)
        bar.log("Wrote metadata to #{path}")
      end

      unless config.no
        downloader = Downloader.new(config.project, http, dest, concurrent: config.concurrent, log: bar.method(:log))
        run_stage2(downloader, root, bar, start)
      end

      bar.finish
    end
  end
end

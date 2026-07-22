# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Live tests against the real SourceForge site. They confirm the documented
# URL templates and HTML format are still current, so they intentionally hit
# the network. True connectivity failures skip; format/URL breakage fails loud.
# Disable with SFDOWN_SKIP_LIVE=1.
class LiveTest < Minitest::Test
  PROJECT = "sevenzip"

  # Raised for genuine network unavailability (as opposed to format changes).
  NET_ERRORS = [SocketError, Net::OpenTimeout, Net::ReadTimeout,
                Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT].freeze

  def setup
    skip "live tests disabled (SFDOWN_SKIP_LIVE)" if ENV["SFDOWN_SKIP_LIVE"]
    @http = Http.new(timeout: 20, sleep: 0)
    @parser = Parser.new(PROJECT)
  end

  def test_root_page_format_current
    html = get(Sf.dir_url(PROJECT, ""))
    nodes = @parser.parse(html, "")
    refute_empty nodes, "no rows parsed — HTML table format may have changed"
    assert(nodes.any? { |n| n.name == "7-Zip" && n.dir? }, "expected 7-Zip folder")
    assert(nodes.all? { |n| n.timestamp.is_a?(Time) }, "timestamps not parsed — <abbr> format changed?")
  end

  def test_net_sf_files_still_present
    html = get(Sf.dir_url(PROJECT, ""))
    meta = @parser.send(:extract_metadata, html)
    refute_empty meta, "net.sf.files object missing or unparseable"
    assert meta["7-Zip"], "expected 7-Zip entry in net.sf.files"
  end

  def test_direct_download_resolves_and_verifies_sha1
    # Fetch the folder page to learn the advertised sha1, then download and
    # confirm the bytes match it — exercises URL template + integrity end-to-end.
    html = get(Sf.dir_url(PROJECT, "7-Zip/26.01"))
    node = @parser.parse(html, "7-Zip/26.01").find { |n| n.name == "7zr.exe" }
    refute_nil node&.sha1, "no sha1 in net.sf.files for 7zr.exe"

    Dir.mktmpdir do |dir|
      dest = File.join(dir, "7zr.exe")
      digest = Digest::SHA1.new
      bytes = 0
      begin
        @http.download(Sf.file_url(PROJECT, node.path), dest) { |chunk| digest.update(chunk); bytes += chunk.bytesize }
      rescue *NET_ERRORS => e
        skip "network unavailable: #{e.class}: #{e.message}"
      end
      assert bytes.positive?, "no bytes streamed"
      assert_equal bytes, File.size(dest)
      assert_equal node.sha1, digest.hexdigest, "downloaded bytes don't match advertised sha1"
    end
  end

  private

  def get(url)
    @http.get(url)
  rescue *NET_ERRORS => e
    skip "network unavailable: #{e.class}: #{e.message}"
  end
end

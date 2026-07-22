# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Serves canned bytes per download URL, streamed in small chunks; records URLs.
class FakeDlHttp
  attr_reader :downloaded

  def initialize(by_url)
    @by_url = by_url
    @downloaded = []
  end

  def download(url, dest)
    @downloaded << url
    data = @by_url.fetch(url) { raise Http::Error, "HTTP 404 for #{url}" }
    File.open(dest, "wb") do |f|
      data.bytes.each_slice(2) do |slice|
        chunk = slice.pack("C*")
        f.write(chunk)
        yield chunk.bytesize if block_given?
      end
    end
  end
end

class DownloaderTest < Minitest::Test
  PROJECT = "proj"
  T_ROOT = Time.utc(2022, 1, 1, 0, 0, 0)
  T_A    = Time.utc(2021, 2, 3, 4, 5, 6)
  T_V1   = Time.utc(2020, 6, 7, 8, 9, 10)
  T_B    = Time.utc(2019, 10, 11, 12, 13, 14)

  def file_node(name, path, ts, size) = Node.new(name: name, type: :f, path: path, timestamp: ts, size: size, downloads: 0, children: [])

  # root/ (a.txt, v1/(b.bin))
  def sample_tree
    b = file_node("b.bin", "v1/b.bin", T_B, 3)
    v1 = Node.new(name: "v1", type: :d, path: "v1", timestamp: T_V1, size: 0, downloads: 0, children: [b])
    a = file_node("a.txt", "a.txt", T_A, 5)
    Node.new(name: PROJECT, type: :d, path: "", timestamp: T_ROOT, size: 0, downloads: 0, children: [a, v1])
  end

  def contents
    {
      Sf.file_url(PROJECT, "a.txt") => "hello",
      Sf.file_url(PROJECT, "v1/b.bin") => "bin"
    }
  end

  def run_download(tree, http, dest)
    dl = Downloader.new(PROJECT, http, dest)
    dl.prepare(tree)
    dl.download_all
    dl.apply_folder_times(tree)
    dl
  end

  def test_creates_tree_and_writes_files
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      run_download(sample_tree, FakeDlHttp.new(contents), dest)
      assert_equal "hello", File.read(File.join(dest, "a.txt"))
      assert_equal "bin", File.binread(File.join(dest, "v1", "b.bin"))
    end
  end

  def test_counters
    Dir.mktmpdir do |dir|
      dl = run_download(sample_tree, FakeDlHttp.new(contents), File.join(dir, PROJECT))
      assert_equal 2, dl.total_files
      assert_equal 8, dl.total_bytes # 5 + 3 (approx sizes; here exact)
      assert_equal 2, dl.files_done
      assert_equal 8, dl.bytes_done  # actual bytes streamed
      assert_equal 0, dl.failures
    end
  end

  def test_file_timestamps_applied
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      run_download(sample_tree, FakeDlHttp.new(contents), dest)
      assert_equal T_A.to_i, File.mtime(File.join(dest, "a.txt")).to_i
      assert_equal T_B.to_i, File.mtime(File.join(dest, "v1", "b.bin")).to_i
    end
  end

  def test_folder_timestamps_applied_after_files
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      run_download(sample_tree, FakeDlHttp.new(contents), dest)
      # v1's mtime survives having b.bin written into it (folders stamped last).
      assert_equal T_V1.to_i, File.mtime(File.join(dest, "v1")).to_i
      assert_equal T_ROOT.to_i, File.mtime(dest).to_i
    end
  end

  def test_download_failure_is_tallied_and_survived
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      partial = contents.reject { |url, _| url.end_with?("v1/b.bin") }
      logged = []
      dl = Downloader.new(PROJECT, FakeDlHttp.new(partial), dest, log: ->(m) { logged << m })
      dl.prepare(sample_tree)
      dl.download_all
      assert_equal 1, dl.files_done # a.txt succeeded
      assert_equal 1, dl.failures
      assert_match(%r{failed to download v1/b\.bin}, logged.first)
      assert_path_exists File.join(dest, "a.txt")
    end
  end

  def test_illegal_chars_sanitized_in_local_path
    dl = Downloader.new(PROJECT, FakeDlHttp.new({}), "root")
    node = Node.new(name: %(a:b?c), type: :f, path: %(v1/a:b?c), timestamp: nil, size: 0, downloads: 0, children: [])
    assert_equal File.join("root", "v1", "a_b_c"), dl.send(:local_path, node)
  end
end

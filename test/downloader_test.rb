# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Serves canned bytes per download URL, streamed in small chunks; records URLs.
class FakeDlHttp
  def initialize(by_url)
    @by_url = by_url
    @downloaded = []
    @mutex = Mutex.new
  end

  def downloaded = @mutex.synchronize { @downloaded.dup }

  def download(url, dest)
    @mutex.synchronize { @downloaded << url }
    data = @by_url.fetch(url) { raise Http::Error, "HTTP 404 for #{url}" }
    File.open(dest, "wb") do |f|
      data.bytes.each_slice(2) do |slice|
        chunk = slice.pack("C*")
        f.write(chunk)
        yield chunk if block_given?
      end
    end
  end
end

# Same, but delays each download and records the peak number of in-flight ones.
class TrackingDlHttp < FakeDlHttp
  attr_reader :peak

  def initialize(by_url, delay: 0.05)
    super(by_url)
    @delay = delay
    @track = Mutex.new
    @inflight = 0
    @peak = 0
  end

  def download(url, dest)
    @track.synchronize do
      @inflight += 1
      @peak = [@peak, @inflight].max
    end
    sleep(@delay)
    super
  ensure
    @track.synchronize { @inflight -= 1 }
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

  # --- integrity verification ---

  def one_file_tree(sha1: nil, md5: nil)
    f = Node.new(name: "a.txt", type: :f, path: "a.txt", timestamp: T_A, size: 5,
                 downloads: 0, md5: md5, sha1: sha1, children: [])
    Node.new(name: PROJECT, type: :d, path: "", timestamp: T_ROOT, size: 0, downloads: 0, children: [f])
  end

  def test_matching_sha1_passes
    Dir.mktmpdir do |dir|
      tree = one_file_tree(sha1: Digest::SHA1.hexdigest("hello"))
      logged = []
      dl = Downloader.new(PROJECT, FakeDlHttp.new(contents), File.join(dir, PROJECT), log: ->(m) { logged << m })
      dl.prepare(tree)
      dl.download_all
      assert_equal 0, dl.mismatches
      assert_empty logged
      assert_equal 1, dl.files_done
    end
  end

  def test_mismatched_sha1_warns_and_is_tallied
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      tree = one_file_tree(sha1: "0" * 40) # wrong
      logged = []
      dl = Downloader.new(PROJECT, FakeDlHttp.new(contents), dest, log: ->(m) { logged << m })
      dl.prepare(tree)
      dl.download_all
      assert_equal 1, dl.mismatches
      assert_equal 1, dl.files_done # file still downloaded, just corrupt
      assert_match(/checksum mismatch for a\.txt/, logged.first)
      assert_path_exists File.join(dest, "a.txt")
    end
  end

  def test_md5_used_when_sha1_absent
    Dir.mktmpdir do |dir|
      tree = one_file_tree(md5: Digest::MD5.hexdigest("hello"))
      logged = []
      dl = Downloader.new(PROJECT, FakeDlHttp.new(contents), File.join(dir, PROJECT), log: ->(m) { logged << m })
      dl.prepare(tree)
      dl.download_all
      assert_equal 0, dl.mismatches
      assert_empty logged
    end
  end

  def test_no_hash_skips_verification
    Dir.mktmpdir do |dir|
      dl = run_download(one_file_tree, FakeDlHttp.new(contents), File.join(dir, PROJECT))
      assert_equal 0, dl.mismatches
    end
  end

  # --- concurrency ---

  # A flat tree of n files, so several downloads can be in flight at once.
  def wide_tree(count)
    files = (1..count).map { |i| file_node("f#{i}.bin", "f#{i}.bin", T_A, 4) }
    Node.new(name: PROJECT, type: :d, path: "", timestamp: T_ROOT, size: 0, downloads: 0, children: files)
  end

  def wide_contents(count) = (1..count).to_h { |i| [Sf.file_url(PROJECT, "f#{i}.bin"), "data#{i}"] }

  def download_wide(http, dest, count, concurrent)
    dl = Downloader.new(PROJECT, http, dest, concurrent: concurrent)
    dl.prepare(wide_tree(count))
    dl.download_all
    dl
  end

  def test_concurrent_downloads_write_every_file
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      dl = download_wide(FakeDlHttp.new(wide_contents(8)), dest, 8, 4)
      assert_equal 8, dl.files_done
      assert_equal 0, dl.failures
      assert_equal (1..8).sum { |i| "data#{i}".bytesize }, dl.bytes_done
      (1..8).each { |i| assert_equal "data#{i}", File.binread(File.join(dest, "f#{i}.bin")) }
    end
  end

  def test_downloads_run_in_parallel
    Dir.mktmpdir do |dir|
      http = TrackingDlHttp.new(wide_contents(8))
      download_wide(http, File.join(dir, PROJECT), 8, 4)
      assert_operator http.peak, :>=, 2
    end
  end

  def test_single_worker_never_overlaps
    Dir.mktmpdir do |dir|
      http = TrackingDlHttp.new(wide_contents(4), delay: 0.01)
      download_wide(http, File.join(dir, PROJECT), 4, 1)
      assert_equal 1, http.peak
    end
  end

  # Pool size is capped at the file count, and an empty work list is a no-op.
  def test_more_workers_than_files
    Dir.mktmpdir do |dir|
      dl = download_wide(FakeDlHttp.new(wide_contents(1)), File.join(dir, PROJECT), 1, 8)
      assert_equal 1, dl.files_done
    end
  end

  def test_no_files_is_a_noop
    Dir.mktmpdir do |dir|
      empty = Node.new(name: PROJECT, type: :d, path: "", timestamp: T_ROOT, size: 0, downloads: 0, children: [])
      dl = Downloader.new(PROJECT, FakeDlHttp.new({}), File.join(dir, PROJECT), concurrent: 4)
      dl.prepare(empty)
      dl.download_all
      assert_equal 0, dl.files_done
    end
  end

  # --- deduplication ---

  DUPE_BODY = "shared payload"

  # root/ (a.txt, v1/(b.bin)) where both files carry the same checksum.
  def dupe_tree(sha1: Digest::SHA1.hexdigest(DUPE_BODY), md5: nil)
    a = Node.new(name: "a.txt", type: :f, path: "a.txt", timestamp: T_A, size: 14,
                 downloads: 0, md5: md5, sha1: sha1, children: [])
    b = Node.new(name: "b.bin", type: :f, path: "v1/b.bin", timestamp: T_B, size: 14,
                 downloads: 0, md5: md5, sha1: sha1, children: [])
    v1 = Node.new(name: "v1", type: :d, path: "v1", timestamp: T_V1, size: 0, downloads: 0, children: [b])
    Node.new(name: PROJECT, type: :d, path: "", timestamp: T_ROOT, size: 0, downloads: 0, children: [a, v1])
  end

  def dupe_contents = { Sf.file_url(PROJECT, "a.txt") => DUPE_BODY, Sf.file_url(PROJECT, "v1/b.bin") => DUPE_BODY }

  def run_dupes(dir, tree: dupe_tree, contents: dupe_contents, link: false, logged: [])
    http = FakeDlHttp.new(contents)
    dl = Downloader.new(PROJECT, http, File.join(dir, PROJECT), link: link, log: ->(m) { logged << m })
    dl.prepare(tree)
    dl.download_all
    [dl, http]
  end

  def test_duplicate_is_fetched_once_but_written_twice
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      dl, http = run_dupes(dir)
      assert_equal [Sf.file_url(PROJECT, "a.txt")], http.downloaded
      assert_equal DUPE_BODY, File.binread(File.join(dest, "a.txt"))
      assert_equal DUPE_BODY, File.binread(File.join(dest, "v1", "b.bin"))
      assert_equal 2, dl.files_done
      assert_equal 1, dl.duped_files
    end
  end

  # Only the bytes that actually cross the network are counted as the total.
  def test_duplicate_excluded_from_total_bytes
    Dir.mktmpdir do |dir|
      dl, = run_dupes(dir)
      assert_equal 2, dl.total_files
      assert_equal 14, dl.total_bytes
      assert_equal 14, dl.duped_bytes
      assert_equal DUPE_BODY.bytesize, dl.bytes_done
    end
  end

  def test_copied_duplicate_is_independent_and_keeps_its_own_timestamp
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      run_dupes(dir)
      a = File.join(dest, "a.txt")
      b = File.join(dest, "v1", "b.bin")
      refute File.identical?(a, b)
      assert_equal T_A.to_i, File.mtime(a).to_i
      assert_equal T_B.to_i, File.mtime(b).to_i
    end
  end

  def test_linked_duplicate_shares_the_original_inode
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      dl, = run_dupes(dir, link: true)
      a = File.join(dest, "a.txt")
      b = File.join(dest, "v1", "b.bin")
      assert File.identical?(a, b), "expected a hard link"
      assert_equal 1, dl.duped_files
      # One inode, one set of timestamps: the original's.
      assert_equal T_A.to_i, File.mtime(b).to_i
    end
  end

  def test_files_without_checksums_are_never_deduped
    Dir.mktmpdir do |dir|
      _, http = run_dupes(dir, tree: dupe_tree(sha1: nil))
      assert_equal 2, http.downloaded.length
    end
  end

  def test_md5_is_used_as_the_dedupe_key_when_sha1_is_absent
    Dir.mktmpdir do |dir|
      dl, http = run_dupes(dir, tree: dupe_tree(sha1: nil, md5: Digest::MD5.hexdigest(DUPE_BODY)))
      assert_equal 1, http.downloaded.length
      assert_equal 1, dl.duped_files
      assert_equal 0, dl.mismatches
    end
  end

  def test_duplicate_falls_back_to_downloading_when_the_original_failed
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      logged = []
      only_dupe = dupe_contents.reject { |url, _| url.end_with?("a.txt") }
      dl, http = run_dupes(dir, contents: only_dupe, logged: logged)
      assert_equal 2, http.downloaded.length # the original was attempted, then the dupe
      assert_equal 1, dl.failures
      assert_equal 1, dl.files_done
      assert_equal 0, dl.duped_files
      assert_equal DUPE_BODY, File.binread(File.join(dest, "v1", "b.bin"))
    end
  end

  # --- error handling ---

  # Writes a few bytes, then dies mid-stream.
  class BrokenHttp
    def initialize(error) = @error = error

    def download(url, dest)
      File.open(dest, "wb") { |f| f.write("partial") }
      raise @error
    end
  end

  def test_non_http_failures_are_tallied_not_fatal
    Dir.mktmpdir do |dir|
      logged = []
      dl = Downloader.new(PROJECT, BrokenHttp.new(Errno::EACCES.new("disk")), File.join(dir, PROJECT),
                          log: ->(m) { logged << m })
      dl.prepare(one_file_tree)
      dl.download_all
      assert_equal 1, dl.failures
      assert_equal 0, dl.files_done
      assert_match(/failed to download a\.txt: Errno::EACCES/, logged.first)
    end
  end

  def test_partial_file_is_removed_on_failure
    Dir.mktmpdir do |dir|
      dest = File.join(dir, PROJECT)
      dl = Downloader.new(PROJECT, BrokenHttp.new(Http::Error.new("boom")), dest, log: ->(_m) {})
      dl.prepare(one_file_tree)
      dl.download_all
      refute_path_exists File.join(dest, "a.txt"), "a truncated download must not be left behind"
    end
  end

  # Bootstrap: a tree rebuilt from metadata drives stage 2 with correct paths.
  def test_downloads_from_metadata_reconstructed_tree
    Dir.mktmpdir do |dir|
      meta = File.join(dir, "metadata.json")
      Metadata.write(sample_tree, meta)
      tree = Metadata.read(meta)

      dest = File.join(dir, PROJECT)
      dl = run_download(tree, FakeDlHttp.new(contents), dest)
      assert_equal 2, dl.files_done
      assert_equal "hello", File.read(File.join(dest, "a.txt"))
      assert_equal "bin", File.binread(File.join(dest, "v1", "b.bin"))
    end
  end
end

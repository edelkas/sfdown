# frozen_string_literal: true

require_relative "test_helper"

# Deterministic parsing tests against saved fixtures. These pin the parsing
# logic; the fixtures are a frozen snapshot of the SF format, so live drift is
# covered separately in live_test.rb.
class ParserTest < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures")

  def setup
    @parser = Parser.new("sevenzip")
  end

  def root_html = File.read(File.join(FIXTURES, "sevenzip_root.html"))
  def leaf_html = File.read(File.join(FIXTURES, "sevenzip_leaf.html"))

  def test_root_lists_only_folders
    nodes = @parser.parse(root_html, "")
    refute_empty nodes
    assert(nodes.all?(&:dir?))
    assert_includes nodes.map(&:name), "7-Zip"
  end

  def test_folder_with_space_in_name
    lzma = @parser.parse(root_html, "").find { |n| n.name == "LZMA SDK" }
    assert_equal :d, lzma.type
    assert_equal "LZMA SDK", lzma.path
    assert_equal 0, lzma.size
    assert_kind_of Time, lzma.timestamp
  end

  def test_leaf_lists_files
    nodes = @parser.parse(leaf_html, "7-Zip/26.01")
    refute_empty nodes
    assert(nodes.all?(&:file?))
  end

  def test_file_fields
    exe = @parser.parse(leaf_html, "7-Zip/26.01").find { |n| n.name == "7z2601-x64.exe" }
    assert_equal "7-Zip/26.01/7z2601-x64.exe", exe.path
    assert_equal 1_782_579, exe.size # "1.7 MB" -> 1.7 * 1024^2
    assert_equal Time.utc(2026, 4, 29, 18, 25, 50), exe.timestamp
    assert_empty exe.children
  end

  def test_file_hashes_extracted
    exe = @parser.parse(leaf_html, "7-Zip/26.01").find { |n| n.name == "7z2601-x64.exe" }
    assert_equal "625e395ad8bd099a311c72e0d8e65d1c3bd6628a", exe.sha1
    assert_equal "bed0747071a866109d26eced6c7751e0", exe.md5
  end

  def test_folder_hashes_are_nil
    folder = @parser.parse(root_html, "").find(&:dir?)
    assert_nil folder.sha1
    assert_nil folder.md5
  end

  def test_downloads_uses_js_total_not_weekly
    # JS object says 77515 total; the HTML weekly span.count says 5,444.
    exe = @parser.parse(leaf_html, "7-Zip/26.01").find { |n| n.name == "7z2601-x64.exe" }
    assert_equal 77_515, exe.downloads
  end

  def test_parse_size_units
    assert_equal 1_782_579, @parser.send(:parse_size, "1.7 MB")
    assert_equal (602.1 * 1024).round, @parser.send(:parse_size, "602.1 kB")
    assert_equal (23.0 * 1024**2).round, @parser.send(:parse_size, "23.0 MB")
    assert_equal 0, @parser.send(:parse_size, "")
    assert_equal 0, @parser.send(:parse_size, nil)
  end

  def test_extract_metadata
    meta = @parser.send(:extract_metadata, leaf_html)
    refute_empty meta
    assert_equal "f", meta.dig("7z2601-x64.exe", "type")
  end

  def test_extract_metadata_absent_is_empty
    assert_empty @parser.send(:extract_metadata, "<html><body>no script here</body></html>")
  end
end

# URL template construction (see DOC.md).
class SfUrlTest < Minitest::Test
  def test_dir_url_root
    assert_equal "https://sourceforge.net/projects/sevenzip/files/", Sf.dir_url("sevenzip", "")
  end

  def test_dir_url_encodes_segments
    assert_equal "https://sourceforge.net/projects/sevenzip/files/LZMA%20SDK/",
                 Sf.dir_url("sevenzip", "LZMA SDK")
  end

  def test_file_url_encodes_path
    assert_equal "https://downloads.sourceforge.net/project/sevenzip/7-Zip/26.01/7zr.exe",
                 Sf.file_url("sevenzip", "7-Zip/26.01/7zr.exe")
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class MetadataTest < Minitest::Test
  T_ROOT = Time.utc(2026, 7, 20, 12, 0, 0)
  T_DIR  = Time.utc(2026, 7, 19, 9, 30, 0)
  T_FILE = Time.utc(2026, 7, 18, 8, 15, 30)

  # root/ (v1.0/(setup.zip))
  def sample_tree
    file = Node.new(name: "setup.zip", type: :f, path: "v1.0/setup.zip", timestamp: T_FILE,
                    size: 10, downloads: 5, md5: "abc123", sha1: "def456", children: [])
    dir = Node.new(name: "v1.0", type: :d, path: "v1.0", timestamp: T_DIR, size: 10, downloads: 5, children: [file])
    Node.new(name: "myproject", type: :d, path: "", timestamp: T_ROOT, size: 10, downloads: 5, children: [dir])
  end

  def test_root_object
    h = Metadata.to_h(sample_tree)
    assert_equal "myproject", h["name"]
    assert_equal "d", h["type"]
    assert_equal 10, h["size"]
    assert_equal 5, h["downloads"]
    assert_equal "2026-07-20 12:00:00 UTC", h["timestamp"]
    assert_equal 1, h["content"].length
  end

  def test_file_object_has_hashes_and_empty_content
    file = Metadata.to_h(sample_tree).dig("content", 0, "content", 0)
    assert_equal "setup.zip", file["name"]
    assert_equal "f", file["type"]
    assert_equal "2026-07-18 08:15:30 UTC", file["timestamp"]
    assert_equal "abc123", file["md5"]
    assert_equal "def456", file["sha1"]
    assert_empty file["content"]
  end

  def test_folder_has_no_hash_keys
    dir = Metadata.to_h(sample_tree).dig("content", 0)
    refute dir.key?("md5")
    refute dir.key?("sha1")
  end

  def test_file_without_hashes_omits_keys
    file = Node.new(name: "x", type: :f, path: "x", timestamp: nil, size: 0, downloads: 0, children: [])
    h = Metadata.to_h(file)
    refute h.key?("md5")
    refute h.key?("sha1")
    assert_nil h["timestamp"]
  end

  def test_write_produces_valid_json_roundtrip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "metadata.json")
      Metadata.write(sample_tree, path)
      parsed = JSON.parse(File.read(path))
      assert_equal "myproject", parsed["name"]
      assert_equal "setup.zip", parsed.dig("content", 0, "content", 0, "name")
    end
  end

  # --- read / bootstrap ---

  def with_written_tree
    Dir.mktmpdir do |dir|
      path = File.join(dir, "metadata.json")
      Metadata.write(sample_tree, path)
      yield path
    end
  end

  def test_read_reconstructs_paths
    with_written_tree do |path|
      root = Metadata.read(path)
      assert_equal "", root.path
      v1 = root.children.first
      assert_equal "v1.0", v1.path
      assert_equal "v1.0/setup.zip", v1.children.first.path
    end
  end

  def test_read_reconstructs_fields
    with_written_tree do |path|
      file = Metadata.read(path).children.first.children.first
      assert file.file?
      assert_equal "setup.zip", file.name
      assert_equal 10, file.size
      assert_equal 5, file.downloads
      assert_equal "abc123", file.md5
      assert_equal "def456", file.sha1
      assert_equal T_FILE, file.timestamp
    end
  end

  def test_read_round_trip_is_structurally_identical
    with_written_tree do |path|
      # Writing the re-read tree yields the same document.
      assert_equal Metadata.to_h(sample_tree), Metadata.to_h(Metadata.read(path))
    end
  end

  def test_read_missing_file_raises_enoent
    assert_raises(Errno::ENOENT) { Metadata.read("does/not/exist.json") }
  end

  def test_read_invalid_json_raises_parser_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.json")
      File.write(path, "{not json")
      assert_raises(JSON::ParserError) { Metadata.read(path) }
    end
  end

  def test_read_structurally_invalid_raises_metadata_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "wrong.json")
      File.write(path, JSON.generate({ "foo" => "bar" }))
      assert_raises(Metadata::Error) { Metadata.read(path) }
    end
  end
end

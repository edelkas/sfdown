# frozen_string_literal: true

require_relative "test_helper"

# Serves canned HTML per directory URL; records which URLs were fetched.
class FakeHttp
  attr_reader :gets

  def initialize(pages)
    @pages = pages
    @gets = []
  end

  def get(url)
    @gets << url
    @pages.fetch(url) { raise Http::Error, "HTTP 404 for #{url}" }
  end
end

module PageBuilder
  module_function

  # Build a directory page HTML from entry hashes {name:, type:, ts:, size:, downloads:}.
  def page(entries)
    rows = entries.map { |e| row(e) }.join("\n")
    js = entries.to_h { |e| [e[:name], { "type" => e[:type].to_s, "downloads" => e[:downloads] }] }
    <<~HTML
      <html><body>
      <table id="files_list"><tbody>
      #{rows}
      </tbody></table>
      <script>net.sf.files = #{JSON.generate(js)};</script>
      </body></html>
    HTML
  end

  def row(e)
    klass = e[:type] == :d ? "folder" : "file"
    size = e[:type] == :d ? "" : e[:size]
    <<~ROW
      <tr title="#{e[:name]}" class="#{klass} ">
        <th headers="files_name_h"><span class="name">#{e[:name]}</span></th>
        <td headers="files_date_h"><abbr title="#{e[:ts]}">x</abbr></td>
        <td headers="files_size_h">#{size}</td>
        <td headers="files_downloads_h"><span class="count">1</span></td>
      </tr>
    ROW
  end
end

class MapperTest < Minitest::Test
  include PageBuilder

  PROJECT = "proj"
  MB = 1024 * 1024

  def dir(path) = Sf.dir_url(PROJECT, path)

  # A small two-level tree: root has readme.txt + v1/ + v2/; v2 has sub/.
  def sample_pages
    {
      dir("") => page([
                         { name: "readme.txt", type: :f, ts: "2020-03-04 05:06:07 UTC", size: "1.0 MB", downloads: 100 },
                         { name: "v1", type: :d, ts: "2021-05-06 07:08:09 UTC", downloads: 999 },
                         { name: "v2", type: :d, ts: "2022-07-08 09:10:11 UTC", downloads: 999 }
                       ]),
      dir("v1") => page([
                          { name: "a.zip", type: :f, ts: "2021-05-06 07:08:09 UTC", size: "1.0 MB", downloads: 10 },
                          { name: "b.zip", type: :f, ts: "2021-05-06 07:08:09 UTC", size: "2.0 MB", downloads: 20 }
                        ]),
      dir("v2") => page([
                          { name: "sub", type: :d, ts: "2019-01-01 00:00:00 UTC", downloads: 999 },
                          { name: "c.zip", type: :f, ts: "2022-07-08 09:10:11 UTC", size: "512.0 kB", downloads: 5 }
                        ]),
      dir("v2/sub") => page([
                              { name: "d.zip", type: :f, ts: "2018-02-02 02:02:02 UTC", size: "1.0 MB", downloads: 1 }
                            ])
    }
  end

  def map(pages)
    http = FakeHttp.new(pages)
    mapper = Mapper.new(PROJECT, http, Parser.new(PROJECT))
    root = mapper.map
    [mapper, root, http]
  end

  def find(node, name) = node.children.find { |c| c.name == name }

  def test_counters
    mapper, = map(sample_pages)
    assert_equal 3, mapper.folders # v1, v2, sub
    assert_equal 5, mapper.files   # readme, a, b, c, d
    assert_equal 0, mapper.failures
  end

  def test_total_size_matches_leaf_sum
    mapper, root = map(sample_pages)
    assert_equal (1 + 1 + 2) * MB + 512 * 1024 + 1 * MB, mapper.total_size # 5.5 MB
    assert_equal mapper.total_size, root.size # root aggregate == sum of all files
  end

  def test_folder_aggregation
    _, root = map(sample_pages)
    assert_equal 3 * MB, find(root, "v1").size
    assert_equal 30, find(root, "v1").downloads # overrides the bogus 999 in JS
    v2 = find(root, "v2")
    assert_equal 512 * 1024 + 1 * MB, v2.size
    assert_equal 6, v2.downloads
    assert_equal 1 * MB, find(v2, "sub").size
    assert_equal 1, find(v2, "sub").downloads
  end

  def test_root_downloads_and_timestamp
    _, root = map(sample_pages)
    assert_equal 136, root.downloads # 100 + 30 + 6
    assert_equal Time.utc(2022, 7, 8, 9, 10, 11), root.timestamp # newest child
  end

  def test_only_directories_are_fetched
    _, _, http = map(sample_pages)
    assert_equal [dir(""), dir("v1"), dir("v2"), dir("v2/sub")].sort, http.gets.sort
  end

  def test_progress_hook_fires_once_per_page
    http = FakeHttp.new(sample_pages)
    mapper = Mapper.new(PROJECT, http, Parser.new(PROJECT))
    seen = []
    mapper.map { |node| seen << node.path }
    assert_equal ["", "v1", "v2", "v2/sub"].sort, seen.sort
  end

  def test_failed_page_is_tallied_and_survived
    pages = sample_pages
    pages.delete(dir("v2/sub")) # make sub unreachable
    mapper = root = nil
    _out, err = capture_io do
      mapper, root, = map(pages)
    end
    assert_equal 1, mapper.failures
    assert_match(/failed to map v2\/sub/, err)
    assert_equal 4, mapper.files # d.zip is lost
    assert_empty find(find(root, "v2"), "sub").children
  end
end

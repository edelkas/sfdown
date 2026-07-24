# frozen_string_literal: true

require_relative "test_helper"

class OptionsTest < Minitest::Test
  include TestHelpers

  def test_defaults
    c = Options.parse(["myproject"])
    assert_equal "myproject", c.project
    assert_equal 1, c.concurrent
    refute c.metadata
    refute c.no
    assert_equal ".", c.output
    assert_equal 5, c.timeout
    assert_in_delta 0.0, c.sleep
  end

  def test_short_options
    c = Options.parse(["myproject", "-m", "-n", "-c", "4", "-o", "./out", "-t", "10", "-s", "1.5"])
    assert_equal "myproject", c.project
    assert_equal 4, c.concurrent
    assert c.metadata
    assert c.no
    assert_equal "./out", c.output
    assert_equal 10, c.timeout
    assert_in_delta 1.5, c.sleep
  end

  def test_long_options
    c = Options.parse(["--concurrent", "8", "--metadata", "--output", "dl", "--timeout", "3", "myproject"])
    assert_equal "myproject", c.project
    assert_equal 8, c.concurrent
    assert c.metadata
    refute c.no
    assert_equal "dl", c.output
    assert_equal 3, c.timeout
  end

  def test_combined_flags
    c = Options.parse(["-mn", "myproject"])
    assert c.metadata
    assert c.no
  end

  def test_project_can_follow_options
    c = Options.parse(["-c", "2", "myproject"])
    assert_equal "myproject", c.project
    assert_equal 2, c.concurrent
  end

  def test_link_option
    refute Options.parse(["myproject"]).link
    assert Options.parse(["myproject", "-l"]).link
    assert Options.parse(["myproject", "--link"]).link
  end

  def test_input_defaults_nil
    assert_nil Options.parse(["myproject"]).input
  end

  def test_input_option
    c = Options.parse(["myproject", "-i", "meta.json"])
    assert_equal "meta.json", c.input
    c = Options.parse(["myproject", "--input", "dir/metadata.json"])
    assert_equal "dir/metadata.json", c.input
  end

  def test_missing_project_exits_with_banner
    status, err = capture_parse_error([])
    assert_equal 1, status
    assert_match(/Usage: sfdown project_name/, err)
  end

  def test_extra_positional_exits
    status, err = capture_parse_error(%w[one two])
    assert_equal 1, status
    assert_match(/unexpected arguments: two/, err)
  end

  def test_concurrent_below_one_exits
    status, = capture_parse_error(["myproject", "-c", "0"])
    assert_equal 1, status
  end

  def test_timeout_not_positive_exits
    status, = capture_parse_error(["myproject", "-t", "0"])
    assert_equal 1, status
  end

  def test_negative_sleep_exits
    status, = capture_parse_error(["myproject", "-s", "-1"])
    assert_equal 1, status
  end

  def test_unknown_option_exits
    status, err = capture_parse_error(["myproject", "-x"])
    assert_equal 1, status
    assert_match(/invalid option/, err)
  end

  def test_non_integer_timeout_exits
    status, = capture_parse_error(["myproject", "-t", "abc"])
    assert_equal 1, status
  end
end

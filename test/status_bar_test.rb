# frozen_string_literal: true

require_relative "test_helper"

class StatusBarTest < Minitest::Test
  ERASE = "\r\e[1A\e[J"

  def bar(width: 80)
    @io = StringIO.new
    StatusBar.new(out: @io, width: width)
  end

  def out = @io.string

  def test_first_update_prints_two_lines_without_moving_up
    b = bar
    b.update("top", "bottom")
    assert_equal "top\nbottom", out
    refute_includes out, ERASE
  end

  def test_second_update_erases_then_reprints
    b = bar
    b.update("a", "b")
    b.update("c", "d")
    assert_includes out, ERASE
    assert out.end_with?("c\nd")
  end

  def test_log_writes_message_then_redraws_bar
    b = bar
    b.update("top", "bot")
    b.log("hello")
    assert_includes out, "hello\n"
    assert out.end_with?("top\nbot") # bar restored below the message
    assert_equal 1, out.scan(ERASE).length # erased once (for the log)
  end

  def test_log_before_any_draw_does_not_erase
    b = bar
    b.log("note")
    assert out.start_with?("note\n")
    refute_includes out, ERASE
  end

  def test_finish_erases_the_bar
    b = bar
    b.update("x", "y")
    b.finish
    assert out.end_with?(ERASE)
  end

  def test_finish_when_not_drawn_is_noop
    b = bar
    b.finish
    assert_equal "", out
  end

  def test_lines_truncated_to_width
    b = bar(width: 5)
    b.update("abcdefgh", "1234567")
    assert_equal "abcde\n12345", out
  end
end

class FmtTest < Minitest::Test
  def test_size
    assert_equal "0 B", Fmt.size(0)
    assert_equal "512 B", Fmt.size(512)
    assert_equal "1.0 KB", Fmt.size(1024)
    assert_equal "1.5 KB", Fmt.size(1536)
    assert_equal "1.0 MB", Fmt.size(1024**2)
    assert_equal "1.0 GB", Fmt.size(1024**3)
  end

  def test_duration
    assert_equal "5.0s", Fmt.duration(5)
    assert_equal "12.3s", Fmt.duration(12.34)
    assert_equal "1m05s", Fmt.duration(65)
    assert_equal "1h01m05s", Fmt.duration(3665)
  end
end

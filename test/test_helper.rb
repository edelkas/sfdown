# frozen_string_literal: true

# Shared setup for all test files.
require "minitest/autorun"
require "stringio"

require_relative "../sfdown"

module TestHelpers
  # Run Options.parse expecting the misuse path (banner + non-zero exit).
  # Returns [exit_status, stderr_output].
  def capture_parse_error(argv)
    original = $stderr
    $stderr = StringIO.new
    err = assert_raises(SystemExit) { Options.parse(argv) }
    [err.status, $stderr.string]
  ensure
    $stderr = original
  end
end

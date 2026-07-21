# frozen_string_literal: true

# Test runner: loads every *_test.rb in this directory; minitest/autorun
# executes them at exit. Run with: ruby test/run.rb
Dir.glob(File.join(__dir__, "*_test.rb")).sort.each { |f| require_relative File.basename(f) }

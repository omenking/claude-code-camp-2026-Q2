require "test_helper"

module TelnetLog
  class ParserTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/telnet_logs")

    test "parses every record, preserving the seq stored in the file" do
      parser = Parser.load(FIXTURES.join("20260722.jsonl"))

      assert_equal [ 1, 2, 3, 4, 5, 6, 7, 8 ], parser.records.map(&:seq)
    end

    test "carries direction, session, and the raw text" do
      parser = Parser.load(FIXTURES.join("20260722.jsonl"))
      look   = parser.records.find { |r| r.seq == 5 }

      assert_equal "default", look.session
      assert_equal "out", look.dir
      assert_equal "look", look.text
      assert_equal 4, look.bytes
    end

    test "a redacted record carries the placeholder text but the real byte count" do
      parser   = Parser.load(FIXTURES.join("20260722.jsonl"))
      password = parser.records.find { |r| r.seq == 3 }

      assert password.redacted
      assert_equal "<redacted>", password.text
      assert_equal 6, password.bytes
    end

    test "both directions and multiple sessions are present" do
      parser = Parser.load(FIXTURES.join("20260722.jsonl"))

      assert_includes parser.records.map(&:dir), "in"
      assert_includes parser.records.map(&:dir), "out"
      assert_includes parser.records.map(&:session), "room_inspector"
    end
  end
end

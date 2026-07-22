require "test_helper"

module ManagerLog
  class ParserTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/manager_logs")

    test "parses every record, preserving the seq stored in the file" do
      parser = Parser.load(FIXTURES.join("20260722.jsonl"))

      assert_equal [ 1, 2, 3, 4, 5, 6 ], parser.records.map(&:seq)
    end

    test "carries tool identity, args, and the sent/received text" do
      parser = Parser.load(FIXTURES.join("20260722.jsonl"))
      look   = parser.records.find { |r| r.seq == 2 }

      assert_equal "command", look.mode
      assert_equal "tbamud__look", look.tool
      assert_equal({}, look.args)
      assert_equal "look", look.sent
      assert_includes look.received, "Common Square"
      assert_equal 1611, look.elapsed_ms
    end

    test "an errored exchange carries no received payload but does carry the error" do
      parser = Parser.load(FIXTURES.join("20260722.jsonl"))
      failed = parser.records.find { |r| r.seq == 6 }

      assert_nil failed.received
      assert_match(/ConnectionError/, failed.error)
    end
  end
end

require "test_helper"

module SessionLog
  class FollowerTest < ActiveSupport::TestCase
    def with_tmp_log
      Dir.mktmpdir do |dir|
        path = File.join(dir, "live.jsonl")
        File.write(path, "")
        yield path
      end
    end

    test "entries_after returns nothing until seq 0 has content" do
      with_tmp_log do |path|
        follower = Follower.new(path)
        assert_empty follower.entries_after(0)
      end
    end

    test "entries_after picks up lines appended after the last read" do
      with_tmp_log do |path|
        follower = Follower.new(path)
        append(path, session_start_line, user_line)

        first_batch = follower.entries_after(0)
        assert_equal 1, first_batch.length
        assert_equal :user, first_batch.first.type

        assert_empty follower.entries_after(first_batch.first.seq)

        append(path, tool_call_line, tool_result_line)
        second_batch = follower.entries_after(first_batch.first.seq)

        assert_equal 1, second_batch.length
        assert_equal :tool, second_batch.first.type
        assert_operator second_batch.first.seq, :>, first_batch.first.seq
      end
    end

    test "does not reparse when the file is unchanged" do
      with_tmp_log do |path|
        follower = Follower.new(path)
        append(path, session_start_line, user_line)
        follower.entries_after(0)

        parser_before = follower.parser
        parser_after  = follower.parser
        assert_same parser_before, parser_after
      end
    end

    private

    def append(path, *lines)
      File.open(path, "a") { |f| lines.each { |l| f.puts(l) } }
    end

    def session_start_line
      %({"phase":"session_start","at":"2026-07-22T10:00:00.000-04:00","model":"m","provider":"p"})
    end

    def user_line
      %({"phase":"prompt","messages":[{"role":"user","content":"look"}],"at":"2026-07-22T10:00:00.100-04:00"})
    end

    def tool_call_line
      %({"phase":"tool_call","name":"look","args":{},"at":"2026-07-22T10:00:01.000-04:00"})
    end

    def tool_result_line
      %({"phase":"tool_result","name":"look","result":"ok","ok":true,"at":"2026-07-22T10:00:01.500-04:00"})
    end
  end
end

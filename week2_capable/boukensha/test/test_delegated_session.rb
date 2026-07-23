require_relative "helper"
require "json"

# Plan Amendment A: a delegated sub-run (`inspect_room` → room_inspector) must
# append to the CALLER's session file instead of minting its own. Before this,
# one REPL turn that visited N rooms produced N+1 session files, none of them a
# complete account of the turn and nothing on disk linking them.
#
# The model round-trip is faked (Boukensha::Client is stubbed) and no MCP server
# is configured, so this exercises the real run_task wiring with no network.
#
# The subagent under test is defined here rather than imported: `room_inspector`
# stopped being an LLM task when Tools::RoomInspector replaced it with a scripted
# survey, but run_task's delegated-logging contract is a FRAMEWORK feature and
# still needs covering. The task name is kept so the assertions still describe
# the case the feature was built for.
class TestDelegatedSession < Minitest::Test
  include McpTestHelper

  class DelegatedTask < Boukensha::Tasks::Base
    def self.task_name = "room_inspector"
    def self.system_prompt(*, **) = "You are a subagent."
  end

  SETTINGS = <<~YAML
    tasks:
      room_inspector:
        provider: anthropic
        model: claude-haiku-4-5
        max_iterations: 3
        max_output_tokens: 256
        allow: []
  YAML

  def test_a_borrowed_logger_keeps_one_file_and_survives_the_sub_run
    Dir.mktmpdir do |dir|
      path   = File.join(dir, "session.jsonl")
      parent = Boukensha::Logger.new(session_id: "parent", log: path, task: "player")
      parent.turn(n: 0)

      result = run_room_inspector(logger: parent)
      assert_equal "{}", result

      # The `own_logger` guard: a borrowed logger belongs to the caller. Closing
      # it here would silently truncate the rest of the player's turn — this
      # write is what catches that.
      parent.turn(n: 1)
      parent.close

      assert_equal [ "session.jsonl" ], Dir.children(dir).sort

      events = File.readlines(path).map { |l| JSON.parse(l) }
      phases = events.map { |e| e["phase"] }

      assert_equal 1, phases.count("session_start"), "one run, one session_start"
      assert_equal 1, phases.count("task_start")
      assert_equal 1, phases.count("task_end")

      sub = events.select { |e| e["task"] == "room_inspector" }
      assert_includes sub.map { |e| e["phase"] }, "response", "the sub-run's work is in this file"
      assert_equal [ 1 ], sub.map { |e| e["depth"] }.uniq

      # ...and the player's own events on either side are still the player's.
      assert_equal [ "player", 0 ], [ events.last["task"], events.last["depth"] ]
      assert_equal "turn", events.last["phase"]
    end
  end

  def test_the_task_start_snapshot_carries_the_sub_runs_own_configuration
    Dir.mktmpdir do |dir|
      path   = File.join(dir, "session.jsonl")
      parent = Boukensha::Logger.new(session_id: "parent", log: path,
                                     snapshot: { max_iterations: 20, model: "claude-opus-4-8" })
      run_room_inspector(logger: parent)
      parent.close

      events = File.readlines(path).map { |l| JSON.parse(l) }
      start  = events.find { |e| e["phase"] == "task_start" }

      assert_equal "room_inspector", start["task_name"]
      assert_equal 3, start["max_iterations"]                 # from SETTINGS, not the parent's 20
      assert_equal "claude-haiku-4-5", start["model"]
      assert_equal :anthropic.to_s, start["provider"]
    end
  end

  # The standalone path (tests, scripts) is unchanged: no logger in, own file
  # out, with this task as the root at depth 0 throughout.
  def test_without_a_logger_run_task_still_mints_its_own_session_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "standalone.jsonl")

      run_room_inspector(log: path)

      events = File.readlines(path).map { |l| JSON.parse(l) }

      assert_equal [ "room_inspector" ], events.map { |e| e["task"] }.uniq
      assert_equal [ 0 ], events.map { |e| e["depth"] }.uniq
      refute_includes events.map { |e| e["phase"] }, "task_start", "a root run brackets nothing"
    end
  end

  # Every response the sub-run logged carries the task that produced it, which
  # is what makes the per-task cost breakdown (§3.1) answerable at all.
  def test_responses_are_attributed_to_the_task_that_produced_them
    Dir.mktmpdir do |dir|
      path   = File.join(dir, "session.jsonl")
      parent = Boukensha::Logger.new(session_id: "parent", log: path)
      run_room_inspector(logger: parent)
      parent.close

      responses = File.readlines(path).map { |l| JSON.parse(l) }
                      .select { |e| e["phase"] == "response" }

      refute_empty responses
      assert_equal [ "room_inspector" ], responses.map { |e| e["task"] }.uniq
      assert_equal [ "claude-haiku-4-5" ], responses.map { |e| e["model"] }.uniq
      assert_equal [ "anthropic" ], responses.map { |e| e["provider"] }.uniq
    end
  end

  private

  # Drive the real Boukensha.run_task against the fake backend.
  def run_room_inspector(**kwargs)
    with_settings(SETTINGS) do
      with_fake_client do
        Boukensha.run_task(DelegatedTask, "inspect", **kwargs)
      end
    end
  end

  # run_task builds its own Client, so the seam is the constructor.
  def with_fake_client
    original = Boukensha::Client.method(:new)
    fake     = FakeClient.new
    Boukensha::Client.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    Boukensha::Client.singleton_class.send(:define_method, :new, original)
  end

  # Point Boukensha.config at a throwaway settings.yaml. Config is memoized on
  # the module, so it is reset on both sides.
  def with_settings(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "settings.yaml"), yaml)
      old = ENV["BOUKENSHA_DIR"]
      ENV["BOUKENSHA_DIR"] = dir
      Boukensha.instance_variable_set(:@config, nil)
      Boukensha.reset_mcp_clients!
      begin
        yield
      ensure
        old.nil? ? ENV.delete("BOUKENSHA_DIR") : ENV["BOUKENSHA_DIR"] = old
        Boukensha.instance_variable_set(:@config, nil)
        Boukensha.reset_mcp_clients!
      end
    end
  end

  # Stands in for Boukensha::Client: one plain text response, no tool use.
  class FakeClient
    def call(**_opts)
      {
        "content" => [ { "type" => "text", "text" => "{}" } ],
        "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 12, "output_tokens" => 3 }
      }
    end
  end
end

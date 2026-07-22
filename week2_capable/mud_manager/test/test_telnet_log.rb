require_relative "helper"
require "tmpdir"
require "fileutils"

class TestTelnetLog < Minitest::Test
  def setup
    @fake = FakeMud.new
    @dir  = Dir.mktmpdir("telnet_log")
  end

  def teardown
    @fake.stop
    FileUtils.remove_entry(@dir)
  end

  def test_from_env_returns_nil_when_dir_unset
    with_env("MUD_TELNET_LOG_DIR" => nil) do
      assert_nil MudManager::TelnetLog.from_env
    end
  end

  def test_from_env_builds_a_log_when_dir_set
    with_env("MUD_TELNET_LOG_DIR" => @dir) do
      log = MudManager::TelnetLog.from_env
      refute_nil log
    end
  end

  def test_disabled_by_default_writes_no_files
    pool = pool_with_telnet_log(nil)
    pool.run_command("default", "look")

    assert_empty Dir.glob(File.join(@dir, "*.jsonl"))
  end

  def test_one_record_per_inbound_chunk_and_outbound_send_both_directions_ordered
    pool = pool_with_telnet_log(telnet_log)
    pool.run_command("default", "look")

    records = read_records
    dirs    = records.map { |r| r["dir"] }

    assert_includes dirs, "in"
    assert_includes dirs, "out"
    # One shared, contiguous seq counter across both directions is what makes
    # "did my command go out before or after that mob arrived?" answerable.
    assert_equal (1..records.length).to_a, records.map { |r| r["seq"] }

    look_send = records.find { |r| r["dir"] == "out" && r["text"] == "look" }
    refute_nil look_send

    reply = records.find { |r| r["dir"] == "in" && r["text"].to_s.match?(/You do: look/) }
    refute_nil reply
  end

  def test_no_credential_ever_appears_in_the_log
    pool = pool_with_telnet_log(telnet_log)
    pool.run_command("default", "look") # opens + logs in first

    raw = File.read(Dir.glob(File.join(@dir, "*.jsonl")).first)
    refute_match(/secret/, raw)

    password_record = read_records.find { |r| r["redacted"] }
    refute_nil password_record
    assert_equal "<redacted>", password_record["text"]
    assert_operator password_record["bytes"], :>, 0
  end

  def test_records_are_scoped_to_the_session_id
    pool = pool_with_telnet_log(telnet_log)
    pool.run_command("default", "look")

    sessions = read_records.map { |r| r["session"] }.uniq
    assert_equal [ "default" ], sessions
  end

  private

  def telnet_log
    MudManager::TelnetLog.new(dir: @dir)
  end

  def pool_with_telnet_log(log, password: "secret")
    cfg = MudManager::Mcp::Config.new(host: "127.0.0.1", port: @fake.port, name: "Gandalf", password: password)
    MudManager::Mcp::SessionPool.new(default_config: cfg, timeout: 5.0, manager_log: nil, telnet_log: log)
  end

  def read_records
    Dir.glob(File.join(@dir, "*.jsonl")).flat_map do |path|
      File.readlines(path).map { |line| JSON.parse(line) }
    end.sort_by { |r| r["seq"] }
  end

  def with_env(vars)
    old = {}
    vars.each { |k, v| old[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

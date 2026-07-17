require "minitest/autorun"
require "tmpdir"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "boukensha"

# The MCP tests need a real MCP server to spawn. The mud-manager daemon in the
# week0_explore package is the one we have, so it plays the role of "some MCP
# server" — the code under test knows nothing about it beyond command/args/env.
MUD_MANAGER_ROOT = File.expand_path("../../../../week0_explore/mud_manager", __dir__)
MUD_MANAGER_BIN  = File.join(MUD_MANAGER_ROOT, "bin", "mud-manager")
MUD_MANAGER_LIB  = File.join(MUD_MANAGER_ROOT, "lib")

module McpTestHelper
  # Spawn a FakeMud for the daemon to talk to, or skip if the sibling package
  # isn't checked out.
  def start_fake_mud
    skip "mud_manager not found at #{MUD_MANAGER_ROOT}" unless File.exist?(MUD_MANAGER_BIN)
    $LOAD_PATH.unshift(MUD_MANAGER_LIB) unless $LOAD_PATH.include?(MUD_MANAGER_LIB)
    require "mud_manager/fake_mud"
    MudManager::FakeMud.new
  end

  # The credentials the daemon needs to reach the fake MUD.
  def fake_mud_env(fake)
    {
      "MUD_HOST" => "127.0.0.1", "MUD_PORT" => fake.port.to_s,
      "MUD_NAME" => "Gandalf",   "MUD_PASSWORD" => "secret"
    }
  end

  # command/args that spawn the daemon as an MCP server.
  def mud_manager_command = RbConfig.ruby
  def mud_manager_args    = [MUD_MANAGER_BIN, "--mcp"]

  def new_registry
    ctx = Boukensha::Context.new(system: "test")
    [ctx, Boukensha::Registry.new(ctx)]
  end

  # Build a Config from a settings.yaml written into a throwaway BOUKENSHA_DIR.
  def config_from(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "settings.yaml"), yaml)
      old = ENV["BOUKENSHA_DIR"]
      ENV["BOUKENSHA_DIR"] = dir
      begin
        yield Boukensha::Config.new
      ensure
        old.nil? ? ENV.delete("BOUKENSHA_DIR") : ENV["BOUKENSHA_DIR"] = old
      end
    end
  end
end

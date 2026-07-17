#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 10 × mud-manager (MCP path).
#
# boukensha has no MUD code at all. This points its generic MCP client at the
# `mud-manager` daemon and registers whatever tools the daemon advertises —
# exactly what the Python / Go / Rust / Java tracks do with their own SDKs.
# Nothing in Boukensha::Tools::Mcp knows what a MUD is; the daemon is just a
# server, and this file is just a host.
#
# Note the names: the daemon advertises `look`, but we pass `prefix: "tbamud"`,
# so the agent sees `tbamud__look`. Prefixing is applied agent-side; the daemon
# never hears about it. In a real run that prefix comes from config.
#
#   # Self-contained smoke test — no API key, no live MUD (built-in fake MUD):
#   ruby examples/mcp_mud_demo.rb --dry
#
#   # Full agent run — needs ANTHROPIC_API_KEY and a reachable MUD via MUD_* or
#   # ~/.boukensha/settings.yaml (mud: host/port/username/password):
#   ruby examples/mcp_mud_demo.rb

# --- load paths: this step's boukensha + the mud_manager package ------------
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../../week0_explore/mud_manager/lib", __dir__)

require "boukensha"

dry = ARGV.include?("--dry")

# --- credentials (env / boukensha config), or a fake MUD for --dry ----------
creds = {}
%w[MUD_HOST MUD_PORT MUD_NAME MUD_PASSWORD].each { |k| creds[k] = ENV[k] if ENV[k] }

fake = nil
if dry
  require "mud_manager/fake_mud"
  fake  = MudManager::FakeMud.new
  creds = {
    "MUD_HOST" => "127.0.0.1", "MUD_PORT" => fake.port.to_s,
    "MUD_NAME" => "Gandalf",   "MUD_PASSWORD" => "secret"
  }
end

if dry
  # Register the daemon's tools into a real boukensha Registry through the
  # generic MCP layer, then dispatch through it — the full agent path, minus
  # the LLM.
  ctx      = Boukensha::Context.new(task: Boukensha::Tasks::Player, system: "demo")
  registry = Boukensha::Registry.new(ctx)

  daemon = File.expand_path("../../../../week0_explore/mud_manager/bin/mud-manager", __dir__)
  client = Boukensha::Tools::Mcp.register(
    registry,
    command: RbConfig.ruby, args: [daemon, "--mcp"],
    env: creds, prefix: "tbamud"
  )

  puts "daemon: #{client.server_info.inspect}"
  puts "tools:  #{ctx.tools.size} — #{ctx.tools.keys.join(', ')}"
  puts

  puts "tbamud__look       => #{registry.dispatch('tbamud__look', {}).inspect}"
  puts "tbamud__attack orc => #{registry.dispatch('tbamud__attack', 'target' => 'orc').inspect}"
  puts "bad cast           => #{registry.dispatch('tbamud__cast_spell', 'spell' => '').inspect}"

  client.close
  fake&.stop
  puts "\n[dry run OK — daemon + step 10 generic MCP layer working]"
  exit 0
end

# --- full agent run ---------------------------------------------------------
# Nothing to wire up: Boukensha.run spawns whatever is in `mcp_servers:` and
# registers its tools. There is no mode to select and no MUD argument to pass,
# because the agent has no concept of a MUD. See examples/example.rb — at this
# point the two demos are the same program.
Boukensha.run(
  task: "Look at your surroundings, check your score, then look at the exits " \
        "and tell me what you see."
)

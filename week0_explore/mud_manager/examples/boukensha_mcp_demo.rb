#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Boukensha × mud-manager (MCP path) demo.
#
# Shows the Ruby track consuming the mud-manager daemon over MCP. The same
# wiring — spawn `mud-manager --mcp`, discover tools, register them — is what
# the Python/Go/Rust/Java tracks do with their own SDKs. Ruby has no shortcut
# any more: boukensha ships no MUD code, so this daemon is its only way in.
#
#   # Dry run (no API key, no live MUD — uses a built-in fake MUD):
#   ruby examples/boukensha_mcp_demo.rb --dry
#
#   # Full agent run (needs ANTHROPIC_API_KEY + a reachable MUD via MUD_* /
#   # ~/.boukensha/settings.yaml):
#   ruby examples/boukensha_mcp_demo.rb
#
# Point at a specific boukensha step with BOUKENSHA_LIB (defaults to the
# repo's week1_baseline step 10).

require "json"

# --- locate boukensha (step 10 by default) --------------------------------
default_boukensha =
  File.expand_path("../../../week1_baseline/ruby/10_standard_tool_library/lib", __dir__)
boukensha_lib = ENV.fetch("BOUKENSHA_LIB", default_boukensha)
$LOAD_PATH.unshift boukensha_lib
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "mud_manager"

dry = ARGV.include?("--dry")

# --- resolve credentials (env / boukensha config) -------------------------
creds = {}
%w[MUD_HOST MUD_PORT MUD_NAME MUD_PASSWORD].each { |k| creds[k] = ENV[k] if ENV[k] }

fake = nil
if dry
  # Spin up an in-process fake MUD so the demo is fully self-contained.
  require "mud_manager/fake_mud"
  fake = MudManager::FakeMud.new
  creds = {
    "MUD_HOST" => "127.0.0.1", "MUD_PORT" => fake.port.to_s,
    "MUD_NAME" => "Gandalf",   "MUD_PASSWORD" => "secret"
  }
end

client = MudManager::Mcp::Client.spawn(env: creds)
puts "Connected to daemon: #{client.server_info.inspect}"
puts "Discovered #{client.tools.size} tools: #{client.tools.map { |t| t["name"] }.join(", ")}"
puts

if dry
  # Drive a few tools directly through the client (no LLM needed) to prove the
  # end-to-end path boukensha would use.
  %w[look].each do |t|
    puts "#{t} => #{client.call_tool(t)[:text].inspect}"
  end
  puts "attack goblin => #{client.call_tool('attack', 'target' => 'goblin')[:text].inspect}"
  puts "bad move => #{client.call_tool('move', 'direction' => 'nowhere')[:text].inspect}"
  client.close
  fake&.stop
  puts "\n[dry run OK]"
  exit 0
end

# --- full agent run: register MCP tools into a Boukensha.run block ---------
# The registration side is boukensha's own generic MCP layer — this package
# ships no boukensha-specific code. Any MCP host would do this the same way.
require "boukensha"

Boukensha.run(
  task: "Look at your surroundings, check your score, then look at the exits " \
        "and tell me what you see.",
  mud:         false,   # do NOT use the embedded session — we go through MCP
  working_dir: false
) do |dsl|
  count = Boukensha::Tools::Mcp.register_client(dsl, client, prefix: "tbamud")
  warn "[demo] registered #{count} MCP tools into boukensha"
end

client.close

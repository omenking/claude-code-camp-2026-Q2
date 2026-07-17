#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 12 — The agent owns no tools.
#
# There is no `mud:` argument and no tool registration here, because boukensha
# has nothing of its own to register. Every tool this agent can call arrives
# from an MCP server listed in settings.yaml's `mcp_servers:` block — the MUD
# daemon, a filesystem server, anything that speaks MCP. Swapping what the
# agent can do is a config edit, not a code change.
#
# This is the one-shot (Boukensha.run) demo. The interactive TUI is launched
# separately via bin/boukensha and isn't exercised by this file.
#
#   ruby examples/example.rb
#   BOUKENSHA_DIR=/path/to/.boukensha ruby examples/example.rb
#
# Point BOUKENSHA_DIR at a config that has an `mcp_servers: mud:` entry (the
# repo root's .boukensha does), and launch from the repo root so that entry's
# relative command path resolves.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "boukensha"

cfg = Boukensha.config
puts "Config:  #{cfg}"
puts "Servers: #{cfg.mcp_servers.keys.join(', ')}"
puts "API key set? #{!ENV['ANTHROPIC_API_KEY'].nil?}"
puts

Boukensha.run(
  task: "Look at your surroundings, check your score, " \
        "then look at the available exits and tell me what you see."
  # system/model/api_key come from config automatically.
  # Tools come from mcp_servers — there is nothing to wire up here.
)

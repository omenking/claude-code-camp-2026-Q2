require "json"
require_relative "tool_spec"
require_relative "../version"

module MudManager
  module Mcp
    # Spec turns the canonical Ruby ToolSpec table into the two serialized
    # artifacts consumers need:
    #
    #   * MCP `inputSchema` objects (JSON Schema) for tools/list, and
    #   * primitives.json — the language-neutral table other tracks generate
    #     local typed builders from.
    #
    # Both are derived from the *same* ToolSpec, so an MCP client and a
    # hand-written Go/Rust client see identical names, enums, and requiredness.
    module Spec
      module_function

      # JSON Schema (draft-ish, what MCP clients expect) for one tool's args.
      def input_schema(tool)
        props = {}
        required = []
        tool[:params].each do |pname, d|
          schema = { "type" => d[:type] }
          schema["description"] = d[:description] if d[:description]
          schema["enum"]        = d[:enum]        if d[:enum]
          schema["default"]     = d[:default]     unless d[:default].nil?
          props[pname] = schema
          required << pname if d[:required]
        end
        out = { "type" => "object", "properties" => props }
        out["required"] = required unless required.empty?
        out
      end

      # The array MCP tools/list returns.
      def mcp_tools
        ToolSpec.all.map do |tool|
          {
            "name"        => tool[:name],
            "description" => tool[:description],
            "inputSchema" => input_schema(tool)
          }
        end
      end

      # The language-neutral spec table. This is primitives.json's content.
      # Ruby (ToolSpec) is canonical; this is a generated projection of it.
      def primitives_table
        tools = {}
        ToolSpec.all.each do |tool|
          args = {}
          tool[:params].each do |pname, d|
            a = { "type" => d[:type], "required" => !!d[:required] }
            a["description"] = d[:description] if d[:description]
            a["enum"]        = d[:enum]        if d[:enum]
            a["default"]     = d[:default]     unless d[:default].nil?
            args[pname] = a
          end
          tools[tool[:name]] = {
            "category"    => tool[:category],
            "description" => tool[:description],
            "args"        => args
          }
        end
        {
          "$schema_note" => "Generated from MudManager::Primitives via MudManager::Mcp::ToolSpec. " \
                            "Ruby is canonical — regenerate with `mud-manager --dump-spec`. Do not hand-edit.",
          "version"      => VERSION,
          "tools"        => tools
        }
      end

      def primitives_json
        JSON.pretty_generate(primitives_table)
      end

      # Write primitives.json to the given path (default: the packaged copy).
      def dump(path = default_spec_path)
        File.write(path, primitives_json + "\n")
        path
      end

      def default_spec_path
        File.expand_path("../../../primitives.json", __dir__)
      end
    end
  end
end

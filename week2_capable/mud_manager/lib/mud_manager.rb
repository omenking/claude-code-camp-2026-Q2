require_relative "mud_manager/version"
require_relative "mud_manager/primitives"
require_relative "mud_manager/session"
require_relative "mud_manager/mcp/errors"
require_relative "mud_manager/mcp/config"
require_relative "mud_manager/mcp/tool_spec"
require_relative "mud_manager/mcp/spec"
require_relative "mud_manager/mcp/session_pool"
require_relative "mud_manager/mcp/dispatcher"
require_relative "mud_manager/mcp/json_line_server"
require_relative "mud_manager/mcp/server"
require_relative "mud_manager/mcp/client"

# MudManager owns a stateful CircleMUD telnet session (Session) and a
# stateless library of command primitives (Primitives), and packages the
# session behind two stdio protocols so agents in ANY language can drive a
# MUD without reimplementing telnet, the login dance, or the command
# primitives:
#
#   * MCP (JSON-RPC 2.0)         — the blessed, zero-protocol-code interface
#   * a bespoke JSON-line format — the low-level teaching escape hatch
#
# See docs/plans/mud_manager/generic_interfacing.md for the design rationale.
module MudManager
end

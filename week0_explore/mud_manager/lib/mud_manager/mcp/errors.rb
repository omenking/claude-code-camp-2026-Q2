module MudManager
  module Mcp
    # A structured, machine-branchable error. Every failure the daemon surfaces
    # to a foreign-language client carries a stable `code` (per plan open-Q #3)
    # so clients branch on the code instead of parsing prose.
    class ProtocolError < StandardError
      attr_reader :code

      # code: one of
      #   "not_configured"   — no credentials available to log in
      #   "not_connected"    — session is closed and could not be (re)opened
      #   "connection_error" — socket-level failure
      #   "login_error"      — wrong password / login dance failed
      #   "timeout"          — read timed out
      #   "argument_error"   — invalid tool argument (bad enum, missing required)
      #   "unknown_tool"     — no such tool / op
      #   "bad_request"      — malformed protocol message
      def initialize(code, message)
        @code = code
        super(message)
      end
    end
  end
end

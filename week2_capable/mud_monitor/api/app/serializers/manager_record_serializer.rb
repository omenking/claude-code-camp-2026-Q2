# Renders a ManagerLog::Parser::Record into the JSON shape the /manager page
# and manager pane consume (spec §4.3, §3.5). `received` carries real ANSI
# escape codes from the MUD, so it gets a pre-rendered `received_html`
# companion field the same way EntrySerializer renders `tool_result`.
class ManagerRecordSerializer
  def self.call(record)
    {
      seq: record.seq,
      at: record.at,
      mono_ms: record.mono_ms,
      session: record.session,
      mode: record.mode,
      tool: record.tool,
      args: record.args,
      correlation_id: record.correlation_id,
      correlation: record.correlation_id ? "exact" : "none",
      sent: record.sent,
      received: record.received,
      received_html: Ansi.to_html(record.received),
      bytes_in: record.bytes_in,
      elapsed_ms: record.elapsed_ms,
      error: record.error
    }
  end
end

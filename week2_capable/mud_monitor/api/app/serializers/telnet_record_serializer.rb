# Renders a TelnetLog::Parser::Record into the JSON shape the /telnet page
# consumes (spec §4.2, §3.4). `text` carries real ANSI escape codes from the
# MUD on inbound chunks, so it gets a pre-rendered `text_html` companion
# field the same way ManagerRecordSerializer renders `received`.
class TelnetRecordSerializer
  def self.call(record)
    {
      seq: record.seq,
      at: record.at,
      mono_ms: record.mono_ms,
      session: record.session,
      dir: record.dir,
      bytes: record.bytes,
      text: record.text,
      text_html: Ansi.to_html(record.text),
      redacted: !!record.redacted
    }
  end
end

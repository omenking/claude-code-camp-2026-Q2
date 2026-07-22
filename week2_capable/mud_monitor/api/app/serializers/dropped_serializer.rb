# Renders a Diff::TelnetManager::Dropped struct into the JSON shape the
# dropped-strip UI consumes (spec §3.6, §5.1). `text` carries real ANSI
# escape codes lifted straight out of the telnet log, so it gets a
# pre-rendered `text_html` companion field the same way the telnet/manager
# record serializers do.
class DroppedSerializer
  def self.call(dropped)
    {
      at: dropped.at,
      telnet_seqs: dropped.telnet_seqs,
      text: dropped.text,
      text_html: Ansi.to_html(dropped.text),
      bytes: dropped.bytes,
      between: {
        after_manager_seq: dropped.after_manager_seq,
        before_manager_seq: dropped.before_manager_seq
      },
      cause: dropped.cause
    }
  end
end

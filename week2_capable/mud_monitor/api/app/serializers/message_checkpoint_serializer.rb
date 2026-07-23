# Renders a SessionLog::MessageTimeline::Checkpoint into the JSON the messages
# sidebar consumes.
#
# `source` tells the UI whether this is the definitive request payload
# ("request" — system + full tool schemas + wire-format messages) or a legacy
# reconstruction ("prompt" — role/content only). `system` and `tools` are
# carried-forward values (the logger dedups constants); `system_changed` /
# `tools_changed` say whether this call is where they actually changed, so the
# UI can collapse the constant parts. `dropped` + `carried` let the UI split
# the array into carried vs appended without sending the tail twice.
class MessageCheckpointSerializer
  def self.call(checkpoint)
    {
      seq:            checkpoint.seq,
      source:         checkpoint.source,
      turn:           checkpoint.turn,
      iteration:      checkpoint.iteration,
      at:             checkpoint.at,
      model:          checkpoint.model,
      max_tokens:     checkpoint.max_tokens,
      system:         checkpoint.system,
      system_changed: checkpoint.system_changed,
      tools:          checkpoint.tools,
      tool_count:     checkpoint.tool_count,
      tools_changed:  checkpoint.tools_changed,
      message_count:  checkpoint.message_count,
      dropped:        checkpoint.dropped,
      carried:        checkpoint.carried,
      marker:         checkpoint.marker,
      messages:       checkpoint.messages.map { |m| serialize_message(m) }
    }
  end

  # Wire messages are already plain JSON ({ "role" =>, "content" => } where
  # content is a String or an array of content blocks). Pass role/content
  # through as logged.
  def self.serialize_message(msg)
    { role: msg["role"], content: msg["content"] }
  end
end

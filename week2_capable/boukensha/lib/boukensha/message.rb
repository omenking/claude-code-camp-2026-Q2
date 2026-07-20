module Boukensha
  Message = Struct.new(:role, :content, :tool_use_id) do
    def to_s
      id_tag = tool_use_id ? " [#{tool_use_id}]" : ""
      "#<Message role=#{role}#{id_tag} content=#{content.to_s[0..60]}...>"
    end
  end
end

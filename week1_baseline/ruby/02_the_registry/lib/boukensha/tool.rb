module Boukensha
  Tool = Struct.new(:name, :description, :parameters, :block) do
    def to_s
      "#<Tool name=#{name} description=#{description.to_s[0..40]} params=#{parameters.keys}>"
    end
  end
end

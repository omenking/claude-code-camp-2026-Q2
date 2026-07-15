module Boukensha
  class UnknownToolError < StandardError; end
  class ApiError         < StandardError; end
  class LoopError        < StandardError; end
  class UnsupportedModelError < StandardError; end
end

module Boukensha
  # A task's tool permissions, parsed from its `allow:` block. The model is a
  # pure allowlist with default-deny: a task may call a tool ONLY if a rule
  # names it, and may pass an argument value ONLY if the rule permits it.
  #
  #   allow:
  #     - poll                                   # tool, any arguments
  #     - look
  #     - check(kind: exits)                     # tool, kind pinned to one value
  #     - check(kind: score|inventory|gold)      # …or any of several (pipe)
  #     - consider                               # free-string target left open
  #
  # Rule grammar (one string per rule):
  #
  #   Rule    ::= Tool [ "(" Arg { "," Arg } ")" ]
  #   Arg     ::= Param ":" Pattern
  #   Pattern ::= "*" | Value { "|" Value }       # "*" = any value
  #
  # Tool names may be bare (`check`) or prefixed (`tbamud__check`); a bare name
  # matches the tool regardless of its MCP prefix.
  #
  # A rule is validated against the tool's OWN parameter schema (the enum it
  # declares in tool_spec, delivered over MCP as inputSchema): the tool must
  # exist, the parameter must exist, it must be constrainable (have an enum),
  # and every pinned value must be one of that enum's values. Typos and illegal
  # values fail at startup, not silently at runtime.
  class Permissions
    class Error < StandardError; end

    Rule = Struct.new(:tool, :where) # where: { param(String) => [values] | :any }

    # allow_list nil  ⇒ permissive (no restriction — the standalone/test path).
    # allow_list []   ⇒ deny-all   (a configured task that granted nothing).
    def self.from(allow_list)
      return new(nil) if allow_list.nil?
      new(Array(allow_list).map { |r| parse_rule(r) })
    end

    def self.deny_all
      new([])
    end

    def initialize(rules)
      @rules = rules
    end

    def permissive?
      @rules.nil?
    end

    # NAME level: may this task see/call the tool at all?
    def allow_tool?(local)
      return true if permissive?
      @rules.any? { |r| matches_tool?(r, local) }
    end

    # VALUE level (advertised): the allowed subset of an enum param's values, in
    # the server's original order. A matching rule that doesn't pin the param
    # (or pins it to `*`) leaves it fully open.
    def allowed_values(local, param, full_enum)
      return full_enum if permissive?
      union = nil
      @rules.each do |r|
        next unless matches_tool?(r, local)
        pat = r.where[param.to_s]
        return full_enum if pat.nil? || pat == :any
        union ||= []
        union |= pat
      end
      return full_enum if union.nil?
      full_enum.select { |v| union.include?(v.to_s) }
    end

    # VALUE level (dispatch guard): is this concrete call permitted? True iff
    # some matching rule is satisfied by every value the call supplies.
    def call_permitted?(local, args)
      return true if permissive?
      @rules.any? do |r|
        next false unless matches_tool?(r, local)
        r.where.all? do |param, pat|
          next true if pat == :any
          value = args[param.to_sym]
          value = args[param.to_s] if value.nil?
          value.nil? || value.to_s.strip.empty? || pat.include?(value.to_s)
        end
      end
    end

    # Validate this task's rules that target `local` against the tool's schema.
    # Raises Error on an unknown parameter, a non-constrainable parameter, or a
    # value outside the parameter's declared enum. No-op when permissive.
    def validate_tool!(local, input_schema)
      return if permissive?
      props = (input_schema && input_schema["properties"]) || {}
      @rules.each do |r|
        next unless matches_tool?(r, local)
        r.where.each do |param, pat|
          schema = props[param] || props[param.to_s]
          raise Error, "permission #{fmt(r)}: '#{r.tool}' has no parameter '#{param}'" unless schema
          next if pat == :any
          enum = schema["enum"]
          unless enum
            raise Error, "permission #{fmt(r)}: parameter '#{param}' of '#{r.tool}' is not constrainable (it declares no enum)"
          end
          bad = pat - enum.map(&:to_s)
          unless bad.empty?
            raise Error, "permission #{fmt(r)}: #{bad.join(', ')} is not a valid #{param} (one of: #{enum.join(', ')})"
          end
        end
      end
    end

    # After all tools are registered, ensure every rule matched a real tool —
    # catches a rule that names a tool no server provides. No-op when permissive.
    def validate_referenced!(registered_locals)
      return if permissive?
      @rules.each do |r|
        next if registered_locals.any? { |l| matches_tool?(r, l) }
        raise Error, "permission rule references unknown tool '#{r.tool}'"
      end
    end

    # ---- internals ----

    def matches_tool?(rule, local)
      rule.tool == local.to_s || rule.tool == unprefix(local.to_s)
    end
    private :matches_tool?

    def unprefix(local)
      i = local.index("__")
      i ? local[(i + 2)..] : local
    end
    private :unprefix

    def fmt(rule)
      rule.where.empty? ? rule.tool : "#{rule.tool}(#{rule.where.map { |k, v| "#{k}: #{v == :any ? '*' : Array(v).join('|')}" }.join(', ')})"
    end
    private :fmt

    def self.parse_rule(str)
      s = str.to_s.strip
      if (m = s.match(/\A([A-Za-z0-9_]+)\s*\((.*)\)\s*\z/))
        tool  = m[1]
        where = {}
        m[2].split(",").each do |pair|
          key, val = pair.split(":", 2)
          raise Error, "invalid permission rule #{str.inspect}: expected 'param: value'" if val.nil?
          param   = key.strip
          pattern =
            if val.strip == "*"
              :any
            else
              vals = val.split("|").map(&:strip).reject(&:empty?)
              raise Error, "invalid permission rule #{str.inspect}: empty value for '#{param}'" if vals.empty?
              vals
            end
          raise Error, "invalid permission rule #{str.inspect}: empty parameter name" if param.empty?
          where[param] = pattern
        end
        Rule.new(tool, where)
      elsif s.match?(/\A[A-Za-z0-9_]+\z/)
        Rule.new(s, {})
      else
        raise Error, "invalid permission rule: #{str.inspect}"
      end
    end
  end
end

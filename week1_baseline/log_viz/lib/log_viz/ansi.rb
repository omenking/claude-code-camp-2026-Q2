module LogViz
  # Converts ANSI SGR escape sequences (as produced by CircleMUD over telnet)
  # into spans of HTML/CSS classes so raw tool output renders with color.
  module Ansi
    CODES = {
      "1" => "ansi-bold",
      "4" => "ansi-underline",
      "30" => "ansi-fg-black",   "31" => "ansi-fg-red",     "32" => "ansi-fg-green",   "33" => "ansi-fg-yellow",
      "34" => "ansi-fg-blue",    "35" => "ansi-fg-magenta", "36" => "ansi-fg-cyan",    "37" => "ansi-fg-white",
      "40" => "ansi-bg-black",   "41" => "ansi-bg-red",     "42" => "ansi-bg-green",   "43" => "ansi-bg-yellow",
      "44" => "ansi-bg-blue",    "45" => "ansi-bg-magenta", "46" => "ansi-bg-cyan",    "47" => "ansi-bg-white",
      "90" => "ansi-fg-bright-black",   "91" => "ansi-fg-bright-red",     "92" => "ansi-fg-bright-green",   "93" => "ansi-fg-bright-yellow",
      "94" => "ansi-fg-bright-blue",    "95" => "ansi-fg-bright-magenta", "96" => "ansi-fg-bright-cyan",    "97" => "ansi-fg-bright-white",
    }.freeze

    ESCAPE_RE = /\e\[([0-9;]*)m/

    # Render a raw string (possibly containing ANSI color codes and CRLF
    # line endings) as escaped HTML with <span> elements for color/style.
    def self.to_html(text)
      classes = []
      html    = +""

      text.to_s.gsub("\r\n", "\n").split(ESCAPE_RE).each_slice(2) do |segment, code|
        unless segment.empty?
          escaped = escape_html(segment)
          html << (classes.empty? ? escaped : %(<span class="#{classes.join(' ')}">#{escaped}</span>))
        end

        apply_codes(classes, code) if code
      end

      html
    end

    def self.escape_html(str)
      str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def self.apply_codes(classes, code_str)
      codes = code_str.empty? ? ["0"] : code_str.split(";")

      codes.each do |code|
        case code
        when "0", ""
          classes.clear
        when "39"
          classes.reject! { |c| c.start_with?("ansi-fg-") }
        when "49"
          classes.reject! { |c| c.start_with?("ansi-bg-") }
        else
          css_class = CODES[code]
          next unless css_class

          classes.reject! { |c| c.start_with?("ansi-fg-") } if css_class.start_with?("ansi-fg-")
          classes.reject! { |c| c.start_with?("ansi-bg-") } if css_class.start_with?("ansi-bg-")
          classes << css_class unless classes.include?(css_class)
        end
      end
    end
  end
end

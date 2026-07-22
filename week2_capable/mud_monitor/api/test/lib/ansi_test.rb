require "test_helper"

class AnsiTest < ActiveSupport::TestCase
  test "escapes HTML before wrapping in SGR spans" do
    html = Ansi.to_html("\e[31m<script>&\e[0m")

    assert_equal '<span class="ansi-fg-red">&lt;script&gt;&amp;</span>', html
  end

  test "CRLF is normalized to LF" do
    assert_equal "a\nb", Ansi.to_html("a\r\nb")
  end

  test "plain text with no escape codes passes through escaped" do
    assert_equal "hello &amp; goodbye", Ansi.to_html("hello & goodbye")
  end

  test "an unterminated escape sequence does not raise and renders the trailing span" do
    html = Ansi.to_html("\e[32mgrowing")

    assert_equal '<span class="ansi-fg-green">growing</span>', html
  end

  test "code 0 resets all active classes" do
    html = Ansi.to_html("\e[31mred\e[0mplain")

    assert_equal '<span class="ansi-fg-red">red</span>plain', html
  end

  test "an unknown SGR code is ignored rather than raising" do
    html = Ansi.to_html("\e[999mtext")

    assert_equal "text", html
  end
end

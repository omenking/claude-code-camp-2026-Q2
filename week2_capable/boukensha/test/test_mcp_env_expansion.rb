require_relative "helper"

# `env:` values in settings.yaml may reference this process's environment as
# ${VAR}. The motivating case is log directories: a relative path there is
# resolved by the spawned server against the shell's cwd, which is why the
# telnet/manager logs once landed in a different .boukensha than the one
# mud_monitor reads. ${BOUKENSHA_DIR} pins them to the directory
# BoukenshaLoader already resolved from ~/.boukensharc.
class TestMcpEnvExpansion < Minitest::Test
  # Exercise the substitution directly — spawning a real server would drag in
  # the whole handshake for a one-line string transform.
  def expand(value)
    Boukensha::Mcp::Client.allocate.send(:expand_env, value)
  end

  def with_env(key, value)
    had = ENV.key?(key)
    old = ENV[key]
    ENV[key] = value
    yield
  ensure
    had ? ENV[key] = old : ENV.delete(key)
  end

  def test_substitutes_a_set_variable
    with_env("BOUKENSHA_DIR", "/home/someone/proj/.boukensha") do
      assert_equal "/home/someone/proj/.boukensha/telnet", expand("${BOUKENSHA_DIR}/telnet")
    end
  end

  def test_substitutes_every_occurrence
    with_env("A", "x") do
      assert_equal "x:x", expand("${A}:${A}")
    end
  end

  # Blanking would yield "/telnet" — a directory at the filesystem root that
  # the server would happily create. Leaving the reference intact makes the
  # misconfiguration visible instead.
  def test_leaves_an_unset_variable_verbatim
    ENV.delete("BOUKENSHA_NOPE")
    assert_equal "${BOUKENSHA_NOPE}/telnet", expand("${BOUKENSHA_NOPE}/telnet")
  end

  def test_leaves_plain_values_alone
    assert_equal "localhost", expand("localhost")
    assert_equal "$NOT_BRACED", expand("$NOT_BRACED")
  end
end

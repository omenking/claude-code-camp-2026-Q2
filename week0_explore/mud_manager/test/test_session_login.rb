require_relative "helper"

# A stale connection under the same character name gets kicked server-side
# with no Y/N prompt: CircleMUD sends "You take over your own body, already
# in use!" and drops straight into the game, skipping the "Welcome"/menu
# flow entirely. Session#login must recognize that text the same way it
# recognizes "Reconnecting." — otherwise it stalls until the read_until
# timeout and login fails even though the server let the client in.
class TestSessionLogin < Minitest::Test
  def test_login_handles_already_in_use_kick_message
    server = TCPServer.new("127.0.0.1", 0)
    port   = server.addr[1]

    accepted = Thread.new do
      sock = server.accept
      sock.write("By what name do you wish to be known? ")
      sock.gets
      sock.write("Password: ")
      sock.gets
      sock.write("\r\nYou take over your own body, already in use!\r\n\r\n<100hp 50m 30v> ")
      sock
    end

    session = MudManager::Session.new(host: "127.0.0.1", port: port, timeout: 3.0)
    session.open
    session.login("dummyi", "helloworld")

    accepted.join(2)
  ensure
    session&.close
    server.close rescue nil
  end
end

require "socket"

module MudManager
  # FakeMud is an in-process CircleMUD stand-in for offline testing. It walks
  # the exact login dance MudManager::Session::login expects, then echoes each
  # command back terminated by the "> " prompt sentinel so read_until_prompt
  # returns deterministically — no live MUD or network required.
  #
  # Password "secret" (by default) logs in; anything else is rejected. Useful
  # for the test suite AND for any language track validating its client before
  # pointing it at a real server.
  #
  #   fake = MudManager::FakeMud.new
  #   # connect a client to 127.0.0.1:fake.port with password "secret"
  #   fake.push("A goblin arrives.\r\n")  # inject async output for poll tests
  #   fake.stop
  class FakeMud
    attr_reader :port

    def initialize(password: "secret", host: "127.0.0.1")
      @password  = password
      @server    = TCPServer.new(host, 0)
      @port      = @server.addr[1]
      @client    = nil
      @client_mu = Mutex.new
      @threads   = []
      @accept    = Thread.new { accept_loop }
    end

    # Push unsolicited (async) output to the connected client.
    def push(text)
      @client_mu.synchronize { @client&.write(text) }
    end

    def stop
      @server.close rescue nil
      @accept.kill
      @threads.each(&:kill)
    end

    private

    def accept_loop
      loop do
        sock = @server.accept
        @client_mu.synchronize { @client = sock }
        @threads << Thread.new { handle(sock) }
      end
    rescue IOError, Errno::EBADF
      # server closed
    end

    def handle(sock)
      sock.write("By what name do you wish to be known? ")
      sock.gets
      sock.write("Password: ")
      pw = sock.gets.to_s.chomp
      if pw == @password
        sock.write("Welcome to CircleMUD!\r\n")
        sock.gets # blank "return" line
        sock.gets # "1" menu choice
        sock.write("You slowly materialize in the Temple.\r\n<100hp 50m 30v> ")
        echo_loop(sock)
      else
        sock.write("Wrong password.\r\n")
        sock.close
      end
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      # client went away
    end

    def echo_loop(sock)
      while (line = sock.gets)
        cmd = line.chomp
        next if cmd.empty?
        if cmd == "quit"
          sock.write("You quit.\r\n")
          sock.close
          break
        end
        sock.write("You do: #{cmd}\r\n<100hp 50m 30v> ")
      end
    end
  end
end

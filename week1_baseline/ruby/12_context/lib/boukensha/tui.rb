# NOTE: deliberately require only the three charm libraries this TUI uses
# (bubbletea + lipgloss + bubbles) rather than `require "charm"`. charm also
# loads `ntcharts`, whose separate Go runtime interferes with bubbletea's
# stdin input-reader goroutine and silently drops keystrokes (typed text
# appears then vanishes). Loading just these three avoids that conflict.
require "bubbletea"
require "lipgloss"
require "bubbles"

module Boukensha
  TickMsg = Class.new(Bubbletea::Message)

  ANSI_COLORS = {
    cyan:         "#00ffff",
    bright_black: "#808080",
    green:        "#00ff00",
    white:        "#ffffff",
    yellow:       "#ffcc00",
    red:          "#ff5555"
  }.freeze

  # Tui wraps a Repl instance and replaces its raw puts/gets I/O with a
  # structured four-zone display powered by charm (bubbletea + lipgloss + bubbles).
  #
  # The Repl continues to own session logic (turn counting, /commands, Agent
  # dispatch).  Tui registers output/event callbacks on the Repl and drives the
  # bubbletea event loop.
  #
  # Layout (top → bottom):
  #   ┌──────────────────────────────────────────────┐
  #   │  conversation viewport (scrollable)           │
  #   ├──────────────────────────────────────────────┤
  #   │  ⟳ live progress line (hidden when idle)     │
  #   ├──────────────────────────────────────────────┤
  #   │  boukensha> input box                         │
  #   ├──────────────────────────────────────────────┤
  #   │  status line (always-on)                      │
  #   └──────────────────────────────────────────────┘
  class Tui
    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    TICK_MS        = 60

    # Thresholds for context-usage colour coding
    CTX_WARN_PCT  = 70
    CTX_ALERT_PCT = 85

    def initialize(repl)
      @repl    = repl
      @context = repl.context
      @events  = Queue.new

      @conversation          = []
      @dirty                 = true
      @turn_count            = 0
      @turn_thread           = nil

      @live = {
        active:             false,
        spinner_idx:        0,
        start_time:         nil,
        elapsed:            0,
        current_action:     "idle",
        iteration:          0,
        tool_call_count:    0,
        turn_input_tokens:  0,
        turn_output_tokens: 0
      }

      @width    = 80
      @height   = 24
      @viewport = Bubbles::Viewport.new
      @textarea = Bubbles::TextArea.new
      @textarea.placeholder = "Type a message…"
      @textarea.height = 1
      @textarea.width  = @width - Repl::PROMPT.length
    end

    def start
      @conversation << @repl.banner

      @repl.on_output { |str| @conversation << str.to_s; @dirty = true }
      @repl.logger.subscribe { |event| @events << event }

      @textarea.focus
      # input_timeout (ms) only governs how often the idle loop wakes — keypresses
      # return from poll_event immediately, so raising it cuts idle CPU ~5x with no
      # added keystroke latency. fps 30 halves full-screen redraws to the pty, which
      # keeps typing responsive on slower terminals (e.g. WSL2).
      Bubbletea::Runner.new(self, alt_screen: true, input_timeout: 50, fps: 30).run
    end

    # ── Bubbletea::Model interface ────────────────────────────────────────────

    def init
      [self, Bubbletea.tick(TICK_MS / 1000.0) { TickMsg.new }]
    end

    def update(msg)
      cmd = nil

      case msg
      when Bubbletea::WindowSizeMessage
        @width  = msg.width
        @height = msg.height
        @viewport.width  = @width
        @viewport.height = viewport_height
        @textarea.width  = @width - Repl::PROMPT.length

      when TickMsg
        drain_events
        if @live[:active]
          @live[:spinner_idx] = (@live[:spinner_idx] + 1) % SPINNER_FRAMES.size
          @live[:elapsed]     = Time.now - @live[:start_time] if @live[:start_time]
        end
        cmd = Bubbletea.tick(TICK_MS / 1000.0) { TickMsg.new }

      when Bubbletea::KeyMessage
        result = handle_key(msg)
        return [self, Bubbletea.quit] if result == :quit
      end

      [self, cmd]
    end

    def view
      sync_viewport if @dirty
      [
        @viewport.view,
        render_progress,
        render_input,
        render_status
      ].join("\n")
    end

    private

    # ── rendering ─────────────────────────────────────────────────────────────

    def sync_viewport
      @viewport.width  = @width
      @viewport.height = viewport_height
      @viewport.content = @conversation.join("\n")
      @viewport.goto_bottom
      @dirty = false
    end

    def render_progress
      if @live[:active]
        frame  = SPINNER_FRAMES[@live[:spinner_idx]]
        action = @live[:current_action]
        iter   = @live[:iteration]
        max    = Agent::MAX_ITERATIONS
        secs   = @live[:elapsed].to_i
        itok   = fmt_tokens(@live[:turn_input_tokens])
        otok   = fmt_tokens(@live[:turn_output_tokens])
        calls  = @live[:tool_call_count]

        lip(:cyan).render(
          "#{frame} #{action}  (iter #{iter}/#{max} · #{secs}s · ↑ #{itok} · ↓ #{otok} · #{calls} calls)"
        )
      else
        pct   = @context.usage_pct
        color = ctx_color(pct)
        used  = fmt_tokens(@context.current_tokens)
        max   = fmt_tokens(@context.context_window)
        turns = @turn_count

        lip(color).render(
          "  [ready]   ctx #{used} / #{max} (#{pct}%)   #{turns} turns"
        )
      end
    end

    def render_input
      prompt = lip(:green, bold: true).render(Repl::PROMPT)
      "#{prompt}#{@textarea.view}"
    end

    def render_status
      ver   = @repl.version || Boukensha::VERSION
      model = @repl.model   || "(model)"
      pct   = @context.usage_pct
      used  = fmt_tokens(@context.current_tokens)
      max   = fmt_tokens(@context.context_window)
      tools = @context.tool_count
      clock = Time.now.strftime("%H:%M:%S")

      ctx_indicator = pct >= CTX_ALERT_PCT ? " ⚠ " : " "
      bar = " boukensha v#{ver} · #{model}  ·  ctx #{used}/#{max} (#{pct}%)#{ctx_indicator}·  #{tools} tools  ·  #{clock} "
      lip(:white, bg: :bright_black).render(bar.ljust(@width))
    end

    def lip(fg = nil, bg: nil, bold: false)
      s = Lipgloss::Style.new
      s = s.foreground(ANSI_COLORS[fg]) if fg && ANSI_COLORS[fg]
      s = s.background(ANSI_COLORS[bg]) if bg && ANSI_COLORS[bg]
      s = s.bold(true) if bold
      s
    end

    def ctx_color(pct)
      if pct >= CTX_ALERT_PCT
        :red
      elsif pct >= CTX_WARN_PCT
        :yellow
      else
        :bright_black
      end
    end

    # ── keyboard ──────────────────────────────────────────────────────────────

    def handle_key(msg)
      case msg.name
      when "ctrl+c", "ctrl+d"
        :quit
      when "esc"
        @turn_thread.raise(Interrupt) if @turn_thread&.alive?
        nil
      when "ctrl+l"
        @repl.handle_command("/clear")
        @turn_count = 0
        nil
      when "pgup"
        @viewport.scroll_up(5)
        nil
      when "pgdown"
        @viewport.scroll_down(5)
        nil
      when "enter"
        submit_input
      else
        @textarea, _ = @textarea.update(msg)
        nil
      end
    end

    def submit_input
      input = @textarea.value.strip
      return nil if input.empty?

      @textarea.reset

      if input.start_with?("/")
        result = @repl.handle_command(input)
        return :quit if result == :quit
        @turn_count = 0 if input == "/clear"
      else
        @conversation << "> #{input}"
        @dirty = true
        launch_turn(input)
      end

      nil
    end

    # ── agent thread ──────────────────────────────────────────────────────────

    def launch_turn(input)
      @live = {
        active:             true,
        spinner_idx:        0,
        start_time:         Time.now,
        elapsed:            0,
        current_action:     "Thinking…",
        iteration:          0,
        tool_call_count:    0,
        turn_input_tokens:  0,
        turn_output_tokens: 0
      }

      @turn_thread = Thread.new do
        @repl.run_turn(input)
      rescue Interrupt
        @events << { phase: :turn_interrupted }
      rescue => e
        @events << { phase: :turn_error, error: e.message }
      ensure
        @events << { phase: :turn_complete }
        @turn_thread = nil
      end
    end

    # ── event queue ───────────────────────────────────────────────────────────

    def drain_events
      while (event = (@events.pop(true) rescue nil))
        handle_event(event)
      end
    end

    def handle_event(event)
      phase = event[:phase] || event["phase"]

      case phase.to_s
      when "iteration"
        @live[:iteration]      = (event[:n] || event["n"]).to_i
        @live[:current_action] = "Thinking…"

      when "tool_call"
        name = event[:name] || event["name"]
        @live[:current_action]  = "Calling tool: #{name}"
        @live[:tool_call_count] += 1

      when "tool_result"
        @live[:current_action] = "Awaiting result…"

      when "response"
        usage = event[:usage] || event["usage"]
        if usage
          itu = usage["input_tokens"].to_i
          otu = usage["output_tokens"].to_i
          @live[:turn_input_tokens]  += itu
          @live[:turn_output_tokens] += otu
        end

      when "compaction"
        dropped = event[:dropped] || event["dropped"]
        @conversation << "[context compacted — #{dropped} messages dropped to free space]"
        @dirty = true

      when "turn_complete"
        @live[:active] = false
        @turn_count   += 1

      when "turn_interrupted"
        @conversation << "[interrupted]"
        @dirty = true

      when "turn_error"
        err = event[:error] || event["error"]
        @live[:active] = false
        @conversation << "[error] #{err}"
        @dirty = true
      end
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    def viewport_height
      [@height - 5, 5].max
    end

    def fmt_tokens(n)
      n = n.to_i
      n >= 1000 ? "#{(n / 1000.0).round(1)}k" : n.to_s
    end
  end
end

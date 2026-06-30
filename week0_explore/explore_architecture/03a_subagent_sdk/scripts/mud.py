#!/usr/bin/env python3
"""mud.py - manage a persistent telnet session to a MUD (tbaMUD/CircleMUD).

A MUD is an interactive, stateful telnet session. A single tool call can't hold
that connection open, so this script runs a small background daemon that owns the
socket: it streams everything the server sends into a log file and forwards your
commands from a named pipe to the server. You then drive the game with short,
stateless calls (send / read) that talk to that daemon.

Subcommands:
  start    Connect to the MUD and start the background session.
  send     Send one or more command lines to the MUD.
  read     Print server output. By default only what's new since the last read.
  status   Show whether the session is alive and the most recent output.
  stop     Disconnect and shut the session down.
  login    Convenience: send name + password to log a character in.

Session state lives under --session-dir (default $MUD_SESSION_DIR or
/tmp/mud-session). Output is stored raw; `read` strips ANSI color by default for
readability (use --raw to keep it).
"""
import argparse
import os
import re
import select
import socket
import sys
import time

DEFAULT_DIR = os.environ.get("MUD_SESSION_DIR", "/tmp/mud-session")

# Telnet protocol bytes (RFC 854)
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
ANSI_RE = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]")


def paths(d):
    return {
        "dir": d,
        "log": os.path.join(d, "session.log"),
        "fifo": os.path.join(d, "cmd.fifo"),
        "pid": os.path.join(d, "daemon.pid"),
        "offset": os.path.join(d, "read.offset"),
        "meta": os.path.join(d, "meta.txt"),
        "err": os.path.join(d, "daemon.err"),
    }


class Telnet:
    """Stream filter: removes telnet IAC negotiation and refuses all options.

    Refusing every option (we reply WONT to DO, DONT to WILL) keeps the byte
    stream clean and readable. We aren't a real terminal, so we don't need to
    agree to anything the server asks for (echo, window size, MSDP, etc.)."""

    def __init__(self):
        self.state = "normal"
        self.cmd = None

    def feed(self, data):
        clean = bytearray()
        resp = bytearray()
        for b in data:
            if self.state == "normal":
                if b == IAC:
                    self.state = "iac"
                else:
                    clean.append(b)
            elif self.state == "iac":
                if b == IAC:           # escaped 0xFF -> literal byte
                    clean.append(IAC)
                    self.state = "normal"
                elif b in (DO, DONT, WILL, WONT):
                    self.cmd = b
                    self.state = "opt"
                elif b == SB:
                    self.state = "sb"
                else:                  # standalone command, ignore
                    self.state = "normal"
            elif self.state == "opt":
                if self.cmd == DO:
                    resp += bytes([IAC, WONT, b])
                elif self.cmd == WILL:
                    resp += bytes([IAC, DONT, b])
                self.state = "normal"
            elif self.state == "sb":
                if b == IAC:
                    self.state = "sb_iac"
            elif self.state == "sb_iac":
                self.state = "normal" if b == SE else "sb"
        return bytes(clean), bytes(resp)


# --------------------------------------------------------------------------- #
# Daemon: owns the socket. Runs detached. Not called directly by the user.
# --------------------------------------------------------------------------- #
def run_daemon(d, host, port):
    p = paths(d)
    with open(p["pid"], "w") as f:
        f.write(str(os.getpid()))
    try:
        sock = socket.create_connection((host, port), timeout=15)
    except Exception as e:
        with open(p["log"], "ab", buffering=0) as logf:
            logf.write(f"[connect failed: {e}]\n".encode())
        os.remove(p["pid"])
        return
    sock.setblocking(False)
    tel = Telnet()

    # Keep our own write end of the FIFO open so reads never hit EOF when a
    # `send` client closes its end -- otherwise select() would spin.
    fifo_r = os.open(p["fifo"], os.O_RDONLY | os.O_NONBLOCK)
    fifo_w = os.open(p["fifo"], os.O_WRONLY)  # noqa: F841 (held open on purpose)
    logf = open(p["log"], "ab", buffering=0)
    fifo_buf = bytearray()

    try:
        while True:
            r, _, _ = select.select([sock, fifo_r], [], [], 1.0)
            if sock in r:
                try:
                    data = sock.recv(8192)
                except BlockingIOError:
                    data = b""
                if data == b"":
                    logf.write(b"\n[connection closed by server]\n")
                    break
                clean, resp = tel.feed(data)
                if clean:
                    logf.write(clean)
                if resp:
                    try:
                        sock.sendall(resp)
                    except OSError:
                        pass
            if fifo_r in r:
                try:
                    chunk = os.read(fifo_r, 8192)
                except BlockingIOError:
                    chunk = b""
                fifo_buf += chunk
                while b"\n" in fifo_buf:
                    line, _, fifo_buf = fifo_buf.partition(b"\n")
                    if line == b"__QUIT__":
                        try:
                            sock.sendall(b"quit\r\n")
                        except OSError:
                            pass
                        raise SystemExit
                    try:
                        sock.sendall(line + b"\r\n")
                    except OSError:
                        logf.write(b"\n[send failed: socket closed]\n")
                        raise SystemExit
    finally:
        try:
            sock.close()
        finally:
            logf.close()
            for fd in (fifo_r, fifo_w):
                try:
                    os.close(fd)
                except OSError:
                    pass
            if os.path.exists(p["pid"]):
                os.remove(p["pid"])


# --------------------------------------------------------------------------- #
# Client-side helpers
# --------------------------------------------------------------------------- #
def is_alive(p):
    if not os.path.exists(p["pid"]):
        return False
    try:
        pid = int(open(p["pid"]).read().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        return False


def cmd_start(args):
    p = paths(args.session_dir)
    os.makedirs(p["dir"], exist_ok=True)
    if is_alive(p):
        print(f"Session already running (pid {open(p['pid']).read().strip()}). "
              f"Use 'stop' first to reconnect.")
        return 0
    # fresh fifo + empty log + reset read offset
    for f in (p["fifo"],):
        if os.path.exists(f):
            os.remove(f)
    os.mkfifo(p["fifo"])
    open(p["log"], "wb").close()
    with open(p["offset"], "w") as f:
        f.write("0")
    with open(p["meta"], "w") as f:
        f.write(f"{args.host}:{args.port}\n")

    # Spawn ourselves as a detached daemon.
    import subprocess
    err = open(p["err"], "ab")
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__),
         "--session-dir", args.session_dir, "_daemon",
         "--host", args.host, "--port", str(args.port)],
        stdout=err, stderr=err, stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    # Give the daemon a moment to connect and receive the banner.
    deadline = time.time() + 5
    while time.time() < deadline:
        if is_alive(p) and os.path.getsize(p["log"]) > 0:
            break
        time.sleep(0.2)
    print(f"Started session to {args.host}:{args.port} (session-dir: {p['dir']}).")
    time.sleep(0.6)
    _print_new(p, raw=False, update=True)
    return 0


def _write_fifo(p, line):
    fd = os.open(p["fifo"], os.O_WRONLY)
    try:
        os.write(fd, line.encode() + b"\n")
    finally:
        os.close(fd)


def cmd_send(args):
    p = paths(args.session_dir)
    if not is_alive(p):
        print("No live session. Run 'start' first.")
        return 1
    for line in args.command:
        _write_fifo(p, line)
        if len(args.command) > 1:
            time.sleep(args.delay)
    time.sleep(args.wait)
    _print_new(p, raw=args.raw, update=True)
    return 0


def _clean(data, raw):
    if raw:
        return data.decode("utf-8", "replace")
    return ANSI_RE.sub(b"", data).decode("utf-8", "replace")


def _get_new(p, raw, update):
    """Return output appended since the last read, advancing the marker."""
    try:
        offset = int(open(p["offset"]).read().strip())
    except (FileNotFoundError, ValueError):
        offset = 0
    size = os.path.getsize(p["log"]) if os.path.exists(p["log"]) else 0
    if size < offset:  # log was truncated/restarted
        offset = 0
    with open(p["log"], "rb") as f:
        f.seek(offset)
        data = f.read()
    if update:
        with open(p["offset"], "w") as f:
            f.write(str(size))
    return _clean(data, raw)


def _print_new(p, raw, update):
    sys.stdout.write(_get_new(p, raw, update))
    sys.stdout.flush()


def cmd_read(args):
    p = paths(args.session_dir)
    if not os.path.exists(p["log"]):
        print("No session log. Run 'start' first.")
        return 1
    if args.all:
        with open(p["log"], "rb") as f:
            data = f.read()
        sys.stdout.write(_clean(data, args.raw))
        if not args.no_update:
            with open(p["offset"], "w") as f:
                f.write(str(os.path.getsize(p["log"])))
        return 0
    # Optionally wait for new output to appear.
    if args.wait > 0:
        try:
            offset = int(open(p["offset"]).read().strip())
        except (FileNotFoundError, ValueError):
            offset = 0
        deadline = time.time() + args.wait
        while time.time() < deadline:
            if os.path.getsize(p["log"]) > offset:
                time.sleep(0.3)  # let a full burst land
                break
            time.sleep(0.2)
    _print_new(p, raw=args.raw, update=not args.no_update)
    return 0


def cmd_status(args):
    p = paths(args.session_dir)
    alive = is_alive(p)
    target = open(p["meta"]).read().strip() if os.path.exists(p["meta"]) else "?"
    print(f"Session dir : {p['dir']}")
    print(f"Target      : {target}")
    print(f"Status      : {'ALIVE' if alive else 'not running'}")
    if os.path.exists(p["log"]):
        size = os.path.getsize(p["log"])
        print(f"Log size    : {size} bytes")
        with open(p["log"], "rb") as f:
            f.seek(max(0, size - 1200))
            tail = f.read()
        print("--- recent output ---")
        sys.stdout.write(_clean(tail, raw=False))
    return 0


def cmd_stop(args):
    p = paths(args.session_dir)
    if not is_alive(p):
        print("No live session.")
    else:
        try:
            _write_fifo(p, "__QUIT__")
            time.sleep(0.8)
        except OSError:
            pass
        if is_alive(p):
            try:
                os.kill(int(open(p["pid"]).read().strip()), 15)
            except (ValueError, ProcessLookupError):
                pass
        print("Session stopped.")
    return 0


def cmd_login(args):
    p = paths(args.session_dir)
    if not is_alive(p):
        print("No live session. Run 'start' first.")
        return 1
    # Drain whatever is on screen so we can react to the prompts we cause.
    _get_new(p, raw=True, update=True)
    _write_fifo(p, args.name)
    time.sleep(1.0)
    _write_fifo(p, args.password)
    time.sleep(1.5)
    out = _get_new(p, raw=False, update=True)
    # A successful auth lands either straight in-game (reconnect) or at the
    # MOTD -> main menu. Walk the menu only if the server actually shows it.
    if re.search(r"press return|\[ *return", out, re.I):
        _write_fifo(p, "")
        time.sleep(1.0)
        out += _get_new(p, raw=False, update=True)
    if re.search(r"make your choice|enter the game|^\s*1\)", out, re.I | re.M):
        _write_fifo(p, "1")           # 1) Enter the game
        time.sleep(1.2)
        out += _get_new(p, raw=False, update=True)
    sys.stdout.write(out)
    if "ncorrect" in out or "wrong" in out.lower():
        print("\n[login may have failed - check the output above]")
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description="Manage a telnet MUD session.")
    ap.add_argument("--session-dir", default=DEFAULT_DIR,
                    help=f"Session state dir (default {DEFAULT_DIR})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("start", help="connect and start the session")
    s.add_argument("--host", default="localhost")
    s.add_argument("--port", type=int, default=4000)
    s.set_defaults(func=cmd_start)

    s = sub.add_parser("send", help="send command line(s) to the MUD")
    s.add_argument("command", nargs="+", help="one or more command lines")
    s.add_argument("--wait", type=float, default=1.0,
                   help="seconds to wait for output after sending (default 1.0)")
    s.add_argument("--delay", type=float, default=0.6,
                   help="seconds between multiple commands (default 0.6)")
    s.add_argument("--raw", action="store_true", help="keep ANSI color codes")
    s.set_defaults(func=cmd_send)

    s = sub.add_parser("read", help="print server output")
    s.add_argument("--all", action="store_true", help="print whole log, not just new")
    s.add_argument("--wait", type=float, default=0.0,
                   help="wait up to N seconds for new output")
    s.add_argument("--raw", action="store_true", help="keep ANSI color codes")
    s.add_argument("--no-update", action="store_true",
                   help="don't advance the read marker")
    s.set_defaults(func=cmd_read)

    s = sub.add_parser("status", help="show session status + recent output")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("stop", help="disconnect and shut down")
    s.set_defaults(func=cmd_stop)

    s = sub.add_parser("login", help="send name + password")
    s.add_argument("name")
    s.add_argument("password")
    s.add_argument("--raw", action="store_true")
    s.set_defaults(func=cmd_login)

    s = sub.add_parser("_daemon", help=argparse.SUPPRESS)
    s.add_argument("--host", required=True)
    s.add_argument("--port", type=int, required=True)
    s.set_defaults(func=lambda a: run_daemon(a.session_dir, a.host, a.port))

    return ap


def main():
    args = build_parser().parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()

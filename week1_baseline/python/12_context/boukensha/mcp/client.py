import itertools
import json
import os
import subprocess


class Error(Exception):
    pass


class Client:
    """A minimal MCP-over-stdio client: it spawns an MCP server as a
    subprocess, performs the initialize handshake, and lets you discover and
    call the tools it advertises. It knows nothing about any particular
    server — command, args, and env are the standard stdio transport config.

        client = Client.spawn("mud-manager", args=["--mcp"])
        for t in client.tools:
            print(t["name"])
        print(client.call_tool("look")["text"])
        client.close()
    """

    PROTOCOL_VERSION = "2025-06-18"

    @classmethod
    def spawn(cls, command, args=(), env=None):
        return cls(command, args=args, env=env)

    def __init__(self, command, args=(), env=None):
        cmd = [str(command), *(str(a) for a in args)]
        spawn_env = {**os.environ, **{str(k): str(v) for k, v in (env or {}).items()}}
        self._process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=spawn_env,
            text=True,
            bufsize=1,
        )
        self._ids = itertools.count(1)
        self.server_info = None
        self.tools = []
        self._handshake()
        self.tools = self._fetch_tools()

    def call_tool(self, name, arguments=None):
        res = self._request("tools/call", {"name": str(name), "arguments": arguments or {}})
        result = res.get("result")
        if result is None:
            raise Error(f"tools/call error: {res.get('error')!r}")
        text = "\n".join(
            c["text"] for c in (result.get("content") or []) if c.get("text") is not None
        )
        return {"text": text, "error": bool(result.get("isError"))}

    def close(self):
        try:
            self._process.stdin.close()
        except Exception:
            pass
        self._process.wait()
        try:
            self._process.stdout.close()
        except Exception:
            pass
        try:
            self._process.stderr.close()
        except Exception:
            pass

    def _handshake(self):
        from .. import __version__

        res = self._request(
            "initialize",
            {
                "protocolVersion": self.PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "boukensha", "version": __version__},
            },
        )
        self.server_info = (res.get("result") or {}).get("serverInfo")
        self._notify("notifications/initialized")

    def _fetch_tools(self):
        res = self._request("tools/list")
        return (res.get("result") or {}).get("tools") or []

    def _request(self, method, params=None):
        request_id = next(self._ids)
        self._write({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        return self._read_until(request_id)

    def _notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _write(self, obj):
        self._process.stdin.write(json.dumps(obj) + "\n")
        self._process.stdin.flush()

    def _read_until(self, request_id):
        while True:
            line = self._process.stdout.readline()
            if line == "":
                raise Error(f"server closed the connection{self._stderr_detail()}")
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") == request_id:
                return msg
            # ignore server-initiated notifications / mismatched ids

    def _stderr_detail(self):
        try:
            self._process.wait()
            output = self._process.stderr.read()
        except Exception:
            return ""
        return f" — stderr: {output.strip()}" if output and output.strip() else ""

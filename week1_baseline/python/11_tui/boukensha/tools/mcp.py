import atexit

from ..mcp.client import Client

SEPARATOR = "__"


class CollisionError(ValueError):
    """Two tools claiming one name. Always fatal, even for an optional server:
    this is a config contradiction, not a server being unreachable, and
    silently dropping the loser is the expensive failure.
    """


def register(registry, command, args=(), env=None, prefix=None):
    client = Client.spawn(command, args=args, env=env)
    atexit.register(lambda: _close_quietly(client))
    register_client(registry, client, prefix=prefix)
    return client


def register_client(registry, client, prefix=None):
    taken = list(registry.tool_names())

    for tool in client.tools:
        remote = tool["name"]
        local = prefixed(remote, prefix)

        if local in taken:
            raise CollisionError(
                f"boukensha: MCP tool name collision on '{local}' — a tool by that "
                "name is already registered. Give this server a distinct `prefix:` "
                "in mcp_servers."
            )
        taken.append(local)

        def make_block(remote_name=remote):
            def block(**kwargs):
                result = client.call_tool(remote_name, kwargs)
                return f"error: {result['text']}" if result["error"] else result["text"]

            return block

        registry.tool(
            local,
            description=str(tool.get("description") or ""),
            parameters=to_boukensha_params(tool.get("inputSchema")),
        )(make_block())

    return len(client.tools)


def prefixed(name, prefix):
    p = (prefix or "").strip()
    return name if not p else f"{p}{SEPARATOR}{name}"


def to_boukensha_params(input_schema):
    props = (input_schema or {}).get("properties") or {}
    out = {}
    for pname, schema in props.items():
        desc = str(schema.get("description") or "")
        if schema.get("enum"):
            desc = f"{desc} (one of: {', '.join(schema['enum'])})".strip()
        out[pname] = {"type": schema.get("type") or "string", "description": desc}
    return out


def _close_quietly(client):
    try:
        client.close()
    except Exception:
        pass

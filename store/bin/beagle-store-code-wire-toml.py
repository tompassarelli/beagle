#!/usr/bin/env python3
"""Manage Beagle Store's owned MCP block in a Codex project config.

The editor works on bytes so unrelated TOML remains byte-identical. New blocks
carry begin/end markers and record the exact newline separator inserted before
the begin marker; ``unset`` removes that owned raw span instead of guessing
whether a neighboring blank line belongs to the user.
"""

import json
import os
import re
import sys


BEGIN_RE = re.compile(
    rb"(?m)^# >>> beagle-store-code-wire managed mcp_servers\.beagle-store separator=([0-2])\n"
)
END_MARKER = b"# <<< beagle-store-code-wire managed mcp_servers.beagle-store\n"
UNMANAGED_BEAGLE_STORE_TABLE_RE = re.compile(
    rb"(?m)^\[mcp_servers\.beagle-store\][ \t]*\r?$"
)


def toml_str(value: str) -> str:
    return json.dumps(value)


def render_toml(server: dict) -> bytes:
    lines = ["[mcp_servers.beagle-store]"]
    lines.append(f"command = {toml_str(server['command'])}")
    args = server.get("args", [])
    lines.append("args = [" + ", ".join(toml_str(arg) for arg in args) + "]")
    env = server.get("env", {})
    if env:
        lines.append("")
        lines.append("[mcp_servers.beagle-store.env]")
        for key, value in env.items():
            lines.append(f"{key} = {toml_str(str(value))}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def render_owned(server: dict, separator_length: int) -> bytes:
    separator = b"\n" * separator_length
    begin = (
        "# >>> beagle-store-code-wire managed mcp_servers.beagle-store "
        f"separator={separator_length}\n"
    ).encode("ascii")
    return separator + begin + render_toml(server) + END_MARKER


def owned_span(data: bytes):
    """Return the full raw span owned by Beagle Store, including its separator."""
    matches = list(BEGIN_RE.finditer(data))
    if not matches:
        return None
    if len(matches) != 1:
        raise ValueError("multiple managed Beagle Store begin markers")

    begin = matches[0]
    end_start = data.find(END_MARKER, begin.end())
    if end_start < 0:
        raise ValueError("managed Beagle Store begin marker has no matching end marker")
    if data.find(END_MARKER, end_start + len(END_MARKER)) >= 0:
        raise ValueError("multiple managed Beagle Store end markers")

    separator_length = int(begin.group(1))
    start = begin.start() - separator_length
    if start < 0 or data[start : begin.start()] != b"\n" * separator_length:
        raise ValueError("managed Beagle Store separator does not match its marker")
    return start, end_start + len(END_MARKER), separator_length


def append_separator(data: bytes) -> int:
    if not data or data.endswith(b"\n\n"):
        return 0
    if data.endswith(b"\n"):
        return 1
    return 2


def write_bytes(path: str, data: bytes) -> None:
    with open(path, "wb") as handle:
        handle.write(data)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit("usage: beagle-store-code-wire-toml.py set|unset <config.toml> [server-json]")
    mode, path = sys.argv[1], sys.argv[2]
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except FileNotFoundError:
        data = b""

    try:
        managed = owned_span(data)
    except ValueError as error:
        sys.exit(f"beagle-store-code-wire-toml.py: refusing malformed managed block: {error}")

    if mode == "set":
        if len(sys.argv) < 4:
            sys.exit("beagle-store-code-wire-toml.py set: missing server-json")
        server = json.loads(sys.argv[3])
        if managed:
            start, end, separator_length = managed
            updated = (
                data[:start]
                + render_owned(server, separator_length)
                + data[end:]
            )
        elif UNMANAGED_BEAGLE_STORE_TABLE_RE.search(data):
            sys.exit(
                "beagle-store-code-wire-toml.py: refusing unmarked "
                "[mcp_servers.beagle-store] table"
            )
        else:
            separator_length = append_separator(data)
            updated = data + render_owned(server, separator_length)
        write_bytes(path, updated)
    elif mode == "unset":
        if managed:
            start, end, _ = managed
            updated = data[:start] + data[end:]
        else:
            return

        if updated == b"":
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
        else:
            write_bytes(path, updated)
    else:
        sys.exit(f"unknown mode {mode!r} (want set|unset)")


if __name__ == "__main__":
    main()

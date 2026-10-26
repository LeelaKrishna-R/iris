#!/usr/bin/env python3
"""Iris for any AI agent: an MCP server (stdio, JSON-RPC 2.0) over her local link.

Claude Code, Codex, Cursor and any other MCP client can make Iris speak, show a bubble, play one of her
animations, glance at something that just happened, come to the pointer, and (only when the person opts in)
read what is on the screen. Nothing here can click, type or press keys: her hands are left out on purpose.

Her link is 127.0.0.1:7791, each request signed with HMAC-SHA256 under a key only this macOS user can read
(~/Library/Application Support/Iris/link.key, written by Iris on first run). No third-party packages.

    claude mcp add iris -- python3 /path/to/iris/agents/iris_mcp.py
    IRIS_MCP_SCREEN=1 …           # also offer iris_screen (what's on his screens: front app, window, text)
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ.get("IRIS_URL", "http://127.0.0.1:7791")
KEY_FILE = Path(os.environ.get("IRIS_KEY_FILE", Path.home() / "Library/Application Support/Iris/link.key"))
PROTOCOL = "2024-11-05"
SCREEN_ALLOWED = os.environ.get("IRIS_MCP_SCREEN") == "1"


class IrisUnreachable(Exception):
    pass


def _key() -> bytes:
    try:
        return KEY_FILE.read_bytes().strip()
    except OSError as e:
        raise IrisUnreachable(f"Iris's link key isn't readable at {KEY_FILE} ({e.strerror}); is Iris installed and "
                              "has she run once?") from None


def call(path: str, payload: dict | None = None, method: str = "POST", timeout: float = 10) -> dict:
    """One signed request to Iris; her JSON reply. Raises IrisUnreachable when she doesn't answer."""
    key = _key()
    raw = b"" if method == "GET" else json.dumps(payload or {}).encode()
    ts, nonce = str(int(time.time())), os.urandom(12).hex()
    route = path.split("?", 1)[0]
    headers = {"X-Iris-Ts": ts, "X-Iris-Nonce": nonce, "Content-Type": "application/json",
               "X-Iris-Sig": hmac.new(key, f"{ts}.{nonce}.".encode() + raw, hashlib.sha256).hexdigest(),
               "X-Iris-Sig2": hmac.new(key, f"{ts}.{nonce}.{method} {route}.".encode() + raw,
                                       hashlib.sha256).hexdigest()}
    req = urllib.request.Request(URL + path, data=None if method == "GET" else raw, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        body = e.read()
    except (urllib.error.URLError, OSError) as e:
        raise IrisUnreachable(f"Iris isn't answering at {URL} ({getattr(e, 'reason', e)}); is she running?") from None
    try:
        return json.loads(body or b"{}")
    except ValueError:
        return {"ok": False, "reason": "unreadable_reply"}


def _spoken(text: str) -> dict:
    """Her voice for `text`: macOS's own `say` to a file, played through her mouth (lips move with it)."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "line.aiff"
        done = subprocess.run(["/usr/bin/say", "-o", str(out), text[:600]], capture_output=True, timeout=60)
        if done.returncode != 0 or not out.exists():
            return {"ok": False, "reason": "no_voice"}
        return call("/mouth/play", {"b64": base64.b64encode(out.read_bytes()).decode(), "text": text[:600]},
                    timeout=90)


# ── tools ────────────────────────────────────────────────────────────────────

def t_say(args: dict) -> str:
    text = " ".join(str(args.get("text") or "").split())
    if not text:
        return "Nothing to say: text is empty."
    if args.get("speak", True):
        r = _spoken(text)
        if r.get("ok"):
            return f"Iris said it aloud ({r.get('seconds', 0):.1f} s)."
        if r.get("reason") != "no_voice":
            return f"Iris didn't speak: {r.get('reason') or 'no reason given'}."
    r = call("/mouth/show", {"text": text[:300], "seconds": float(args.get("seconds") or 6)})
    return "Iris showed it in her bubble." if r.get("ok") else f"Iris didn't show it: {r.get('reason')}."


def t_react(args: dict) -> str:
    name = str(args.get("animation") or "").strip()
    r = call("/iris/act", {"id": name, "seconds": float(args.get("seconds") or 6)})
    if r.get("ok"):
        return f"Iris played {name}."
    if r.get("reason") == "no_such_animation":
        return f"Iris has no animation called {name!r}; iris_animations lists hers."
    return f"Iris didn't play it: {r.get('reason')}."


def t_animations(args: dict) -> str:
    r = call("/iris/catalog", method="GET")
    names = sorted(a.get("id", "") for a in r.get("animations") or [] if a.get("id"))
    return ("Her animations: " + ", ".join(names) + ".") if names else "Iris didn't list any animations."


def t_notice(args: dict) -> str:
    title = " ".join(str(args.get("what") or "").split())[:80]
    r = call("/iris/notice", {"title": title})
    return "Iris glanced up at it." if r.get("ok") else f"Iris didn't notice it: {r.get('reason')}."


def t_come(args: dict) -> str:
    to = args.get("to") or "cursor"
    r = call("/iris/come", {"to": to})
    return ("Iris is on her way." if r.get("ok") else f"Iris didn't come: {r.get('reason')}.")


def t_listen(args: dict) -> str:
    """What the person next says to her by name ("Iris, …") or types into her "Ask" box, waiting up to 25 s."""
    wait = min(25.0, max(1.0, float(args.get("seconds") or 20)))
    r = call("/ears/next", {"timeout": wait}, timeout=wait + 10)
    h = r.get("heard")
    if not h:
        return f"Nothing was said to Iris in {wait:.0f} s."
    how = "typed to her" if h.get("typed") else "said to her"
    return f"{how.capitalize()}: {h.get('text', '')}"


def t_screen(args: dict) -> str:
    r = call("/eyes/now", method="GET", timeout=5)
    if not r.get("ok"):
        return f"Iris can't see the screen right now: {r.get('reason') or 'no reason given'}."
    parts = [f"Front app: {r.get('front_app') or 'unknown'}", f"window: {r.get('front_title') or 'untitled'}"]
    for d in r.get("displays") or []:
        if d.get("text"):
            parts.append(f"display {d.get('id')}: {str(d['text'])[:1500]}")
    return "\n".join(parts)


TOOLS = {
    "iris_say": (t_say, "Make Iris say something to the person at the Mac, aloud with her lips moving (falls back "
                        "to her speech bubble when no voice is available). Keep it short and natural.",
                 {"text": {"type": "string", "description": "What she says."},
                  "speak": {"type": "boolean", "description": "Aloud (default) or bubble only."},
                  "seconds": {"type": "number", "description": "How long the bubble stays."}}, ["text"]),
    "iris_react": (t_react, "Play one of Iris's animations (a reaction such as think, nod or giggle). "
                            "Use iris_animations for the names.",
                   {"animation": {"type": "string"}, "seconds": {"type": "number"}}, ["animation"]),
    "iris_animations": (t_animations, "List Iris's animations by name.", {}, []),
    "iris_notice": (t_notice, "Have Iris glance up at something that just happened (a task finished, a test failed, "
                              "an approval is waiting): a look and a small '!', no words.",
                    {"what": {"type": "string", "description": "A few words on what happened."}}, ["what"]),
    "iris_listen": (t_listen, "Wait for what the person says to Iris by name (\"Iris, …\") or types into her Ask box, "
                              "up to 25 seconds; answer with iris_say to hold a spoken conversation through her. Only "
                              "speech addressed to her is ever returned.",
                    {"seconds": {"type": "number", "description": "How long to wait, 1-25 (default 20)."}}, []),
    "iris_come": (t_come, "Call Iris over: beside the pointer, or to the other screen.",
                  {"to": {"type": "string", "enum": ["cursor", "other_screen"]}}, []),
}
if SCREEN_ALLOWED:
    TOOLS["iris_screen"] = (t_screen, "What Iris sees on the screens right now: the front app, its window and the "
                                      "text she read off each display. Only offered when the person set "
                                      "IRIS_MCP_SCREEN=1.", {}, [])


# ── MCP over stdio ───────────────────────────────────────────────────────────

def _tool_list() -> list[dict]:
    return [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": props, "required": req}}
            for n, (_f, d, props, req) in TOOLS.items()]


def handle(msg: dict) -> dict | None:
    """One JSON-RPC message in, its reply out (None for a notification)."""
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if mid is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": PROTOCOL, "capabilities": {"tools": {}},
                  "serverInfo": {"name": "iris", "version": "0.1.0"}}
    elif method == "tools/list":
        result = {"tools": _tool_list()}
    elif method == "tools/call":
        name = params.get("name")
        if name not in TOOLS:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"unknown tool {name!r}"}}
        try:
            text, error = TOOLS[name][0](params.get("arguments") or {}), False
        except IrisUnreachable as e:
            text, error = str(e), True
        result = {"content": [{"type": "text", "text": text}], "isError": error}
    elif method == "ping":
        result = {}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"no method {method!r}"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        reply = handle(msg)
        if reply is not None:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

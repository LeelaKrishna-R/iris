"""The MCP server, against a fake Iris that checks every request is signed the way her link verifies it."""
import hashlib
import hmac
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents"))
import iris_mcp  # noqa: E402

KEY = b"test-key-0123456789"
DECISIONS: list = []          # what /iris/decisions answers, one poll at a time


@pytest.fixture
def iris(tmp_path, monkeypatch):
    seen = []

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _serve(self, method):
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            ts, nonce = self.headers["X-Iris-Ts"], self.headers["X-Iris-Nonce"]
            want = hmac.new(KEY, f"{ts}.{nonce}.{method} {self.path.split('?')[0]}.".encode() + raw,
                            hashlib.sha256).hexdigest()
            if self.headers.get("X-Iris-Sig2") != want:
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'{"ok": false, "reason": "bad_signature"}')
                return
            seen.append((method, self.path, json.loads(raw or b"{}")))
            reply = {"ok": True}
            if self.path == "/iris/catalog":
                reply = {"ok": True, "animations": [{"id": "wave"}, {"id": "think"}]}
            if self.path == "/iris/act" and json.loads(raw)["id"] not in ("wave", "think"):
                reply = {"ok": False, "reason": "no_such_animation"}
            if self.path == "/ears/next":
                reply = {"ok": True, "heard": {"text": "what's the weather", "typed": False}}
            if self.path == "/iris/decisions":
                reply = {"ok": True, "decisions": DECISIONS.pop(0) if DECISIONS else []}
            if self.path == "/eyes/now":
                reply = {"ok": True, "front_app": "Code", "front_title": "main.py", "displays": [{"id": 1, "text": "hi"}]}
            body = json.dumps(reply).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            self._serve("POST")

        def do_GET(self):
            self._serve("GET")

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    key = tmp_path / "link.key"
    key.write_bytes(KEY)
    monkeypatch.setattr(iris_mcp, "URL", f"http://127.0.0.1:{srv.server_address[1]}")
    monkeypatch.setattr(iris_mcp, "KEY_FILE", key)
    yield seen
    srv.shutdown()


def tool(name, **args):
    r = iris_mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}})
    return r["result"]["content"][0]["text"], r["result"]["isError"]


def test_initialize_and_list_offer_no_hands():
    init = iris_mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert init["result"]["serverInfo"]["name"] == "iris"
    names = {t["name"] for t in iris_mcp.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]}
    assert {"iris_say", "iris_react", "iris_animations", "iris_notice", "iris_come"} <= names
    assert not any(w in n for n in names for w in ("type", "click", "key", "press", "drag", "scroll"))
    assert "iris_screen" not in names                         # only when the person opts in


def test_bubble_when_not_spoken(iris):
    text, err = tool("iris_say", text="Tests passed.", speak=False)
    assert not err and text == "Iris showed it in her bubble."
    assert iris[-1] == ("POST", "/mouth/show", {"text": "Tests passed.", "seconds": 6.0})


def test_react_and_an_unknown_animation(iris):
    assert tool("iris_react", animation="wave")[0] == "Iris played wave."
    assert "no animation called 'moonwalk'" in tool("iris_react", animation="moonwalk")[0]
    assert tool("iris_animations")[0] == "Her animations: think, wave."


def test_notice_and_come(iris):
    assert tool("iris_notice", what="build finished")[0] == "Iris glanced up at it."
    assert iris[-1][1:] == ("/iris/notice", {"title": "build finished"})
    assert tool("iris_come", to="cursor")[0] == "Iris is on her way."


def test_iris_not_running_is_said(tmp_path, monkeypatch):
    key = tmp_path / "link.key"
    key.write_bytes(KEY)
    monkeypatch.setattr(iris_mcp, "KEY_FILE", key)
    monkeypatch.setattr(iris_mcp, "URL", "http://127.0.0.1:9")    # nothing listens
    text, err = tool("iris_notice", what="x")
    assert err and "isn't answering" in text


def test_no_key_is_said(tmp_path, monkeypatch):
    monkeypatch.setattr(iris_mcp, "KEY_FILE", tmp_path / "missing.key")
    text, err = tool("iris_notice", what="x")
    assert err and "link key isn't readable" in text


def test_stdio_round_trip():
    import subprocess
    p = subprocess.run([sys.executable, str(Path(iris_mcp.__file__))], capture_output=True, text=True, timeout=20,
                       input=json.dumps({"jsonrpc": "2.0", "id": 7, "method": "ping"}) + "\n")
    assert json.loads(p.stdout.strip()) == {"jsonrpc": "2.0", "id": 7, "result": {}}


def test_claude_code_hook_reacts_to_stop_and_notification(iris):
    import claude_code_hook as hook
    assert hook.react({"hook_event_name": "Stop"}) == "notice"
    assert iris[-1][1:] == ("/iris/notice", {"title": "Claude finished"})
    assert hook.react({"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"}) == "needs_you"
    assert [p for _m, p, _b in iris[-2:]] == ["/iris/come", "/mouth/show"]
    assert iris[-1][2]["text"] == "Claude needs your permission to use Bash"
    assert hook.react({"hook_event_name": "PreToolUse"}) == ""


def test_claude_code_hook_never_blocks_claude(tmp_path, monkeypatch):
    import subprocess
    p = subprocess.run([sys.executable, str(Path(iris_mcp.__file__).parent / "claude_code_hook.py")],
                       input='{"hook_event_name": "Stop"}', capture_output=True, text=True, timeout=20,
                       env={"IRIS_URL": "http://127.0.0.1:9", "IRIS_KEY_FILE": str(tmp_path / "none"), "PATH": "/usr/bin"})
    assert p.returncode == 0 and p.stdout == ""


def test_listen_returns_what_was_said_to_her(iris):
    assert tool("iris_listen", seconds=3)[0] == "Said to her: what's the weather"
    assert iris[-1][1:] == ("/ears/next", {"timeout": 3.0})


def test_codex_notify_reacts_to_a_finished_turn(iris):
    import codex_notify
    assert codex_notify.react({"type": "agent-turn-complete", "last-assistant-message": "All tests pass."}) == "notice"
    assert iris[-1][1:] == ("/iris/notice", {"title": "Codex: All tests pass."})
    assert codex_notify.react({"type": "something-else"}) == ""


def test_cursor_hook_reacts_to_stop(iris):
    import cursor_hook
    assert cursor_hook.react({"hook_event_name": "stop", "status": "completed"}) == "notice"
    assert iris[-1][1:] == ("/iris/notice", {"title": "Cursor finished"})
    assert cursor_hook.react({"hook_event_name": "stop", "status": "error"}) == "notice_error"
    assert cursor_hook.react({"hook_event_name": "stop", "status": "aborted"}) == ""
    assert cursor_hook.react({"hook_event_name": "afterFileEdit"}) == ""


def test_cli(iris):
    import iris_cli
    assert iris_cli.run(["say", "--bubble", "Build", "finished"]) == (0, "Iris showed it in her bubble.")
    assert iris[-1][2]["text"] == "Build finished"
    assert iris_cli.run(["react", "moonwalk"])[0] == 1
    assert iris_cli.run(["notice", "tests", "failed"]) == (0, "Iris glanced up at it.")
    assert iris_cli.run([])[0] == 64 and iris_cli.run(["dance-party"])[0] == 64


def test_cli_iris_down(tmp_path, monkeypatch):
    import iris_cli
    monkeypatch.setattr(iris_mcp, "KEY_FILE", tmp_path / "missing")
    assert iris_cli.run(["notice", "x"])[0] == 2


def test_voice_loop_turn_passes_words_to_the_agent_and_says_its_reply(iris):
    import voice_loop
    reply = voice_loop.turn(["echo", "You said:"], "what's on my calendar", speak=False)
    assert reply == "You said: what's on my calendar"
    paths = [p for _m, p, _b in iris]
    assert paths[-2:] == ["/iris/act", "/mouth/show"] and iris[-1][2]["text"] == reply


def test_voice_loop_turn_says_when_the_agent_cant_start(iris):
    import voice_loop
    assert voice_loop.turn(["/no/such/agent"], "hi", speak=False).startswith("I couldn't start the agent")


def test_ask_shows_the_card_and_returns_the_click(iris, monkeypatch):
    monkeypatch.setattr(iris_mcp, "POLL_S", 0)
    monkeypatch.setattr(iris_mcp.os, "urandom", lambda n: b"\x01" * n)
    DECISIONS[:] = [[], [{"id": "someone-else", "choice": "approve"}], [{"id": "mcp-010101010101", "choice": "reject"}]]
    assert tool("iris_ask", action="Delete the build folder")[0] == "Denied: don't do it."
    method, path, body = next(x for x in iris if x[1] == "/iris/ask")
    assert body["id"] == "mcp-010101010101" and body["text"] == "Delete the build folder"
    assert body["title"] == "Your agent asks"
    assert ("POST", "/iris/decisions_ack", {"ids": ["mcp-010101010101"]}) in iris     # only its own click confirmed
    assert not any(x[1] == "/iris/decisions_ack" and "someone-else" in x[2]["ids"] for x in iris)
    DECISIONS[:] = [[{"id": "mcp-010101010101", "choice": "approve"}]]
    assert tool("iris_ask", action="Push to main", title="Claude Code")[0] == "Allowed: go ahead."


def test_ask_with_no_answer_closes_the_card_and_allows_nothing(iris, monkeypatch):
    monkeypatch.setattr(iris_mcp, "POLL_S", 0)
    clock = iter(range(0, 10_000, 3))
    monkeypatch.setattr(iris_mcp.time, "time", lambda: float(next(clock)))
    DECISIONS[:] = []
    assert tool("iris_ask", action="Send the email", seconds=5)[0] == \
        "No answer in 5 s; the card was closed. Nothing was allowed."
    assert iris[-1][1] == "/iris/ask_done"


def test_ask_needs_an_action(iris):
    assert tool("iris_ask", action="  ")[0] == "Nothing to ask: action is empty."
    assert iris == []

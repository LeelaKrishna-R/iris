"""The agent hooks (Claude Code, Codex, Cursor), against the same signed fake Iris as the MCP tests: what each
event asks of her, and that nothing about Iris ever gets in the agent's way (exit 0, nothing on stdout)."""
import io
import json
import socket
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents"))
import claude_code_hook  # noqa: E402
import codex_notify  # noqa: E402
import cursor_hook  # noqa: E402
import iris_mcp  # noqa: E402
from test_mcp import iris  # noqa: E402,F401  (the fixture)


def stdin(monkeypatch, text):
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))


def test_claude_finishing_is_a_glance(iris, monkeypatch, capsys):
    stdin(monkeypatch, json.dumps({"hook_event_name": "Stop"}))
    assert claude_code_hook.main() == 0
    assert iris == [("POST", "/iris/notice", {"title": "Claude finished"})]
    assert capsys.readouterr().out == ""


def test_claude_needing_you_brings_her_over_with_its_words(iris):
    long = "Claude needs your permission to use Bash\n\n" + "x" * 300
    assert claude_code_hook.react({"hook_event_name": "Notification", "message": long}) == "needs_you"
    assert iris[0] == ("POST", "/iris/come", {"to": "cursor"})
    method, path, body = iris[1]
    assert path == "/mouth/show" and body["seconds"] == 8
    assert body["text"].startswith("Claude needs your permission to use Bash x") and len(body["text"]) == 120


def test_other_claude_events_ask_nothing(iris):
    assert claude_code_hook.react({"hook_event_name": "PreToolUse"}) == ""
    assert claude_code_hook.react({}) == ""
    assert iris == []


def test_codex_turn_names_what_it_said_last(iris):
    assert codex_notify.main(["codex_notify.py", json.dumps(
        {"type": "agent-turn-complete", "last-assistant-message": "Fixed   the failing\ntest " + "y" * 100})]) == 0
    (_, path, body), = iris
    assert path == "/iris/notice" and body["title"].startswith("Codex: Fixed the failing test y")
    assert len(body["title"]) == 80
    iris.clear()
    codex_notify.react({"type": "agent-turn-complete"})
    assert iris[0][2] == {"title": "Codex finished"}


def test_codex_other_events_and_bad_input(iris):
    assert codex_notify.main(["codex_notify.py", json.dumps({"type": "approval-requested"})]) == 0
    assert codex_notify.main(["codex_notify.py", "{not json"]) == 0
    assert codex_notify.main(["codex_notify.py"]) == 0
    assert iris == []


@pytest.mark.parametrize("status,title", [("completed", "Cursor finished"), ("error", "Cursor stopped with an error")])
def test_cursor_stop(iris, status, title):
    assert cursor_hook.react({"hook_event_name": "stop", "status": status})
    assert iris == [("POST", "/iris/notice", {"title": title})]


def test_cursor_aborted_or_another_hook_asks_nothing(iris):
    assert cursor_hook.react({"hook_event_name": "stop", "status": "aborted"}) == ""
    assert cursor_hook.react({"hook_event_name": "beforeShellExecution"}) == ""
    assert iris == []


def _closed_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


@pytest.mark.parametrize("hook", [claude_code_hook, cursor_hook])
def test_iris_not_running_never_blocks_the_agent(hook, tmp_path, monkeypatch, capsys):
    key = tmp_path / "link.key"
    key.write_bytes(b"k" * 32)
    monkeypatch.setattr(iris_mcp, "URL", f"http://127.0.0.1:{_closed_port()}")
    monkeypatch.setattr(iris_mcp, "KEY_FILE", key)
    stdin(monkeypatch, json.dumps({"hook_event_name": "Stop", "status": "completed"} if hook is claude_code_hook
                                  else {"hook_event_name": "stop", "status": "completed"}))
    assert hook.main() == 0
    out = capsys.readouterr()
    assert out.out == "" and out.err.startswith("iris: ")


@pytest.mark.parametrize("hook", [claude_code_hook, cursor_hook])
def test_unreadable_input_is_ignored(hook, iris, monkeypatch):
    stdin(monkeypatch, "not json at all")
    assert hook.main() == 0
    assert iris == []

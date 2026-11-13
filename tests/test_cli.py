"""`iris` from a terminal, against the same signed fake Iris as the MCP tests: each command's request, its
exit status (0 done, 1 Iris said no, 2 unreachable, 64 usage), and where its words go."""
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents"))
import iris_cli  # noqa: E402
import iris_mcp  # noqa: E402
from test_hooks import _closed_port  # noqa: E402
from test_mcp import iris  # noqa: E402,F401  (the fixture)


def _fake_say(monkeypatch):
    def run(cmd, **k):                                   # macOS's `say -o <file>`: writes the audio file
        Path(cmd[2]).write_bytes(b"FORM")
        return subprocess.CompletedProcess(cmd, 0)
    monkeypatch.setattr(iris_mcp.subprocess, "run", run)


def test_say_aloud_and_in_her_bubble(iris, monkeypatch):
    _fake_say(monkeypatch)
    code, out = iris_cli.run(["say", "Build", "finished"])
    assert code == 0 and out.startswith("Iris said it aloud"), out
    assert iris[-1][1] == "/mouth/play"
    code, out = iris_cli.run(["say", "--bubble", "Build", "finished"])
    assert (code, out) == (0, "Iris showed it in her bubble.")
    assert iris[-1] == ("POST", "/mouth/show", {"text": "Build finished", "seconds": 6.0})


def test_notice_react_come_and_animations(iris):
    assert iris_cli.run(["notice", "tests", "failed"]) == (0, "Iris glanced up at it.")
    assert ("POST", "/iris/notice", {"title": "tests failed"}) in iris
    assert iris_cli.run(["react", "wave"]) == (0, "Iris played wave.")
    assert iris_cli.run(["come"]) == (0, "Iris is on her way.")
    assert iris[-1] == ("POST", "/iris/come", {"to": "cursor"})
    assert iris_cli.run(["come", "other_screen"])[0] == 0 and iris[-1][2] == {"to": "other_screen"}
    assert iris_cli.run(["animations"]) == (0, "Her animations: think, wave.")


def test_an_animation_she_doesnt_have_is_a_no(iris):
    code, out = iris_cli.run(["react", "backflip"])
    assert code == 1 and "no animation called 'backflip'" in out


def test_listen_prints_what_was_said_to_her(iris):
    assert iris_cli.run(["listen", "5"]) == (0, "Said to her: what's the weather")
    assert iris[-1] == ("POST", "/ears/next", {"timeout": 5.0})


@pytest.mark.parametrize("argv", [[], ["say"], ["notice"], ["react"], ["dance"], ["listen", "soon"]])
def test_usage(iris, argv):
    code, out = iris_cli.run(argv)
    assert code == 64 and out.startswith("    iris say"), (argv, out)
    assert iris == []


def test_iris_not_running_is_exit_2(tmp_path, monkeypatch, capsys):
    key = tmp_path / "link.key"
    key.write_bytes(b"k" * 32)
    monkeypatch.setattr(iris_mcp, "URL", f"http://127.0.0.1:{_closed_port()}")
    monkeypatch.setattr(iris_mcp, "KEY_FILE", key)
    monkeypatch.setattr(sys, "argv", ["iris", "notice", "done"])
    assert iris_cli.main() == 2
    out = capsys.readouterr()
    assert out.out == "" and out.err.strip()                  # the reason, on stderr


def test_without_macos_say_she_shows_it_instead(iris, monkeypatch):
    def run(cmd, **k):
        raise FileNotFoundError(cmd[0])
    monkeypatch.setattr(iris_mcp.subprocess, "run", run)
    assert iris_cli.run(["say", "Build", "finished"]) == (0, "Iris showed it in her bubble.")


def test_busy_only_on_a_call(iris, monkeypatch):
    seen = {"ok": True, "front_app": "Code", "front_title": "main.py",
            "windows": [{"app": "Discord", "title": "#general - Discord"}], "mic_others": False}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, method="POST", timeout=10: dict(seen))
    assert iris_cli.run(["busy"]) == (1, "Not on a call.")          # Discord open for text
    seen["mic_others"] = True
    assert iris_cli.run(["busy"]) == (0, "On a call: Discord.")     # someone holds the mic with Discord open
    seen.update(windows=[{"app": "Safari", "title": "Meet - abc-defg-hij"}], mic_others=None)
    assert iris_cli.run(["busy"]) == (0, "On a call: Google Meet.")  # a meeting's own window counts by itself
    seen.update(ok=False, reason="paused")
    assert iris_cli.run(["busy"]) == (1, "Iris can't tell: paused.")


def test_say_uses_her_bubble_while_you_are_on_a_call(iris, monkeypatch):
    _fake_say(monkeypatch)
    real = iris_mcp.call
    eyes = {"ok": True, "front_app": "Code", "front_title": "x", "mic_others": True,
            "windows": [{"app": "zoom.us", "title": "Zoom Meeting"}]}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, method="POST", timeout=10:
                        dict(eyes) if path == "/eyes/now" else real(path, payload, method, timeout))
    assert iris_cli.run(["say", "Build", "finished"]) == (0, "Iris showed it in her bubble (you're on a call).")
    assert iris[-1] == ("POST", "/mouth/show", {"text": "Build finished", "seconds": 6.0})


def test_ask_exits_0_only_when_allowed(iris, monkeypatch):
    from test_mcp import DECISIONS
    monkeypatch.setattr(iris_mcp, "POLL_S", 0)
    monkeypatch.setattr(iris_mcp.os, "urandom", lambda n: b"\x02" * n)
    DECISIONS[:] = [[{"id": "mcp-020202020202", "choice": "approve"}]]
    assert iris_cli.run(["ask", "Deploy", "to", "production?"]) == (0, "Allowed: go ahead.")
    body = next(x[2] for x in iris if x[1] == "/iris/ask")
    assert body["text"] == "Deploy to production?" and body["title"] == "A script asks"
    DECISIONS[:] = [[{"id": "mcp-020202020202", "choice": "reject"}]]
    assert iris_cli.run(["ask", "Drop the table"]) == (1, "Denied: don't do it.")


def test_ask_with_no_answer_is_a_no(iris, monkeypatch):
    from test_mcp import DECISIONS
    monkeypatch.setattr(iris_mcp, "POLL_S", 0)
    clock = iter(range(0, 10_000, 4))
    monkeypatch.setattr(iris_mcp.time, "time", lambda: float(next(clock)))
    DECISIONS[:] = []
    code, out = iris_cli.run(["ask", "--wait", "8", "Send", "the", "invoices"])
    assert code == 1 and out.startswith("No answer in 8 s")
    assert next(x[2] for x in iris if x[1] == "/iris/ask")["text"] == "Send the invoices"


@pytest.mark.parametrize("argv", [["ask"], ["ask", "--wait"], ["ask", "--wait", "soon", "x"], ["ask", "--wait", "10"]])
def test_ask_usage(iris, argv):
    assert iris_cli.run(argv)[0] == 64
    assert iris == []


@pytest.mark.parametrize("argv", [["help"], ["--help"], ["-h"]])
def test_asking_for_help_is_not_an_error(argv, capsys):
    assert iris_cli.run(argv) == (0, iris_cli.USAGE)
    sys.argv = ["iris", *argv]
    assert iris_cli.main() == 0
    out = capsys.readouterr()
    assert "iris say" in out.out and not out.err

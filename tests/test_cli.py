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

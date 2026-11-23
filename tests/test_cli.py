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


def test_say_with_a_tone_colours_her_bubble(iris, monkeypatch):
    code, out = iris_cli.run(["say", "--bubble", "--tone", "urgent", "Disk", "full"])
    assert (code, out) == (0, "Iris showed it in her bubble.")
    assert iris[-1] == ("POST", "/mouth/show", {"text": "Disk full", "seconds": 6.0, "tone": "urgent"})
    _fake_say(monkeypatch)
    assert iris_cli.run(["say", "Review", "waiting", "--tone", "needs-you"])[0] == 0
    assert iris[-1][1] == "/mouth/play" and iris[-1][2]["tone"] == "needs_you"
    assert iris_cli.run(["say", "--tone", "calm", "--bubble", "ok"])[0] == 0
    assert "tone" not in iris[-1][2]                     # calm is her default: nothing to send


def test_say_seconds_keeps_her_bubble_up_that_long(iris):
    assert iris_cli.run(["say", "--bubble", "--seconds", "15", "Tests", "passed"]) == (0, "Iris showed it in her bubble.")
    assert iris[-1] == ("POST", "/mouth/show", {"text": "Tests passed", "seconds": 15.0})


@pytest.mark.parametrize("argv", [["say", "--seconds", "soon", "hi"], ["say", "hi", "--seconds"],
                                  ["say", "--seconds", "0", "hi"], ["say", "--seconds", "600", "hi"]])
def test_seconds_that_isnt_a_bubble_length_is_usage_and_says_nothing(iris, argv):
    code, out = iris_cli.run(argv)
    assert code == 64, (argv, out)
    assert iris == []


@pytest.mark.parametrize("argv", [["say", "--tone", "loud", "hi"], ["say", "hi", "--tone"]])
def test_a_tone_she_doesnt_have_is_usage_and_says_nothing(iris, argv):
    code, out = iris_cli.run(argv)
    assert code == 64, (argv, out)
    assert iris == []


def test_notice_react_come_and_animations(iris):
    assert iris_cli.run(["notice", "tests", "failed"]) == (0, "Iris glanced up at it.")
    assert ("POST", "/iris/notice", {"title": "tests failed"}) in iris
    assert iris_cli.run(["react", "wave"]) == (0, "Iris played wave.")
    assert iris_cli.run(["come"]) == (0, "Iris is on her way.")
    assert iris[-1] == ("POST", "/iris/come", {"to": "cursor"})
    assert iris_cli.run(["come", "other_screen"])[0] == 0 and iris[-1][2] == {"to": "other_screen"}
    assert iris_cli.run(["animations"]) == (0, "Her animations: think, wave.")


def test_animations_she_cant_list_is_a_no_with_her_reason(iris, monkeypatch):
    monkeypatch.setattr(iris_mcp, "call", lambda *a, **k: {"ok": False, "reason": "paused"})
    assert iris_cli.run(["animations"]) == (1, "Iris didn't list her animations: paused.")
    monkeypatch.setattr(iris_mcp, "call", lambda *a, **k: {"ok": True, "animations": []})
    assert iris_cli.run(["animations"]) == (1, "Iris didn't list any animations.")


def test_an_animation_she_doesnt_have_is_a_no(iris):
    code, out = iris_cli.run(["react", "backflip"])
    assert code == 1 and "no animation called 'backflip'" in out


def test_screen_prints_what_she_sees(iris, monkeypatch):
    assert iris_cli.run(["screen"]) == (0, "Front app: Code\nwindow: main.py\ndisplay 1: hi")
    assert iris[-1][:2] == ("GET", "/eyes/now")
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, **k: {"ok": False, "reason": "no_screen_recording"})
    assert iris_cli.run(["screen"]) == (1, "Iris can't see the screen right now: no_screen_recording.")


def test_screen_json_for_a_script(iris, monkeypatch):
    import json
    code, out = iris_cli.run(["screen", "--json"])
    assert code == 0 and json.loads(out) == {"seen": True, "front_app": "Code", "window": "main.py",
                                             "displays": [{"id": 1, "text": "hi"}]}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, **k: {"ok": False, "reason": "paused"})
    code, out = iris_cli.run(["screen", "--json"])
    assert code == 1 and json.loads(out) == {"seen": False, "reason": "paused"}


def test_listen_prints_what_was_said_to_her(iris):
    assert iris_cli.run(["listen", "5"]) == (0, "Said to her: what's the weather")
    assert iris[-1] == ("POST", "/ears/next", {"timeout": 5.0})


def test_listen_json_gives_the_words_alone(iris, monkeypatch):
    import json
    code, out = iris_cli.run(["listen", "5", "--json"])
    assert code == 0 and json.loads(out) == {"heard": "what's the weather", "typed": False,
                                             "said": "Said to her: what's the weather"}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, **k: {"ok": True, "heard": None})
    code, out = iris_cli.run(["listen", "--json", "3"])
    assert code == 1 and json.loads(out)["heard"] is None and json.loads(out)["typed"] is None


def test_listen_with_nothing_said_exits_1(monkeypatch):
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, **k: {"ok": True, "heard": None})
    assert iris_cli.run(["listen", "3"]) == (1, "Nothing was said to Iris in 3 s.")


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


def test_health_says_what_she_can_do(monkeypatch):
    seen = []

    def call(path, payload=None, method="POST", timeout=10):
        seen.append((method, path))
        return {"ok": True, "version": "0.1",
                "permissions": {"screen": True, "accessibility": False, "microphone": True},
                "ears": {"listening": False, "problem": "no_microphone"}}

    monkeypatch.setattr(iris_mcp, "call", call)
    code, out = iris_cli.run(["health"])
    assert code == 0 and seen == [("GET", "/health")]
    assert out.splitlines() == ["Iris 0.1 is running.",
                                "Screen Recording: allowed. Accessibility: not allowed. Microphone: allowed.",
                                "Ears: not listening (no_microphone)."]


def test_json_goes_to_stdout_whatever_the_exit_code(tmp_path, monkeypatch, capsys):
    import json
    monkeypatch.setattr(iris_cli, "run", lambda argv: (1, '{"on_call": false, "app": null, "said": "Not on a call."}'))
    monkeypatch.setattr(sys, "argv", ["iris", "busy", "--json"])
    assert iris_cli.main() == 1
    out = capsys.readouterr()
    assert json.loads(out.out)["on_call"] is False and out.err == ""


def test_json_when_she_is_not_running_is_json(tmp_path, monkeypatch, capsys):
    import json
    key = tmp_path / "link.key"
    key.write_bytes(b"k" * 32)
    monkeypatch.setattr(iris_mcp, "URL", f"http://127.0.0.1:{_closed_port()}")
    monkeypatch.setattr(iris_mcp, "KEY_FILE", key)
    monkeypatch.setattr(sys, "argv", ["iris", "health", "--json"])
    assert iris_cli.main() == 2
    got = json.loads(capsys.readouterr().out)
    assert got["reachable"] is False and "isn't answering" in got["reason"]


def test_health_when_she_is_not_running(tmp_path, monkeypatch):
    def call(*a, **k):
        raise iris_mcp.IrisUnreachable("Iris isn't answering; is she running?")

    monkeypatch.setattr(iris_mcp, "call", call)
    code, out = iris_cli.run(["health"])
    assert code == 2 and "isn't answering" in out


def test_snapshot_saves_her_picture(tmp_path, monkeypatch):
    import base64
    png = b"\x89PNG\r\n\x1a\nfake"
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, method="POST", timeout=10:
                        {"ok": True, "png": base64.b64encode(png).decode(), "iris": {}} if path == "/iris/snapshot" else {})
    out_file = tmp_path / "iris.png"
    code, out = iris_cli.run(["snapshot", str(out_file)])
    assert code == 0 and out_file.read_bytes() == png and str(out_file) in out


def test_snapshot_when_she_has_no_picture(tmp_path, monkeypatch):
    monkeypatch.setattr(iris_mcp, "call", lambda *a, **k: {"ok": False, "reason": "no_image"})
    code, out = iris_cli.run(["snapshot", str(tmp_path / "x.png")])
    assert code == 1 and "no_image" in out and not (tmp_path / "x.png").exists()


def test_snapshot_to_a_folder_that_isnt_there_says_so(tmp_path, monkeypatch):
    import base64
    monkeypatch.setattr(iris_mcp, "call", lambda *a, **k: {"ok": True, "png": base64.b64encode(b"png").decode()})
    target = tmp_path / "missing" / "iris.png"
    code, out = iris_cli.run(["snapshot", str(target)])
    assert code == 1 and out.startswith(f"Couldn't save her picture to {target}: ") and not target.exists()


def test_snapshot_with_an_unreadable_picture_saves_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(iris_mcp, "call", lambda *a, **k: {"ok": True, "png": "not base64!"})
    code, out = iris_cli.run(["snapshot", str(tmp_path / "x.png")])
    assert (code, out) == (1, "Iris sent a picture that couldn't be read; nothing was saved.")
    assert not (tmp_path / "x.png").exists()


def test_say_dash_reads_stdin(iris, monkeypatch):
    import io
    code, out = iris_cli.run(["say", "--bubble", "-"], stdin=io.StringIO("3 passed,\n 1 failed\n"))
    assert (code, out) == (0, "Iris showed it in her bubble.")
    assert iris[-1] == ("POST", "/mouth/show", {"text": "3 passed, 1 failed", "seconds": 6.0})
    assert iris_cli.run(["say", "-"], stdin=io.StringIO("  \n")) == (64, "Nothing to say: nothing came in on stdin.")


def test_health_json_for_scripts(monkeypatch):
    import json

    def call(path, payload=None, method="POST", timeout=10):
        return {"ok": True, "version": "0.1",
                "permissions": {"screen": True, "microphone": False},
                "ears": {"listening": False, "problem": "no_microphone"}}

    monkeypatch.setattr(iris_mcp, "call", call)
    code, out = iris_cli.run(["health", "--json"])
    assert code == 0 and json.loads(out) == {
        "running": True, "version": "0.1", "permissions": {"screen": True, "microphone": False},
        "listening": False, "ears_problem": "no_microphone"}
    assert iris_cli.run(["health", "--yaml"])[0] == 64


def test_ask_json_says_the_decision_as_one_word(iris, monkeypatch):
    import json
    from test_mcp import DECISIONS
    monkeypatch.setattr(iris_mcp, "POLL_S", 0)
    monkeypatch.setattr(iris_mcp.os, "urandom", lambda n: b"\x02" * n)
    DECISIONS[:] = [[{"id": "mcp-020202020202", "choice": "approve"}]]
    code, out = iris_cli.run(["ask", "--json", "Deploy?"])
    assert code == 0 and json.loads(out) == {"decision": "allowed", "said": "Allowed: go ahead."}
    DECISIONS[:] = [[{"id": "mcp-020202020202", "choice": "reject"}]]
    code, out = iris_cli.run(["ask", "Drop", "it", "--json"])
    assert code == 1 and json.loads(out)["decision"] == "denied"


def test_wait_free_returns_when_the_call_ends(iris, monkeypatch):
    seen = {"ok": True, "front_app": "zoom.us", "front_title": "Zoom Meeting", "windows": [], "mic_others": True}
    answers = [True, True, False]

    def call(path, payload=None, method="POST", timeout=10):
        on = answers.pop(0)
        return dict(seen, front_app="zoom.us" if on else "Code", front_title="Zoom Meeting" if on else "main.py",
                    mic_others=on)
    monkeypatch.setattr(iris_mcp, "call", call)
    monkeypatch.setattr(iris_cli, "WAIT_FREE_POLL_S", 0)
    assert iris_cli.run(["wait-free"]) == (0, "Not on a call.") and answers == []


@pytest.mark.parametrize("limit", ["nan", "inf", "-5", "90000"])
def test_wait_free_limit_that_isnt_a_wait_is_usage_and_asks_nothing(iris, limit):
    assert iris_cli.run(["wait-free", limit]) == (64, "wait-free waits 0 to 86400 seconds (0 checks once).")
    assert iris == []


def test_wait_free_gives_up_at_its_limit_and_when_she_cant_tell(iris, monkeypatch):
    seen = {"ok": True, "front_app": "zoom.us", "front_title": "Zoom Meeting", "windows": [], "mic_others": True}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, method="POST", timeout=10: dict(seen))
    monkeypatch.setattr(iris_cli, "WAIT_FREE_POLL_S", 0)
    code, out = iris_cli.run(["wait-free", "0"])
    assert code == 1 and out.startswith("Still on a call: ") and out.endswith("after 0 s.")
    seen.update(ok=False, reason="paused")
    assert iris_cli.run(["wait-free", "30"]) == (1, "Iris can't tell: paused.")


def test_busy_json_says_unknown_as_null(iris, monkeypatch):
    import json
    seen = {"ok": True, "front_app": "Code", "front_title": "main.py",
            "windows": [{"app": "Discord", "title": "#general - Discord"}], "mic_others": True}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, method="POST", timeout=10: dict(seen))
    code, out = iris_cli.run(["busy", "--json"])
    assert code == 0 and json.loads(out) == {"on_call": True, "app": "Discord", "said": "On a call: Discord."}
    seen["mic_others"] = False
    assert json.loads(iris_cli.run(["busy", "--json"])[1])["on_call"] is False
    seen.update(ok=False, reason="paused")
    code, out = iris_cli.run(["busy", "--json"])
    assert code == 1 and json.loads(out)["on_call"] is None

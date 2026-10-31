"""The voice loop: what you said goes to the agent as its last argument, and what Iris is given to say is the agent's
own reply, or a plain sentence when the agent fails, hangs or can't start. Iris herself is faked; the agents are real
processes (small Python one-liners)."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agents"))
import iris_mcp  # noqa: E402
import voice_loop  # noqa: E402

PY = [sys.executable, "-c"]


@pytest.fixture
def iris(monkeypatch):
    seen = {"calls": [], "said": []}
    monkeypatch.setattr(iris_mcp, "call", lambda path, payload=None, **k: seen["calls"].append((path, payload)) or {})
    monkeypatch.setattr(iris_mcp, "t_say", lambda args: seen["said"].append(args) or "ok")
    return seen


def test_the_agents_reply_is_what_she_says(iris):
    agent = PY + ["import sys; print('You said:', sys.argv[-1])"]
    assert voice_loop.turn(agent, "what's on my screen", speak=True) == "You said: what's on my screen"
    assert iris["calls"][0] == ("/iris/act", {"id": "think", "seconds": 8})       # thinking while it works
    assert iris["said"] == [{"text": "You said: what's on my screen", "speak": True}]


def test_the_bubble_instead_of_her_voice(iris):
    voice_loop.turn(PY + ["print('hi')"], "hello", speak=False)
    assert iris["said"] == [{"text": "hi", "speak": False}]


def test_an_agent_that_fails_is_said_plainly(iris):
    agent = PY + ["import sys; sys.stderr.write('no API key'); sys.exit(1)"]
    assert voice_loop.turn(agent, "hi", speak=True) == "The agent stopped with an error: no API key"


def test_an_agent_that_hangs_is_said_plainly(iris):
    assert voice_loop.turn(PY + ["import time; time.sleep(5)"], "hi", speak=True, timeout=0.5) == (
        "The agent didn't answer in time.")


def test_an_agent_that_cant_start_is_said_plainly(iris):
    said = voice_loop.turn(["/no/such/agent-binary"], "hi", speak=True)
    assert said.startswith("I couldn't start the agent:"), said


def test_a_long_reply_is_cut_for_her_voice(iris):
    voice_loop.turn(PY + ["print('x' * 900)"], "hi", speak=True)
    assert len(iris["said"][0]["text"]) == 600


def test_no_agent_given_is_an_error(capsys):
    with pytest.raises(SystemExit):
        voice_loop.main([])
    assert "give the agent command after --" in capsys.readouterr().err


def test_iris_not_running_exits_2(monkeypatch, capsys):
    def down(*a, **k):
        raise iris_mcp.IrisUnreachable("Iris isn't running")
    monkeypatch.setattr(iris_mcp, "call", down)
    assert voice_loop.main(["--", "echo"]) == 2
    assert "Iris isn't running" in capsys.readouterr().err


def test_what_she_heard_reaches_the_agent_until_ctrl_c(monkeypatch, iris, capsys):
    heard = iter([{"heard": {"text": "hello"}}, {"heard": None}])

    def ears(path, payload=None, **k):
        if path == "/ears/next":
            try:
                return next(heard)
            except StopIteration:
                raise KeyboardInterrupt
        return {}
    monkeypatch.setattr(iris_mcp, "call", ears)
    assert voice_loop.main(["--"] + PY + ["import sys; print(sys.argv[-1].upper())"]) == 0
    assert iris["said"] == [{"text": "HELLO", "speak": True}]

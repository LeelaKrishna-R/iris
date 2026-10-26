#!/usr/bin/env python3
"""Talk to any agent out loud through Iris.

Say "Iris, …" (or type into her Ask box, ⌃⌥Space). What you said goes to an agent command as its last argument;
its reply comes back in her voice. Ctrl-C stops it.

    python3 voice_loop.py -- claude -p             # Claude Code, one-shot
    python3 voice_loop.py -- codex exec            # Codex
    python3 voice_loop.py --bubble -- my-agent     # her speech bubble instead of her voice

The agent's reply is said as it printed it (up to 600 characters aloud); nothing is sent anywhere else.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import iris_mcp as m  # noqa: E402

THINKING = "think"


def turn(agent: list[str], said: str, speak: bool, timeout: float = 180) -> str:
    """One exchange: `said` to the agent, its reply to Iris. Returns what she was given to say."""
    m.call("/iris/act", {"id": THINKING, "seconds": 8})          # her thinking pose while the agent works
    try:
        out = subprocess.run(agent + [said], capture_output=True, text=True, timeout=timeout)
        reply = " ".join((out.stdout or "").split()) or " ".join((out.stderr or "").split())[:300]
        if out.returncode != 0 and not out.stdout.strip():
            reply = f"The agent stopped with an error: {reply or 'no output'}"
    except subprocess.TimeoutExpired:
        reply = "The agent didn't answer in time."
    except OSError as e:
        reply = f"I couldn't start the agent: {e.strerror}."
    m.t_say({"text": reply[:600], "speak": speak})
    return reply


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bubble", action="store_true", help="her speech bubble instead of her voice")
    ap.add_argument("agent", nargs=argparse.REMAINDER, help="the agent command, after --")
    a = ap.parse_args(argv)
    agent = [x for x in a.agent if x != "--"]
    if not agent:
        ap.error("give the agent command after --, e.g.: -- claude -p")
    print(f"Listening for \"Iris, …\" → {' '.join(agent)}  (Ctrl-C to stop)", file=sys.stderr)
    try:
        while True:
            h = m.call("/ears/next", {"timeout": 25}, timeout=35).get("heard")
            if h and h.get("text"):
                print(f"you: {h['text']}", file=sys.stderr)
                print(f"agent: {turn(agent, h['text'], speak=not a.bubble)}", file=sys.stderr)
    except KeyboardInterrupt:
        return 0
    except m.IrisUnreachable as e:
        print(f"iris: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

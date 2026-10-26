#!/usr/bin/env python3
"""Iris reacts to OpenAI Codex CLI: its `notify` program (Codex passes one JSON argument per event).

    agent-turn-complete   Codex finished its turn → she glances up ("!") at what it said last, no words

In your user-level ~/.codex/config.toml (Codex ignores notify in a project-local .codex/config.toml):

    notify = ["python3", "/path/to/iris/agents/codex_notify.py"]

Never in Codex's way: it exits 0 whatever happens with Iris, and prints nothing to stdout.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from iris_mcp import IrisUnreachable, call  # noqa: E402


def react(event: dict) -> str:
    """What Iris was asked to do for this Codex event ("" when it isn't one she reacts to)."""
    if event.get("type") == "agent-turn-complete":
        last = " ".join(str(event.get("last-assistant-message") or "").split())
        call("/iris/notice", {"title": ("Codex: " + last)[:80] if last else "Codex finished"})
        return "notice"
    return ""


def main(argv: list[str]) -> int:
    try:
        event = json.loads(argv[1]) if len(argv) > 1 else {}
    except ValueError:
        return 0
    try:
        react(event)
    except IrisUnreachable as e:
        print(f"iris: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

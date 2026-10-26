#!/usr/bin/env python3
"""Iris reacts to Cursor's agent: a Cursor hook (reads the hook event as JSON on stdin).

    stop   the agent finished     completed → she glances up ("!"); error → a glance that says so; aborted → nothing

In ~/.cursor/hooks.json (or a project's .cursor/hooks.json):

    {"version": 1,
     "hooks": {"stop": [{"type": "command", "command": "python3 /path/to/iris/agents/cursor_hook.py"}]}}

Never in Cursor's way: it prints nothing (so nothing is read as a decision or a follow-up) and exits 0.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from iris_mcp import IrisUnreachable, call  # noqa: E402


def react(event: dict) -> str:
    """What Iris was asked to do for this Cursor event ("" when it isn't one she reacts to)."""
    if event.get("hook_event_name") != "stop":
        return ""
    status = event.get("status")
    if status == "completed":
        call("/iris/notice", {"title": "Cursor finished"})
        return "notice"
    if status == "error":
        call("/iris/notice", {"title": "Cursor stopped with an error"})
        return "notice_error"
    return ""


def main() -> int:
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    try:
        react(event)
    except IrisUnreachable as e:
        print(f"iris: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

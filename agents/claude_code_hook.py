#!/usr/bin/env python3
"""Iris reacts to Claude Code's work: a Claude Code hook (reads the hook event as JSON on stdin).

    Stop          Claude finished its turn        → she glances up ("!"), no words
    Notification  Claude needs you (a permission, or it's waiting on your input)
                                                   → she comes to your pointer and says so in her bubble

Add to ~/.claude/settings.json (or a project's .claude/settings.json):

    {"hooks": {
       "Stop":         [{"hooks": [{"type": "command", "command": "python3 /path/to/iris/agents/claude_code_hook.py"}]}],
       "Notification": [{"hooks": [{"type": "command", "command": "python3 /path/to/iris/agents/claude_code_hook.py"}]}]
    }}

It never blocks Claude: whatever happens with Iris, it exits 0 and prints nothing to stdout.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from iris_mcp import IrisUnreachable, call  # noqa: E402


def react(event: dict) -> str:
    """What Iris was asked to do for this hook event ("" when the event isn't one she reacts to)."""
    name = event.get("hook_event_name") or ""
    if name == "Stop":
        call("/iris/notice", {"title": "Claude finished"})
        return "notice"
    if name == "Notification":
        said = " ".join(str(event.get("message") or "Claude needs you").split())[:120]
        call("/iris/come", {"to": "cursor"})
        call("/mouth/show", {"text": said, "seconds": 8})
        return "needs_you"
    return ""


def main() -> int:
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    try:
        react(event)
    except IrisUnreachable as e:
        print(f"iris: {e}", file=sys.stderr)          # never in Claude's way
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

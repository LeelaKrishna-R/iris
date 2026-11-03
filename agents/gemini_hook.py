#!/usr/bin/env python3
"""Iris reacts to Gemini CLI: a Gemini CLI hook (reads the hook event as JSON on stdin).

    AfterAgent    Gemini finished its turn        → she glances up ("!"), no words
    Notification  Gemini needs your permission for a tool
                                                   → she comes to your pointer and says so in her bubble

Add to ~/.gemini/settings.json (or a project's .gemini/settings.json):

    {"hooks": {
       "AfterAgent":   [{"hooks": [{"type": "command", "command": "python3 /path/to/iris/agents/gemini_hook.py"}]}],
       "Notification": [{"hooks": [{"type": "command", "command": "python3 /path/to/iris/agents/gemini_hook.py"}]}]
    }}

Gemini reads a hook's stdout as JSON, so this prints "{}" (no decision) and exits 0 whatever happens with Iris:
it never retries, blocks or halts Gemini.
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
    if name == "AfterAgent":
        call("/iris/notice", {"title": "Gemini finished"})
        return "notice"
    if name == "Notification":
        said = " ".join(str(event.get("message") or "Gemini needs you").split())[:120]
        call("/iris/come", {"to": "cursor"})
        call("/mouth/show", {"text": said, "seconds": 8})
        return "needs_you"
    return ""


def main() -> int:
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        event = None
    if isinstance(event, dict):                       # valid JSON that isn't an event is ignored
        try:
            react(event)
        except IrisUnreachable as e:
            print(f"iris: {e}", file=sys.stderr)      # never in Gemini's way
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

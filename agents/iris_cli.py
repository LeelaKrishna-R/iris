#!/usr/bin/env python3
"""`iris` from a terminal, a script or any agent that can run a command.

    iris say "Build finished"          aloud (macOS voice) with her lips moving; --bubble for her speech bubble only;
                                       --tone notice|needs_you|urgent colours the bubble by how much it matters;
                                       --seconds 12 keeps a bubble up that long (default 6)
    make 2>&1 | tail -1 | iris say -   "-" says what comes in on stdin
    iris notice "tests failed"         a glance and a small "!", no words
    iris react giggle                  one of her animations (`iris animations` lists them)
    iris come [cursor|other_screen]    she comes over
    iris listen [seconds]              prints what's said to her by name next (up to 25 s), or exits 1 on silence
    iris busy [--json]                 exit 0 if you're on a call (Zoom, Meet, Discord with the mic in use, …), else 1
    iris wait-free [600]               waits until you're off a call (up to 600 s): `iris wait-free && iris say done`
    iris ask [--wait 120] "Deploy?"    an Allow / Deny card beside her; exit 0 only if you click Allow in time
                                       (--json prints {"decision": "allowed"|"denied"|"no_answer"|"not_shown", ...})
    iris health [--json]               whether she's running, which permissions she has, whether she can hear
    iris snapshot [file.png]           saves a picture of her as she looks right now (for a bug report)
    iris help                          this list

Exit status: 0 done, 1 Iris said no (the reason is printed), 2 Iris isn't reachable, 64 usage.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import iris_mcp as m  # noqa: E402

USAGE = __doc__.split("\n\n")[1]


def run(argv: list[str], stdin=None) -> tuple[int, str]:
    if not argv:
        return 64, USAGE
    if argv[0] in ("help", "--help", "-h"):
        return 0, USAGE                                   # asked for, so stdout and 0: `iris --help | less` works
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "say" and rest:
            seconds = 6.0
            if "--seconds" in rest:                       # a missing or non-number value is usage (64)
                i = rest.index("--seconds")
                seconds, rest = float(rest[i + 1]), rest[:i] + rest[i + 2:]
                if not 1 <= seconds <= 60:
                    return 64, "--seconds is how long her bubble stays: 1 to 60."
            tone = "calm"
            if "--tone" in rest:                          # a missing value is usage (64)
                i = rest.index("--tone")
                tone, rest = rest[i + 1], rest[:i] + rest[i + 2:]
                m._tone({"tone": tone})                   # one that isn't a tone is usage too, before anything is said
            bubble = "--bubble" in rest
            text = " ".join(a for a in rest if a != "--bubble")
            if text == "-":
                text = " ".join((stdin or sys.stdin).read().split())
                if not text:
                    return 64, "Nothing to say: nothing came in on stdin."
            out = m.t_say({"text": text, "speak": not bubble, "tone": tone, "seconds": seconds})
            return (0 if out.startswith("Iris said") or out.startswith("Iris showed") else 1), out
        if cmd == "notice" and rest:
            out = m.t_notice({"what": " ".join(rest)})
            return (0 if out.startswith("Iris glanced") else 1), out
        if cmd == "react" and rest:
            out = m.t_react({"animation": rest[0]})
            return (0 if out.startswith("Iris played") else 1), out
        if cmd == "animations":
            return 0, m.t_animations({})
        if cmd == "come":
            out = m.t_come({"to": rest[0] if rest else "cursor"})
            return (0 if out.startswith("Iris is on her way") else 1), out
        if cmd == "busy":
            out = m.t_busy({})
            code = 0 if out.startswith("On a call") else 1
            return code, (_busy_json(out) if "--json" in rest else out)
        if cmd == "wait-free":
            # exit 0 as soon as you're off a call; 1 if you're still on one when the time is up, or she can't tell
            # (paused, not running): waiting on an answer that isn't coming would only hold the script up
            limit = float(rest[0]) if rest else 600.0     # a non-number is usage (64)
            start = time.monotonic()
            while True:
                out = m.t_busy({})
                if out.startswith("Not on a call"):
                    return 0, out
                if not out.startswith("On a call"):
                    return 1, out
                if time.monotonic() - start >= limit:
                    return 1, f"Still {out[0].lower()}{out[1:]} after {limit:g} s."
                time.sleep(WAIT_FREE_POLL_S)
        if cmd == "ask":
            # iris ask "Deploy to production?" && ./deploy.sh — Deny, no answer, or a card she couldn't show is 1
            wait = 120.0
            as_json = "--json" in rest
            rest = [a for a in rest if a != "--json"]
            if rest[:1] == ["--wait"]:
                wait, rest = float(rest[1]), rest[2:]          # a missing or non-number value is usage (64)
            if not rest:
                return 64, USAGE
            out = m.t_ask({"action": " ".join(rest), "title": "A script asks", "seconds": wait})
            code = 0 if out.startswith("Allowed") else 1
            return code, (_ask_json(out) if as_json else out)
        if cmd == "snapshot":
            return _snapshot(rest[0] if rest else "iris-snapshot.png")
        if cmd == "health":
            h = m.call("/health", method="GET")
            if rest == ["--json"]:
                return 0, _health_json(h)
            return (64, USAGE) if rest else (0, _health(h))
        if cmd == "listen":
            # silence is 1, so `if said=$(iris listen 10); then …` acts only on an answer
            out = m.t_listen({"seconds": float(rest[0]) if rest else 20})
            return (1 if out.startswith("Nothing was said") else 0), out
    except m.IrisUnreachable as e:
        return 2, str(e)
    except (ValueError, IndexError):
        return 64, USAGE
    return 64, USAGE


def _snapshot(path: str) -> tuple[int, str]:
    """GET /iris/snapshot: her current picture, written to `path`; a reply without one says why and writes nothing."""
    import base64
    got = m.call("/iris/snapshot", method="GET")
    if not got.get("ok") or not got.get("png"):
        return 1, f"Iris has no picture to give right now ({got.get('reason') or 'no reason given'})."
    Path(path).write_bytes(base64.b64decode(got["png"]))
    return 0, f"Saved her picture to {path}."


_PERMS = (("screen", "Screen Recording"), ("accessibility", "Accessibility"), ("microphone", "Microphone"))


WAIT_FREE_POLL_S = 5.0


def _busy_json(said: str) -> str:
    """For a script: {"on_call": true | false | null, "app": what the call is in or null, "said": her sentence}.
    null when she can't tell (paused, not running): unknown is never said as "not on a call"."""
    import json
    if said.startswith("On a call: "):
        return json.dumps({"on_call": True, "app": said[len("On a call: "):].rstrip("."), "said": said})
    return json.dumps({"on_call": False if said.startswith("Not on a call") else None, "app": None, "said": said})


def _ask_json(said: str) -> str:
    """An ask's outcome for a script: the decision as one word, and her sentence as she said it."""
    import json
    decision = ("allowed" if said.startswith("Allowed") else "denied" if said.startswith("Denied")
                else "no_answer" if said.startswith("No answer") else "not_shown")
    return json.dumps({"decision": decision, "said": said})


def _health_json(h: dict) -> str:
    """The same three facts for a script: {"running", "version", "permissions", "listening", "ears_problem"}.
    A permission she didn't report is left out, never guessed."""
    import json
    perms = h.get("permissions") or {}
    ears = h.get("ears") or {}
    return json.dumps({"running": True, "version": h.get("version"),
                       "permissions": {k: bool(perms[k]) for k, _ in _PERMS if k in perms},
                       "listening": bool(ears.get("listening")),
                       "ears_problem": None if ears.get("listening") else ears.get("problem")})


def _health(h: dict) -> str:
    """GET /health in three lines: running, her macOS permissions, her ears."""
    perms = h.get("permissions") or {}
    said = [f"{name}: {'allowed' if perms.get(key) else 'not allowed'}." for key, name in _PERMS if key in perms]
    ears = h.get("ears") or {}
    hearing = "listening" if ears.get("listening") else "not listening"
    if not ears.get("listening") and ears.get("problem"):
        hearing += f" ({ears['problem']})"
    return "\n".join([f"Iris {h.get('version', '')} is running.".replace("  ", " "),
                      " ".join(said) or "Permissions: not reported.", f"Ears: {hearing}."])


def main() -> int:
    code, out = run(sys.argv[1:])
    print(out, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""`iris` from a terminal, a script or any agent that can run a command.

    iris say "Build finished"          aloud (macOS voice) with her lips moving; --bubble for her speech bubble only
    iris notice "tests failed"         a glance and a small "!", no words
    iris react giggle                  one of her animations (`iris animations` lists them)
    iris come [cursor|other_screen]    she comes over
    iris listen [seconds]              prints what's said to her by name next (up to 25 s), or nothing

Exit status: 0 done, 1 Iris said no (the reason is printed), 2 Iris isn't reachable, 64 usage.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import iris_mcp as m  # noqa: E402

USAGE = __doc__.split("\n\n")[1]


def run(argv: list[str]) -> tuple[int, str]:
    if not argv:
        return 64, USAGE
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "say" and rest:
            bubble = "--bubble" in rest
            text = " ".join(a for a in rest if a != "--bubble")
            out = m.t_say({"text": text, "speak": not bubble})
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
        if cmd == "listen":
            out = m.t_listen({"seconds": float(rest[0]) if rest else 20})
            return 0, out
    except m.IrisUnreachable as e:
        return 2, str(e)
    except ValueError:
        return 64, USAGE
    return 64, USAGE


def main() -> int:
    code, out = run(sys.argv[1:])
    print(out, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    raise SystemExit(main())

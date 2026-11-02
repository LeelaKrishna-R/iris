"""agents/shell_hook.zsh in a real zsh, with a fake `iris_cli.py` that records what it was asked: a long command is
said aloud by name only, a failed one says so, a short one says nothing, and on a call she only glances up."""
import shutil
import subprocess
import time
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parents[1] / "agents" / "shell_hook.zsh"
pytestmark = pytest.mark.skipif(shutil.which("zsh") is None, reason="zsh not installed")

FAKE = """import sys
from pathlib import Path
log = Path(sys.argv[0]).with_name("asked.log")
log.write_text(log.read_text() + " | ".join(sys.argv[1:]) + "\\n" if log.exists() else " | ".join(sys.argv[1:]) + "\\n")
sys.exit(0 if (sys.argv[1] == "busy" and Path(sys.argv[0]).with_name("on_call").exists()) else
         1 if sys.argv[1] == "busy" else 0)
"""


def _run(tmp_path, script, long_s="0", on_call=False):
    cli = tmp_path / "iris_cli.py"
    cli.write_text(FAKE)
    if on_call:
        (tmp_path / "on_call").write_text("")
    zsh = (f"source {HOOK}; "
           # the hooks as an interactive prompt runs them, around each command
           f"for c in {script}; do _iris_preexec \"$c\"; eval \"$c\"; _iris_precmd; done; wait")
    subprocess.run(["zsh", "-f", "-c", zsh], env={"IRIS_CLI": str(cli), "IRIS_LONG_S": long_s, "PATH": "/usr/bin:/bin"},
                   check=True, timeout=30)
    for _ in range(50):                                   # her calls run in the background
        log = tmp_path / "asked.log"
        if log.exists() and log.read_text().count("\n") >= 2:
            break
        time.sleep(0.1)
    return (tmp_path / "asked.log").read_text().splitlines() if (tmp_path / "asked.log").exists() else []


def test_a_long_command_is_said_by_its_name_only(tmp_path):
    assert _run(tmp_path, "'true --token=s3cret /private/path'") == ["busy", "say | Your true command finished."]


def test_a_failed_one_says_so(tmp_path):
    assert _run(tmp_path, "'false'") == ["busy", "say | Your false command failed."]


def test_on_a_call_she_only_glances_up(tmp_path):
    assert _run(tmp_path, "'true'", on_call=True) == ["busy", "notice | your true command finished"]


def test_a_short_command_says_nothing(tmp_path):
    assert _run(tmp_path, "'true'", long_s="30") == []

"""agents/shell_hook.bash in a real interactive bash (macOS ships 3.2), with a fake `iris_cli.py` that records what
it was asked: the prompt hook says a long command by its name only, a failed one says so, a short one says nothing,
on a call she only glances up, and the line that sources the hook is never itself reported."""
import shutil
import subprocess
import time
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parents[1] / "agents" / "shell_hook.bash"
BASH = shutil.which("bash")
pytestmark = pytest.mark.skipif(BASH is None, reason="bash not installed")

FAKE = """import sys
from pathlib import Path
log = Path(sys.argv[0]).with_name("asked.log")
log.write_text((log.read_text() if log.exists() else "") + " | ".join(sys.argv[1:]) + "\\n")
sys.exit(0 if (sys.argv[1] == "busy" and Path(sys.argv[0]).with_name("on_call").exists()) else
         1 if sys.argv[1] == "busy" else 0)
"""


def _run(tmp_path, lines, long_s="0", on_call=False, want=2):
    cli = tmp_path / "iris_cli.py"
    cli.write_text(FAKE)
    if on_call:
        (tmp_path / "on_call").write_text("")
    script = "\n".join([f"source {HOOK}", *lines, "exit"]) + "\n"
    subprocess.run([BASH, "--norc", "--noprofile", "-i"], input=script, text=True, capture_output=True, timeout=30,
                   env={"IRIS_CLI": str(cli), "IRIS_LONG_S": long_s, "PATH": "/usr/bin:/bin", "HOME": str(tmp_path),
                        "PS1": "$ "})
    log = tmp_path / "asked.log"
    for _ in range(50):                                   # her calls run in the background
        if log.exists() and log.read_text().count("\n") >= want:
            break
        time.sleep(0.1)
    time.sleep(0.3)
    return sorted(log.read_text().splitlines()) if log.exists() else []


def test_a_long_command_is_said_by_its_name_only(tmp_path):
    assert _run(tmp_path, ["true --token=s3cret /private/path"]) == ["busy", "say | Your true command finished."]


def test_a_failed_one_says_so(tmp_path):
    assert _run(tmp_path, ["false"]) == ["busy", "say | Your false command failed."]


def test_on_a_call_she_only_glances_up(tmp_path):
    assert _run(tmp_path, ["true"], on_call=True) == ["busy", "notice | your true command finished"]


def test_a_short_command_says_nothing(tmp_path):
    assert _run(tmp_path, ["true"], long_s="30", want=1) == []


def test_a_line_of_commands_is_named_by_its_first(tmp_path):
    assert _run(tmp_path, ["ls /nonexistent-dir 2>/dev/null; true"]) == ["busy", "say | Your ls command finished."]

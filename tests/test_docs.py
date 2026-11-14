"""The README keeps up with the code: every MCP tool the server offers is in its tool table (and nothing that isn't),
and every agent script is named in it. `iris_busy` shipped without a row."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = (ROOT / "README.md").read_text(encoding="utf-8")


def test_the_mcp_tool_table_lists_every_tool():
    sys.path.insert(0, str(ROOT / "agents"))
    import iris_mcp
    offered = set(iris_mcp.TOOLS) | {"iris_screen"}          # iris_screen only with IRIS_MCP_SCREEN=1, but documented
    table = set(re.findall(r"^\| `(iris_[a-z_]+)` \|", README, re.MULTILINE))
    assert table == offered, (sorted(offered - table), sorted(table - offered))


def test_every_agent_script_is_named():
    scripts = [p.name for p in (ROOT / "agents").iterdir() if p.suffix in (".py", ".zsh")]
    assert scripts
    missing = [s for s in scripts if s not in README]
    assert not missing, missing


def _cli_commands() -> set[str]:
    """The commands the iris CLI takes, from its own usage text (help aside)."""
    sys.path.insert(0, str(ROOT / "agents"))
    import iris_cli
    return {m for m in re.findall(r"^\s+iris ([a-z]+)", iris_cli.USAGE, re.MULTILINE)} - {"help"}


def test_the_readme_names_every_cli_command():
    row = next(ln for ln in README.splitlines() if "**`iris` CLI**" in ln)
    missing = sorted(c for c in _cli_commands() if f"iris {c}" not in row)
    assert not missing, missing


def test_the_api_doc_shows_every_cli_command():
    api = (ROOT / "docs" / "API.md").read_text(encoding="utf-8")
    missing = sorted(c for c in _cli_commands() if f"iris_cli.py {c}" not in api)
    assert not missing, missing

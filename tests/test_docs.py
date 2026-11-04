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

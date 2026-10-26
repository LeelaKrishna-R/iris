# Iris

A desktop companion for your Mac that any AI agent can bring to life.

Iris lives on your screen as a small animated character. She walks, sits beside your windows, reacts when
you play with her, and naps when you step away. Hook her up to an AI agent (Claude Code, Codex, Cursor,
OpenClaw, or your own) and she becomes its face: she speaks its replies, glances up when a task finishes,
and waves when it needs you.

> Status: early. This repository is built in the open, one shipped piece at a time. What is here works;
> what isn't yet is listed under **Roadmap**, never described as done.

## How agents talk to her

Iris runs a small local API on `127.0.0.1:7791`. Only your macOS user can use it: every request is
signed with a key Iris writes to `~/Library/Application Support/Iris/link.key` (mode 0600) on first run.
Agents connect in one of three ways:

| Way | For | Status |
|---|---|---|
| **MCP server** (`agents/iris_mcp.py`) | Claude Code, Codex, Cursor and any MCP client | shipped |
| **Claude Code hook** (`agents/claude_code_hook.py`): she glances up when Claude finishes, comes over when it needs you | Claude Code | shipped |
| **Hooks for other agents** (Codex, Cursor) | coding agents | planned |
| **HTTP API + `iris` CLI** | custom agents, scripts | planned |

### MCP tools

| Tool | What she does |
|---|---|
| `iris_say` | Says a line aloud with her lips moving (macOS voice), or in her speech bubble |
| `iris_react` | Plays one of her animations (wave, hop, think …) |
| `iris_animations` | Lists her animations |
| `iris_notice` | Glances up at something that just happened, with a small "!" and no words |
| `iris_listen` | Waits for what you say to her by name ("Iris, …") or type in her Ask box, so an agent can hold a spoken conversation through her |
| `iris_come` | Comes to your pointer, or to your other screen |
| `iris_screen` | What's on your screens (front app, window, text). **Off unless you set `IRIS_MCP_SCREEN=1`.** |

Iris can't click, type or press keys through any of these. Her hands are left out of the agent
interface on purpose.

```sh
# Claude Code
claude mcp add iris -- python3 /path/to/iris/agents/iris_mcp.py
```

The server is one Python file with no dependencies beyond the standard library.

## Roadmap

1. **MCP server** for any agent: shipped (`agents/iris_mcp.py`, tests in `tests/`).
2. **The Iris app itself** (`app/`, in progress: builds, wake words and agent name are settings), neutral and installable: her body, animations and senses, with no
   assumptions about who you are. Your name, her wake word and her personality are your settings.
3. **Agent hooks**: Claude Code shipped (`agents/claude_code_hook.py`); Codex and Cursor next.
4. **HTTP API docs + `iris` CLI** for custom agents.
5. **First-run setup** that explains each macOS permission (screen recording, microphone,
   accessibility), and works with any of them refused.

## Requirements

macOS 14 or later. The MCP server needs Python 3.9+.

## License

To be decided before the first public release.

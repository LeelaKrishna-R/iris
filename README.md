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
| **Codex notify** (`agents/codex_notify.py`): she glances up when Codex finishes a turn | OpenAI Codex CLI | shipped |
| **Cursor hook** (`agents/cursor_hook.py`): she glances up when Cursor's agent finishes (or stops on an error) | Cursor | shipped |
| **`iris` CLI** (`agents/iris_cli.py`): `iris say …`, `iris notice …`, `iris react wave`, `iris listen` | scripts, custom agents | shipped |
| **HTTP API** (`docs/API.md`): every endpoint, signing, and why her hands stay out of agents | custom agents | documented |

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
3. **Agent hooks**: Claude Code, Codex and Cursor shipped (`agents/claude_code_hook.py`, `agents/codex_notify.py`, `agents/cursor_hook.py`).
4. **`iris` CLI** and **HTTP API docs** (`docs/API.md`): shipped.
5. **First-run welcome** (shipped: explains each permission and opens its System Settings pane; "Welcome…" in her menu shows it again). Next: fallbacks tested with each permission refused (screen recording, microphone,
   accessibility), and works with any of them refused.

## Install (from source)

```sh
git clone <this repo> iris && cd iris/app
./build.sh --launch          # builds, signs, installs to ~/Applications/Iris.app and starts her
```

macOS asks for three permissions, each optional; she does less without each one:

| Permission | What she uses it for | Without it |
|---|---|---|
| Screen Recording | reacting to what's on your screens; `iris_screen` if you allow agents | she can't see your screens |
| Microphone + Speech Recognition | hearing her name ("Iris, …") so an agent can answer you out loud | she can't hear you; her Ask box (⌃⌥Space) still works |
| Accessibility | knowing where your typing goes | she knows less about what you're doing |

Settings (all optional):

```sh
defaults write app.iris.companion agentName "Claude"     # who she speaks for, in her menu
defaults write app.iris.companion wakeWords -array iris  # the names that wake her
```

## Where she came from

Iris began as the desktop companion of Friday, one person's own assistant, and grew up on his Mac.
This repository is her own home now. Her code still carries notes from those days, written about "him",
and they'll be tidied as she ships here.

## Requirements

macOS 14 or later. The MCP server needs Python 3.9+.

## License

To be decided before the first public release.

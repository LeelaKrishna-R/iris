# Iris's local API

For agents that don't speak MCP, or that want more than the MCP tools give. Iris listens on
`http://127.0.0.1:7791` (this Mac only). Every request carries JSON (or none, for `GET`) and is signed.

## Signing

The key is the contents of `~/Library/Application Support/Iris/link.key`. Iris writes it, mode 0600, the first
time she runs. Send these headers on every request:

| Header | Value |
|---|---|
| `X-Iris-Ts` | unix seconds, now |
| `X-Iris-Nonce` | a random hex string, new each request |
| `X-Iris-Sig2` | hex HMAC-SHA256(key, `"{ts}.{nonce}.{METHOD} {path}."` + body bytes) |
| `Content-Type` | `application/json` |

`agents/iris_mcp.py` (`call`) is a complete client in about thirty lines of standard-library Python.

## Speaking and showing

| Request | Body | What she does |
|---|---|---|
| `POST /mouth/show` | `{"text": str, "seconds": number}` | Shows `text` in her speech bubble (default 6 s) |
| `POST /mouth/play` | `{"b64": base64 audio, "text": str}` | Speaks the audio with her lips moving; replies `{"seconds": …}`, or 409 if she was interrupted |

## Body and mood

| Request | Body | What she does |
|---|---|---|
| `GET /iris/catalog` | none | Her animations: `{"animations": [{"id", "when", "rig"}]}` |
| `POST /iris/act` | `{"id": str, "seconds": number}` | Plays animation `id`; 400 `no_such_animation` if she has none by that name |
| `POST /iris/notice` | `{"title": str}` | Glances up at where notifications appear, with a small "!" when you aren't busy |
| `POST /iris/come` | `{"to": "cursor" \| "other_screen"}` | Comes to the pointer or the other screen |
| `POST /iris/hold` | `{"seconds": ≤60, "talk": bool, "pose": "sit" \| "work" \| "wave" \| "sleep" \| "carry"}` | Holds still in a pose |
| `POST /iris/mood` | `{"event": "praise" \| "shoo"}` | Pleased, or steps away |
| `POST /iris/mind` | `{"want", "strength", "mood", "say", "face"}` | Sets what she wants and feels for a while (advanced) |
| `GET /iris/snapshot` | none | A PNG of how she looks right now (base64) and her state |
| `GET /health` | none | Version, which macOS permissions she has, her ears' and body's state |

## Approvals

| Request | Body | What it does |
|---|---|---|
| `POST /iris/ask` | `{"id": str, "text": str, "title": str, "until": unix seconds}` | Shows a card beside her with `text`, Allow and Deny, until `until` (10 minutes by default, an hour at most). One card at a time; a new ask replaces the old one |
| `GET /iris/decisions` | none | Clicks not yet confirmed: `{"decisions": [{"id", "choice": "approve" \| "reject"}], "showing": id}`. A click stays until you confirm it (or for 10 minutes), so a slow read can't lose it and another agent's read can't take yours |
| `POST /iris/decisions_ack` | `{"ids": [str]}` | Confirms the clicks you acted on; only those leave the list |
| `POST /iris/ask_done` | `{"id": str}` | Closes the card when the ask was answered somewhere else or ran out |

The card is a non-activating panel: it never takes your typing, and Allow has no key equivalent, so only a
click answers it. Iris records the click and does nothing else; your agent acts on it. `iris_ask` in
`agents/iris_mcp.py` does all of it for you, confirming only its own card's click.

## Senses

| Request | Body | What it gives |
|---|---|---|
| `POST /ears/next` | `{"timeout": ≤25}` | The next thing said to her by name, or typed into her Ask box: `{"heard": {"text", "typed", "at"}}`, or `{"heard": null}` |
| `POST /ears/words` | `{"words": [str]}` | Names her recognizers should expect (up to 80) |
| `GET /eyes/now` | none | The front app and window, and the text she read off each display. Off while you've paused her eyes |
| `POST /iris/senses` | `{"ears_off_s": n, "eyes_off_s": n}` | Turns her ears or eyes off for a while (0 turns them back on) |
| `POST /iris/usage` | `{"day": "YYYY-MM-DD"}` | Your active minutes per app that day, from her eyes |

## Hands: not for agents by default

`/hands/type`, `/hands/keys`, `/hands/click`, `/hands/press`, `/hands/move`, `/hands/scroll`, `/hands/drag`,
`/hands/media` and `/hands/quit` act on your Mac as if you did it. They need Accessibility permission, and
the MCP server and CLI deliberately don't expose them. If you wire them into an agent yourself, put your
own approval step in front.

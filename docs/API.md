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

## From a terminal: `iris`

`agents/iris_cli.py` signs for you, so a shell script, a git hook or any agent that can run a command can use her
without writing a client:

```sh
python3 agents/iris_cli.py say "Build finished"          # aloud, lips moving; --bubble for her speech bubble only
python3 agents/iris_cli.py notice "tests failed"         # a glance and a small "!", no words
python3 agents/iris_cli.py react giggle                  # one of her animations
python3 agents/iris_cli.py animations                    # lists them
python3 agents/iris_cli.py come other_screen             # cursor (default) or other_screen
python3 agents/iris_cli.py listen 10                     # prints what's said to her by name next, up to 25 s
python3 agents/iris_cli.py busy                          # exit 0 if you're on a call, 1 if not
python3 agents/iris_cli.py ask "Deploy to production?"   # Allow / Deny card; exit 0 only on Allow (--wait 120 s)
```

`ask` puts the same card beside her that MCP agents get from `iris_ask`, titled "A script asks", and waits for your
click (`--wait`, 5 to 300 seconds, 120 by default). Allow exits `0`; Deny, no answer in time (the card is closed) or
a card she couldn't show exits `1`. So `python3 agents/iris_cli.py ask "Push to main?" && git push` only pushes on
your Allow.

`busy` reads her eyes (`GET /eyes/now`): a meeting's own window anywhere on screen, or FaceTime, Zoom, Teams, Webex,
Discord, Slack, WhatsApp, Signal, Telegram or Skype while another app has the mic. Discord open for text isn't a call.
So `python3 agents/iris_cli.py busy || python3 agents/iris_cli.py say "Build finished"` stays quiet during a call.
MCP agents get the same check as `iris_busy`.

What she answered goes to stdout; a refusal or an error goes to stderr. Exit status: `0` done, `1` Iris said no
(the reason is printed: no such animation, nothing to say), `2` Iris isn't running or can't be reached, `64` the
command wasn't understood. So `make test || python3 agents/iris_cli.py notice "tests failed"` works as written.

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
| `POST /iris/decisions_ack` | `{"ids": [str]}` | Confirms the clicks you acted on; only those leave the list. Confirming the card's own click closes it: after a click the card stays, its buttons waiting, until you confirm (or 20 s pass, when the buttons come back) |
| `POST /iris/ask_done` | `{"id": str}` | Closes the card when the ask was answered somewhere else or ran out |

The card is a non-activating panel: it never takes your typing, and Allow has no key equivalent, so only a
click answers it. Iris records the click and does nothing else; your agent acts on it. `iris_ask` in
`agents/iris_mcp.py` does all of it for you, confirming only its own card's click.

## Day card

| Request | Body | What it does |
|---|---|---|
| `POST /iris/day` | `{"rows": [{"key": str, "head": str, "text": str, "off": bool, "items": [{"id": str, "text": str, "act": str}]}], "at": unix seconds}` | Shows a card beside her with up to 8 rows: a heading and its text each. A row marked `off` is drawn greyed (say why in its `text`). `items` (up to 3) put one line each with a small button labelled `act` ("Done", "Paid"); an item with no `act` or `id` is plain text. Sending again replaces the card |
| `GET /iris/day_state` | none | `{"hidden", "has", "refresh", "acts": [{"token", "id"}]}`: whether the person hid the card, whether it has rows, whether they clicked Iris since your last look (a good moment to send fresh rows; read once), and the button clicks waiting, each under its own token |
| `POST /iris/day_ack` | `{"tokens": [str]}` | Confirms the clicks you acted on; only those leave the list |

Iris only records a button click and shows it as pending; your agent does the work, says what happened
(`/mouth/show`) and sends the card again. Act on a token once: one delivered again after a lost confirm is
the same click. The card stays out of screen shares and recordings. Her menu offers Show / Hide My Day only
once an agent has sent a card.

## Senses

| Request | Body | What it gives |
|---|---|---|
| `POST /ears/next` | `{"timeout": ≤25}` | The next thing said to her by name, or typed into her Ask box: `{"heard": {"text", "typed", "at"}}`, or `{"heard": null}` |
| `POST /ears/words` | `{"words": [str]}` | Names her recognizers should expect (up to 80) |
| `GET /eyes/now` | none | The front app and window, and the text she read off each display. Off while you've paused her eyes |
| `POST /iris/senses` | `{"ears_off_s": n, "eyes_off_s": n}` | Turns her ears or eyes off for a while (0 turns them back on) |
| `POST /iris/usage` | `{"day": "YYYY-MM-DD"}` | Your active minutes per app that day, from her eyes |
| `GET /eyes/focus` | none, or `?app=<name>` | Where your keyboard focus is: `{"app", "role", "field": [x, y, w, h], "caret": [x, y, w, h], "into", "why"}`, or `{"ok": false, "reason": "no_focus"}`. With `?app=`, only `{"into", "why"}`: where that app's keystrokes would land |
| `POST /eyes/shot` | none | Screenshots every display, leaving her own window out, into `~/Pictures/Iris Screenshots`: `{"paths": [str]}`, or 500 `capture_failed` |
| `GET /iris/events` | none | What she noticed since the last read, as plain sentences (`he just came back to the Mac`, `music started playing`, `he opened "…" in Safari`); reading empties the list |

## Hands: not for agents by default

`/hands/type`, `/hands/keys`, `/hands/click`, `/hands/press`, `/hands/move`, `/hands/scroll`, `/hands/drag`,
`/hands/media` and `/hands/quit` act on your Mac as if you did it. `/hands/see` (`{"app": str, "menus": bool}`)
only looks: the buttons, fields and menus she can find in that app, `{"app", "things": [{"role", "name",
"dialog", "frame"}]}`, 404 `no_such_app`. All of them return 403 `accessibility_not_allowed` without the permission. They need Accessibility permission, and
the MCP server and CLI deliberately don't expose them. If you wire them into an agent yourself, put your
own approval step in front.

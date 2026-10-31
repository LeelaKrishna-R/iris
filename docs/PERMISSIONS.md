# What Iris does without each permission

Iris uses four macOS permissions, and her first-run welcome explains why she asks for each.
Any of them can be refused. This page says what each one is for and what she does without it, read from the code
in `app/Sources/Iris/`. It has not yet been checked case by case on a fresh Mac; if you see something different,
please open an issue.

| Permission | What she uses it for | Refused |
|---|---|---|
| **Accessibility** | Her hands: typing, pressing keys and clicking for your agent (`Hands`). Knowing the focused window's position and title (`World.frontWindow`, `World.frontTitle`) and what kind of field you're typing into (`Focus.into`: terminal, editor, chat). | The hands endpoints (`/hands/type`, `/hands/keys`, `/hands/click`, `/hands/see`) answer `403` with `"reason": "accessibility_not_allowed"`, so your agent is told rather than left guessing. The focused window's frame and title read as unknown, and the kind of field as `"unknown"` (`"no accessibility"`). Window positions for walking and perching still come from the window server's list, which needs no permission. |
| **Screen Recording** | Her eyes: whether your screens are changing, from tiny 64-pixel-wide streams (`Eyes`, ScreenCaptureKit) that aren't kept. And a screenshot when your agent asks for one (`/eyes/shot`, saved to `~/Pictures/Iris Screenshots`). | Her eyes don't open: `Eyes` records `"screen_recording_not_allowed"` and her eyes' status reports `"permitted": false`. She doesn't react to things moving on screen, and `/eyes/shot` answers `500` with `"reason": "capture_failed"`. Everything else about her works. |
| **Microphone** | Her ears: hearing her name. | Her ears don't start: `Ears` records `"microphone_not_allowed"`. You can still talk to her through your agent and the `iris` CLI. |
| **Speech Recognition** | Turning what she hears into words, with Apple's speech recognition (on this Mac where it can, with a second pass on Apple's server for a clearer reading). | Her ears don't start: `Ears` records `"speech_recognition_not_allowed"`. `Iris --hear file.wav` says "speech recognition not allowed for this binary" and exits with code 2. |

## Seeing what she has

`GET /health` (see [API.md](API.md)) includes a `permissions` object with `screen`, `accessibility` and
`microphone`, each `true` or `false`, so an agent can tell what she can do before asking for it.

To change one later: System Settings → Privacy & Security → the permission's pane, then restart Iris. "Welcome…" in
her menu shows the first-run explanations again.

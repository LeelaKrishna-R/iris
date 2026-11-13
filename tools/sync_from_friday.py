#!/usr/bin/env python3
"""Bring Iris's app code over from the Friday repo, made neutral the same way every time.

    python3 tools/sync_from_friday.py ~/Desktop/github/Friday/Friday/iris

Copies Sources/, Package.swift, Resources/Info.plist and Resources/catalog.json from Friday's iris/, then applies
the edits that make her nobody's in particular: her own bundle id, permission texts about "your agent", wake words
/ agent name / port / data folder from Config, no personal names in her recognizer, a first-run welcome, comments
without the first user's quotes and dated diary tags. The public-only files (Config.swift, Welcome.swift, build.sh)
are kept. Every edit must find what it expects: a sync that can't apply one stops and says which, rather than
publishing half-neutral code.
"""
from __future__ import annotations

import glob
import json
import re
import shutil
import sys
from pathlib import Path

PUBLIC_ONLY = {"Config.swift", "Welcome.swift"}
# Upstream files whose names say the upstream agent's: kept here under a neutral one (Swift doesn't care which).
RENAMED = {"BodyFriday.swift": "BodyAgent.swift"}
# Words that must never reach this repo (names, places, accounts), one per line. The list itself is private, so it
# lives beside this file, untracked; without it only Friday's own domain is checked.
PRIVATE_WORDS = Path(__file__).with_name("private_words.txt")


class SyncError(Exception):
    pass


def private_words() -> str:
    words = ["heyfriday"]
    if PRIVATE_WORDS.exists():
        words += [w.strip() for w in PRIVATE_WORDS.read_text(encoding="utf-8").splitlines() if w.strip()]
    return "|".join(re.escape(w) for w in words)


def _sub(text: str, old: str, new: str, where: str, regex: bool = False) -> str:
    if regex:
        out, n = re.subn(old, new, text, flags=re.S)
    else:
        n = text.count(old)
        out = text.replace(old, new)
    if n == 0 and new not in text:
        raise SyncError(f"{where}: expected text not found: {old[:80]!r}")
    return out


def _edit(path: Path, *edits) -> None:
    s = path.read_text(encoding="utf-8")
    for e in edits:
        s = _sub(s, *e, where=path.name) if len(e) == 2 else _sub(s, e[0], e[1], path.name, regex=e[2])
    path.write_text(s, encoding="utf-8")


def _edit_any(paths: list, *edits) -> None:
    """Like _edit, across several files (Body.swift upstream is split by job: Body*.swift and Menu.swift): each edit
    applies in every file where its text is found, and stops the sync if none has it."""
    texts = {p: p.read_text(encoding="utf-8") for p in paths if p.exists()}
    for e in edits:
        old, new, regex = (e[0], e[1], e[2] if len(e) == 3 else False)
        hit = False
        for p, t in texts.items():
            found = re.search(old, t, flags=re.S) if regex else old in t
            if found or new in t:
                texts[p] = _sub(t, old, new, p.name, regex=regex) if found else t
                hit = True
        if not hit:
            raise SyncError(f"{'/'.join(sorted(p.name for p in texts))}: expected text not found: {old[:80]!r}")
    for p, t in texts.items():
        p.write_text(t, encoding="utf-8")


# A diary date in a comment: "10-26", "9-30" (month-day), alone or as a span ("10-13..10-17", "10-10 to 10-19"),
# never a range of units ("10-15 s", "1-2 min", "8-10%").
_MD = r"(?:[1-9]|1[0-2])-[0-3]\d(?![\w%-])"
_DATE = (r"(?<![\w:.-])" + _MD + r"(?:(?:\.\.|\s+to\s+)" + _MD + r")?(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?"
         r"(?!\s*(?:s|ms|min|minutes?|seconds?|px|pt|h|hours?)\b)")
_TIME_TAG = r"^\d{1,2}:\d[\dx](?::\d{2})?:\s+"                                    # "02:5x: ..." a diary time
_OWNER = r"\bowner:?\s*(?:\"[^\"]*\"|(?=[,;)]|$))"                             # owner "mostly staring" / owner:


def _undated(s: str) -> str:
    """s without its diary dates and the first user's quotes, its punctuation tidied."""
    s = re.sub(_OWNER, "", s)
    s = re.sub(_TIME_TAG, "", s)
    s = re.sub(r"\bowner\s+(?=" + _DATE + ")", "", s)
    s = re.sub(_DATE + r"(?:\s+[a-z][\w-]*)?\s*:\s+", "", s)                 # "10-26 sim: ..."
    s = re.sub(_DATE, "", s)
    while True:                                                                 # tidy until nothing changes
        t = re.sub(r"\s{2,}", " ", s)
        t = re.sub(r"\s+([,;.:)])", r"\1", t)
        t = re.sub(r"([(])\s*[,;:]\s*", r"\1", t)
        t = re.sub(r"[,;:]\s*([,;:)])", r"\1", t)
        if t == s:
            return s
        s = t


def _paren(m: re.Match) -> str:
    inner = m.group(1)
    if not re.search(r"\bowner\b|" + _DATE, inner):
        return m.group(0)
    kept = _undated(re.sub(r'["“][^"”]*["”]', "", inner)).strip(" ,;:")      # a quote dated so is the first user's
    return f"({kept})" if re.search(r"[A-Za-z]{3}", kept) else ""


def _scrub_note(body: str) -> str:
    if not re.search(r"\bowner\b|" + _DATE, body) and not re.match(_TIME_TAG, body):
        return body
    new = re.sub(r"\s*\(([^()]*)\)", lambda m: (" " if m.group(0)[0].isspace() else "") + _paren(m)
                 if _paren(m) else "", body)                                   # "(10-26, owner: ...)"
    new = _undated(new)
    if new == body:
        return body
    return re.sub(r"^[,;:.]\s*", "", new).strip()


def upstream_name_shown(ln: str) -> bool:
    """"Friday" inside a string literal of a Swift line (comments aside): something she shows, says or journals that
    would name the upstream agent instead of Config.agentName."""
    at = _comment_at(ln)
    code = ln if at < 0 else ln[:at]
    return any(re.search(r"\bFriday\b", lit) for lit in re.findall(r'"(?:[^"\\]|\\.)*"', code))


def _comment_at(ln: str) -> int:
    """Where a trailing // comment starts in a line of Swift, outside any string; -1 if none."""
    quoted = False
    for i, ch in enumerate(ln):
        if ch == '"' and (i == 0 or ln[i - 1] != "\\"):
            quoted = not quoted
        elif not quoted and ln.startswith("//", i) and (i == 0 or ln[i - 1] in " \t"):
            return i
    return -1


def scrub_comments(text: str) -> str:
    """Comments without the first user's quotes or dated diary tags, whole-line and after code alike."""
    out = []
    for ln in text.split("\n"):
        at = _comment_at(ln)
        if at >= 0:
            m = re.match(r"(///?\s?)(.*)$", ln[at:])
            pre, body = m.groups()
            new = _scrub_note(body)
            code = ln[:at]
            if new.strip():
                ln = code + pre + new
            else:
                ln = (code + pre).rstrip() if not code.strip() else code.rstrip()
        out.append(ln)
    return "\n".join(out)


PERSON = [(r"\bhis\b", "the person's"), (r"\bhimself\b", "themselves"), (r"\bhim\b", "them"),
          (r"\bhe's\b", "they're"), (r"\bhe is\b", "they are"), (r"\bhe was\b", "they were"), (r"\bhe has\b", "they have"),
          (r"\bhe\b", "the person")]


def public_text(text: str) -> str:
    """Names that are the upstream app's, in code and comments alike: its defaults domain and screenshot folder."""
    return (text.replace("defaults write dev.heyfriday.iris", "defaults write app.iris.companion")
            .replace("Friday Screenshots", "Iris Screenshots"))


def neutral_person(text: str) -> str:
    """The catalog's 'when' notes were written about one man; say them about whoever is at the Mac."""
    for old, new in PERSON:
        text = re.sub(old, new, text)
    return text


# A Swift string literal on one line (escapes and \( ... ) interpolations without quotes inside them).
_STRING = re.compile(r'"(?:[^"\\\n]|\\\([^"()]*(?:\([^"()]*\)[^"()]*)*\)|\\.)*"')


def agent_in_strings(text: str) -> str:
    """The upstream agent's name, where she shows or logs it (inside a string literal, capitalised), as whatever agent
    this Iris runs with (Config.agentName). Lowercase keys of Core's data ("friday") and code names stay as they are."""
    return _STRING.sub(lambda m: re.sub(r"\bFriday\b", r"\\(Config.agentName)", m.group(0)), text)


def sync(src: Path, dst: Path) -> None:
    """src: Friday's iris/ folder. dst: this repo's app/ folder."""
    s_src, s_dst = src / "Sources/Iris", dst / "Sources/Iris"
    if not s_src.is_dir():
        raise SyncError(f"no Sources/Iris under {src}")
    for f in s_dst.glob("*.swift"):
        if f.name not in PUBLIC_ONLY:
            f.unlink()
    for f in s_src.glob("*.swift"):
        shutil.copy2(f, s_dst / RENAMED.get(f.name, f.name))
    shutil.copy2(src / "Package.swift", dst / "Package.swift")
    (dst / "Resources").mkdir(exist_ok=True)
    shutil.copy2(src / "Resources/Info.plist", dst / "Resources/Info.plist")
    shutil.copy2(src / "Resources/Iris.entitlements", dst / "Resources/Iris.entitlements")
    if (src / "Resources/catalog.json").exists():
        cat = json.loads((src / "Resources/catalog.json").read_text(encoding="utf-8"))
        for e in cat:
            for k in ("shows", "when"):
                if isinstance(e.get(k), str):
                    e[k] = neutral_person(e[k])
        (dst / "Resources/catalog.json").write_text(json.dumps(cat, indent=1, ensure_ascii=False), encoding="utf-8")

    _edit(dst / "Resources/Info.plist",
          ("<string>dev.heyfriday.iris</string>", "<string>app.iris.companion</string>"),
          (r"(NSMicrophoneUsageDescription</key><string>)[^<]*", r"\1Iris listens for her name, so you can talk to your AI agent out loud.", True),
          (r"(NSSpeechRecognitionUsageDescription</key><string>)[^<]*", r"\1Iris turns what you say to her into words on this Mac, so your agent can answer.", True),
          (r"(NSScreenCaptureUsageDescription</key><string>)[^<]*", r"\1Iris looks at your screens to react to what you're doing (and, if you allow it, to tell your agent).", True))
    _edit(s_dst / "HerName.swift",
          (r"static let wakeWords = \[[^\]]*\]", "static var wakeWords: [String] { Config.wakeWords }", True),
          # "Siri" heard as her name stays upstream's: someone else's "Hey Siri" is usually for Siri.
          ("for pat in [misheardName, misheardFriday, misheardIris] {",
           'for pat in [misheardName] + (wakeWords.contains("friday") ? [misheardFriday] : []) {'))
    _edit(s_dst / "Ears.swift",
          (r"static let words = \[.*?\]\n",
           'static var words: [String] {\n        let names = HerName.wakeWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }\n'
           '        return names + names.flatMap { ["hey \\\\($0)", "okay \\\\($0)"] }\n'
           '            + ["what did I miss", "remind me", "come here", "go away", "be quiet", "go to sleep", "wake up", "dance", "sit"]\n'
           '    }\n', True),
          ('        // 11-11: and "Hey Iris" as "Hey Siri"; every mishearing her name knows (HerName.misheard)\n',
           "        // every mishearing her name knows, for the wake words set (HerName.misheard)\n"))
    _edit(s_dst / "Ask.swift", ('f.placeholderString = "Ask Friday…"', 'f.placeholderString = "Ask \\(Config.agentName)…"'),
          ('f.setAccessibilityLabel("Ask Friday")', 'f.setAccessibilityLabel("Ask \\(Config.agentName)")'))
    _edit(s_dst / "Store.swift",
          ("""/// Where Iris keeps what she learns and sees: ~/Library/Application Support/Iris.
/// Friday Core runs as the same macOS user on this Mac, so it reads the link
/// key from here; nobody else can (0600).""",
           """/// Where Iris keeps what she learns and sees: ~/Library/Application Support/Iris (or Config.dataDir).
/// Agents run as the same macOS user, so they read the link key from here; nobody else can (0600)."""),
          ('let d = base.appendingPathComponent("Iris", isDirectory: true)',
           'let d = Config.dataDir ?? base.appendingPathComponent("Iris", isDirectory: true)'))
    _edit(s_dst / "ApprovalCard.swift",
          (r"/// Friday's approval, answered on the Mac.*?(?=final class ApprovalCard)",
           "/// An approval your agent asks for, answered on the Mac: what it wants to do, beside Iris, with Allow and\n"
           "/// Deny. A click is only recorded here (`decisions`); your agent collects it from /iris/decisions and acts\n"
           "/// on it once. The card never takes your typing (a non-activating panel); it goes when the ask runs out,\n"
           "/// when your agent says it was answered elsewhere (/iris/ask_done), or when you click.\n", True),
          ('"Friday asks for your approval: ', '"\\(Config.agentName) asks for your approval: '))
    _edit(s_dst / "Link.swift", ("static let port: UInt16 = 7791", "static var port: UInt16 { Config.port }"))
    _edit(s_dst / "EndOfSpeech.swift",
          (r"/// When what he said to her is over.*?(?=enum EndOfSpeech)",
           "/// When what you said to her is over (Ears.checkSilence), as rules alone so they can be checked without a\n"
           "/// microphone: 1.3 s after the last word with the mic quiet, 2.2 s at most, 1.2 s more when the last word\n"
           "/// plainly goes on (\"and\", \"to\", \"my\", \"what\" …), 2 s after her name alone. An ask that closes itself\n"
           "/// (\"… please\", \"… thanks\", \"… thank you\", \"… right now\"), two words or more, ends 0.8 s after its last\n"
           "/// word; everything else waits as long as before, so \"Can you check\" isn't cut off.\n", True))
    _edit(s_dst / "main.swift",
          ('log("iris: awake")\n', 'log("iris: awake")\n        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Welcome.showIfFirstRun() }\n'),
          (r"            //[^\n]*a Friday approval with Allow / Deny beside her[^\n]*\n[^\n]*\n",
           "            // an approval your agent asks for, with Allow / Deny beside her; the click waits in\n"
           "            // /iris/decisions for the agent, which acts on it once (agents/iris_mcp.py iris_ask)\n", True))
    body = sorted(s_dst.glob("Body*.swift")) + [s_dst / "Menu.swift"]
    _edit_any(body,
          ('String(format: "Friday\'s answer to him is taking over %.0f s", Stages.impatientAfter)',
           '"\\(Config.agentName)\'s answer is taking over \\(Int(Stages.impatientAfter)) s"'),
          ('"Friday speaking through her"', '"\\(Config.agentName) speaking through her"'),
          ('why: "waiting for Friday\'s answer to him")', 'why: "waiting for \\(Config.agentName)\'s answer")'),
          ('withTitle: "Ask Friday…  ⌃⌥Space"', 'withTitle: "Ask \\(Config.agentName)…  ⌃⌥Space"'),
          ('withTitle: "Talk to Friday  ⌃⌥⇧Space"', 'withTitle: "Talk to \\(Config.agentName)  ⌃⌥⇧Space"'),
          ('waveWhy = "Friday asked her to wave"', 'waveWhy = "\\(Config.agentName) asked her to wave"'),
          ('fallAsleep("Friday asked her to nap")', 'fallAsleep("\\(Config.agentName) asked her to nap")'),
          ('why: "Friday used his mouse through her hands")', 'why: "\\(Config.agentName) used the mouse through her hands")'),
          ('(wakeWhy.isEmpty ? "Friday asked" : wakeWhy)', '(wakeWhy.isEmpty ? "\\(Config.agentName) asked" : wakeWhy)'),
          (': "woke: Friday asked"', ': "woke: \\(Config.agentName) asked"'),
          ("/// `asked`: Core's cause when Friday asked for it", "/// `asked`: your agent's cause when it asked for it"),
          ('why: "he allowed Friday\'s request: "', 'why: "he allowed \\(Config.agentName)\'s request: "'),
          (r"    // [^\n]*his Nap \(the app's Iris panel, a 60 s hold\) lasted 7 s[^\n]*\n",
           "    // a nap asked for (the agent's 60 s hold) used to end at the first touch of the mouse. A nap he\n", True),
          (r"    // [^\n]*poses\.jsonl 00:00-01:30: [^\n]*\n    // and Code: [^\n]*\n",
           "    // switching between apps, each with its text field somewhere else, sent her \"out of his way\" every\n"
           "    // minute or two: her clear spot for one field was in the way of the next.\n", True),
          ('wakeWhy = "he asked Friday something"', 'wakeWhy = "he asked \\(Config.agentName) something"'),
          ('wakeWhy = "Friday had something to tell him"', 'wakeWhy = "\\(Config.agentName) had something to tell him"'),
          ('"Friday asked: " + asked', '"\\(Config.agentName) asked: " + asked'),
          (r"        // [^\n]*her journal said \"woke: Friday asked\" for this[^\n]*\n",
           "        // what woke her is said in her journal (without it, \"woke: <agent> asked\" was all it said)\n", True),
          ('actWhy = own ? why : asked.isEmpty ? "Friday asked for it" : "Friday: " + asked',
           'actWhy = own ? why : asked.isEmpty ? "\\(Config.agentName) asked for it" : "\\(Config.agentName): " + asked'),
          ('m.addItem(withTitle: "Quit Iris"',
           'm.addItem(withTitle: "Welcome…", action: #selector(Menu.welcome), keyEquivalent: "").target = Menu.shared\n'
           '        m.addItem(withTitle: "Quit Iris"'),
          ("@objc func ask() { body?.onAsk?() }",
           "@objc func ask() { body?.onAsk?() }\n    @objc func welcome() { Welcome.show() }"))
    # The day card upstream is filled by its own agent; here any agent can fill it (/iris/day, docs/API.md), and
    # her menu offers it only once one has, so an Iris with nothing behind it has no item that does nothing.
    _edit_any(body,
          ('        m.addItem(withTitle: DayCard.shared.hidden ? "Show My Day" : "Hide My Day", action: #selector(Menu.day),\n'
           '                  keyEquivalent: "").target = Menu.shared\n',
           '        if !DayCard.shared.rows.isEmpty {\n'
           '            m.addItem(withTitle: DayCard.shared.hidden ? "Show My Day" : "Hide My Day", action: #selector(Menu.day),\n'
           '                      keyEquivalent: "").target = Menu.shared\n'
           '        }\n'))
    _edit(s_dst / "DayCard.swift",
          (r'static let fridayApp = "[^"]*"', "static var fridayApp: String { Config.agentApp }", True),
          (r"/// His day at a glance.*?(?=final class DayCard)",
           "/// A day card beside Iris, filled by your agent: rows it sends to /iris/day (a heading and a line each, a\n"
           "/// row it couldn't read marked \"off\" and drawn greyed), with an optional button beside a line (\"Done\",\n"
           "/// \"Paid\"). A click waits under its own token in /iris/day_state until the agent confirms it acted\n"
           "/// (/iris/day_ack). The card never takes your typing and stays out of screen shares and recordings; x hides\n"
           "/// it until you pick Show My Day in her menu.\n", True))
    _edit(s_dst / "Sim.swift",
          (r"            // [^\n]*journaled \"woke: Friday asked\"[^\n]*\n",
           "            // a wake with no cause of its own, journaled as the agent's ask\n", True),
          ('(info["why"] as? String) == "woke: Friday asked"', '(info["why"] as? String) == "woke: \\(Config.agentName) asked"'))
    for f in glob.glob(str(s_dst / "*.swift")):
        p = Path(f)
        if p.name in PUBLIC_ONLY:
            continue
        p.write_text(scrub_comments(public_text(agent_in_strings(p.read_text(encoding="utf-8")))), encoding="utf-8")
    named = [f"{Path(f).name}:{i + 1}" for f in glob.glob(str(s_dst / "*.swift")) if Path(f).name not in PUBLIC_ONLY
             for i, ln in enumerate(Path(f).read_text(encoding="utf-8").split("\n")) if upstream_name_shown(ln)]
    if named:
        raise SyncError("the upstream agent's name in text she shows or logs (use Config.agentName): "
                        + ", ".join(named[:10]))
    left = [f"{Path(f).name}:{i + 1}" for f in glob.glob(str(s_dst / "*.swift"))
            for i, ln in enumerate(Path(f).read_text(encoding="utf-8").split("\n"))
            if re.search(private_words(), ln, re.I)]
    if left:
        raise SyncError("personal names left after the edits: " + ", ".join(left[:10]))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    try:
        sync(Path(sys.argv[1]).expanduser(), Path(__file__).resolve().parents[1] / "app")
    except SyncError as e:
        sys.exit(f"sync stopped: {e}")
    print("synced; now: cd app && swift build -c release")

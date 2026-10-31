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


# A diary date in a comment: "10-26", "9-30" (month-day), alone or as a span ("10-13..10-17", "10-10 to 10-19"),
# never a range of units ("10-15 s", "1-2 min", "8-10%").
_MD = r"(?:[1-9]|1[0-2])-[0-3]\d(?![\w%-])"
_DATE = (r"(?<![\w:.-])" + _MD + r"(?:(?:\.\.|\s+to\s+)" + _MD + r")?(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?"
         r"(?!\s*(?:s|ms|min|minutes?|seconds?|px|pt|h|hours?)\b)")
_OWNER = r"\bowner:?\s*(?:\"[^\"]*\"|(?=[,;)]|$))"                             # owner "mostly staring" / owner:


def _undated(s: str) -> str:
    """s without its diary dates and the first user's quotes, its punctuation tidied."""
    s = re.sub(_OWNER, "", s)
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
    if not re.search(r"\bowner\b|" + _DATE, body):
        return body
    new = re.sub(r"\s*\(([^()]*)\)", lambda m: (" " if m.group(0)[0].isspace() else "") + _paren(m)
                 if _paren(m) else "", body)                                   # "(10-26, owner: ...)"
    new = _undated(new)
    if new == body:
        return body
    return re.sub(r"^[,;:.]\s*", "", new).strip()


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


def neutral_person(text: str) -> str:
    """The catalog's 'when' notes were written about one man; say them about whoever is at the Mac."""
    for old, new in PERSON:
        text = re.sub(old, new, text)
    return text


def sync(src: Path, dst: Path) -> None:
    """src: Friday's iris/ folder. dst: this repo's app/ folder."""
    s_src, s_dst = src / "Sources/Iris", dst / "Sources/Iris"
    if not s_src.is_dir():
        raise SyncError(f"no Sources/Iris under {src}")
    for f in s_dst.glob("*.swift"):
        if f.name not in PUBLIC_ONLY:
            f.unlink()
    for f in s_src.glob("*.swift"):
        shutil.copy2(f, s_dst / f.name)
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
          ("for pat in [misheardName, misheardFriday] {",
           'for pat in [misheardName] + (wakeWords.contains("friday") ? [misheardFriday] : []) {'))
    _edit(s_dst / "Ears.swift",
          (r"static let words = \[.*?\]\n",
           'static var words: [String] {\n        let names = HerName.wakeWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }\n'
           '        return names + names.flatMap { ["hey \\\\($0)", "okay \\\\($0)"] }\n'
           '            + ["what did I miss", "remind me", "come here", "go away", "be quiet", "go to sleep", "wake up", "dance", "sit"]\n'
           '    }\n', True),
          ("low.range(of: HerName.misheardFriday, options: .regularExpression) != nil",
           '(HerName.wakeWords.contains("friday") ? low.range(of: HerName.misheardFriday, options: .regularExpression) : nil) != nil'))
    _edit(s_dst / "Ask.swift", ('f.placeholderString = "Ask Friday…"', 'f.placeholderString = "Ask \\(Config.agentName)…"'))
    _edit(s_dst / "Eyes.swift", ('"Pictures/Friday Screenshots"', '"Pictures/Iris Screenshots"'))
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
           "/// when your agent says it was answered elsewhere (/iris/ask_done), or when you click.\n", True))
    _edit(s_dst / "Link.swift", ("static let port: UInt16 = 7791", "static var port: UInt16 { Config.port }"))
    _edit(s_dst / "main.swift",
          ('log("iris: awake")\n', 'log("iris: awake")\n        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Welcome.showIfFirstRun() }\n'),
          (r"            //[^\n]*a Friday approval with Allow / Deny beside her[^\n]*\n[^\n]*\n",
           "            // an approval your agent asks for, with Allow / Deny beside her; the click waits in\n"
           "            // /iris/decisions for the agent, which acts on it once (agents/iris_mcp.py iris_ask)\n", True))
    body = s_dst / "Body.swift"
    _edit(body,
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
          ('actWhy = own ? why : asked.isEmpty ? "Friday asked for it" : "Friday: " + asked',
           'actWhy = own ? why : asked.isEmpty ? "\\(Config.agentName) asked for it" : "\\(Config.agentName): " + asked'),
          ('m.addItem(withTitle: "Quit Iris"',
           'm.addItem(withTitle: "Welcome…", action: #selector(Menu.welcome), keyEquivalent: "").target = Menu.shared\n'
           '        m.addItem(withTitle: "Quit Iris"'),
          ("@objc func ask() { body?.onAsk?() }",
           "@objc func ask() { body?.onAsk?() }\n    @objc func welcome() { Welcome.show() }"))
    for f in glob.glob(str(s_dst / "*.swift")):
        p = Path(f)
        if p.name in PUBLIC_ONLY:
            continue
        t = p.read_text(encoding="utf-8").replace("defaults write dev.heyfriday.iris", "defaults write app.iris.companion")
        p.write_text(scrub_comments(t), encoding="utf-8")
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

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


class SyncError(Exception):
    pass


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


def scrub_comments(text: str) -> str:
    out = []
    for ln in text.split("\n"):
        m = re.match(r"^(\s*///?\s?)(.*)$", ln)
        if m and ln.lstrip().startswith("//"):
            pre, body = m.groups()
            new = re.sub(r"\b\d{1,2}-\d{2}(?:\s+[\w:]+)?\s*\(owner[^)]*\)\s*:?\s*", "", body)
            new = re.sub(r"\(owner[^)]*\)\s*", "", new)
            new = re.sub(r"\bowner\s+\d{1,2}-\d{2}:?\s*", "", new)
            new = re.sub(r"^\d{1,2}-\d{2}(?:\s+[a-z][\w-]*)?\s*:\s*", "", new)
            new = re.sub(r"\s*\(\d{1,2}-\d{2}[^)]*\)", "", new)
            ln = pre + new if new.strip() else pre.rstrip()
        out.append(ln)
    return "\n".join(out)


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
                    e[k] = re.sub(r"\bhis\b", "the person's", e[k])
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
    _edit(s_dst / "Link.swift", ("static let port: UInt16 = 7791", "static var port: UInt16 { Config.port }"))
    _edit(s_dst / "main.swift",
          ('log("iris: awake")\n', 'log("iris: awake")\n        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Welcome.showIfFirstRun() }\n'))
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
          ('actWhy = own ? why : "Friday asked for it"', 'actWhy = own ? why : "\\(Config.agentName) asked for it"'),
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
            if re.search(r"heyfriday", ln, re.I)]
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

"""Her saved files are readable by you alone (0600), as Store's own comment promises.

Compiles the real app/Sources/Iris/Store.swift with a tiny driver and points it at a temp folder,
so nothing touches your real ~/Library/Application Support/Iris.
"""
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

APP = Path(__file__).resolve().parent.parent / "app" / "Sources" / "Iris"

DRIVER = """
import Foundation
enum Config { static var dataDir: URL? = URL(fileURLWithPath: CommandLine.arguments[1]) }
struct Box: Codable { let n: Int }
Store.save(Box(n: 1), "a.json")                      // a first save
FileManager.default.createFile(atPath: Store.url("b.json").path, contents: Data("{}".utf8),
                               attributes: [.posixPermissions: 0o644])
Store.save(Box(n: 2), "b.json")                      // over a file someone left readable
print(Store.load(Box.self, "b.json")!.n)
"""


@pytest.mark.skipif(shutil.which("swiftc") is None, reason="needs swiftc (macOS)")
def test_saved_files_are_yours_alone(tmp_path):
    src = (APP / "Store.swift").read_text()
    (tmp_path / "Store.swift").write_text(src)
    (tmp_path / "main.swift").write_text(DRIVER)
    exe = tmp_path / "drive"
    subprocess.run(["swiftc", "-o", str(exe), str(tmp_path / "Store.swift"), str(tmp_path / "main.swift")],
                   check=True, capture_output=True)
    data = tmp_path / "data"
    out = subprocess.run([str(exe), str(data)], check=True, capture_output=True, text=True).stdout
    assert out.strip() == "2"
    for name in ("a.json", "b.json"):
        assert stat.S_IMODE(os.stat(data / name).st_mode) == 0o600, name
    assert not (data / "b.json.tmp").exists()
    assert stat.S_IMODE(os.stat(data).st_mode) == 0o700

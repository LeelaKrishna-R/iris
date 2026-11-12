"""She stays out of screen shares and recordings unless you switch her in from her menu, for that launch only; the
day card (your bills, names) never shows in a share."""
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris"


def read(name):
    return (SRC / name).read_text(encoding="utf-8")


def test_menu_switch_is_off_at_launch_and_not_saved():
    menu = read("Menu.swift")
    assert "private(set) var inScreenShares = false" in menu
    assert "inScreenShares ? .readOnly : .none" in menu
    assert "Store.save" not in menu[menu.index("func screenShares"):menu.index("func screenShares") + 400]
    assert '"Show Me in Screen Shares"' in read("BodyAgent.swift")


def test_body_and_bubble_follow_the_switch():
    body = read("Body.swift")
    assert "w.sharingType = Menu.shared.sharing" in body and "bubble?.share(Menu.shared.sharing)" in body
    assert "func share(_ type: NSWindow.SharingType)" in read("Bubble.swift")


def test_day_card_never_shared():
    card = read("DayCard.swift")
    assert "sharingType = .none" in card and "Menu.shared.sharing" not in card

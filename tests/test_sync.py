"""The sync's comment scrubber: no first-user quotes or diary dates reach this repo, and nothing else changes."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from sync_from_friday import public_text, scrub_comments, upstream_name_shown  # noqa: E402


def test_trailing_comment_notes_go():
    got = scrub_comments('    static let quietSitFor: Double = 60      // 10-26 (owner: "mostly staring and sitting"): was 300; '
                         'a long sit is her book, not a stare')
    assert got == "    static let quietSitFor: Double = 60      // was 300; a long sit is her book, not a stare"


def test_parenthesised_dates_and_quotes_go():
    got = scrub_comments("    static let settleAfter: Double = 60        // s standing near them with no walk, then she sits "
                         '(10-24: 180; 10-26: 60, owner "mostly staring")')
    assert got == "    static let settleAfter: Double = 60        // s standing near them with no walk, then she sits"


def test_a_leading_date_goes():
    assert scrub_comments("        // 10-26 sim 27: active was a touch in the last 30 s") == \
        "        // sim 27: active was a touch in the last 30 s"
    assert scrub_comments("    /// 10-26 poses.jsonl 09:03-09:08 showed it") == "    /// poses.jsonl 09:03-09:08 showed it"


def test_a_paren_open_to_the_next_line_keeps_its_paren():
    assert scrub_comments("    /// its bundle id, or for a helper with none (10-14: Safari plays") == \
        "    /// its bundle id, or for a helper with none (Safari plays"
    assert scrub_comments("        // None seen since she started (10-20 04:06: she restarted under a dialog,") == \
        "        // None seen since she started (she restarted under a dialog,"


def test_a_date_range_goes_whole():
    assert scrub_comments("    // in her eyes logs 10-13..10-17, 270 of 309") == "    // in her eyes logs, 270 of 309"


def test_ranges_times_urls_and_code_stay():
    for ln in ["    // every 10-15 s, 1-2 min apart, at 09:03-09:08",
               "    //   accurate rev 2:      CER  8-10%, 68-76 lines exact",
               '    let u = "http://127.0.0.1:7777/iris" // the link',
               '    let s = "10-26 (owner)"',
               "    let x = a - 10-26"]:
        assert scrub_comments(ln) == ln, ln


def test_a_comment_of_only_a_date_leaves_the_code():
    assert scrub_comments("    nod()   // (10-24)") == "    nod()"


def test_a_dated_quote_goes_with_its_date():
    assert scrub_comments('    // his hand on her (10-14, "i need her super responsive"): each touch plays') == \
        "    // his hand on her: each touch plays"
    assert scrub_comments('            // 10-22 (owner 10-21: "random reactions"): every 60-150 s by dice') == \
        "            // every 60-150 s by dice"


def test_an_open_paren_loses_its_date_and_quote_cleanly():
    assert scrub_comments('/// an approval, answered on the Mac (10-26, owner: "Approvals on the Mac", decisions') == \
        "/// an approval, answered on the Mac (decisions"


def test_the_screenshot_folder_is_irises_in_comments_too():
    src = ('    /// ~/Pictures/Friday Screenshots (not a folder macOS guards)\n'
           '            // "take a screenshot": saved to Pictures/Friday Screenshots\n'
           '        let dir = "Pictures/Friday Screenshots"\n'
           '    // defaults write dev.heyfriday.iris eyesOff -bool YES\n')
    out = public_text(src)
    assert "Friday Screenshots" not in out and out.count("Iris Screenshots") == 3
    assert "defaults write app.iris.companion" in out


def test_the_upstream_name_in_a_string_she_shows_is_caught():
    assert upstream_name_shown('        perform("bow", seconds: 2.4, own: true, why: "he allowed Friday\'s request: ")')
    assert upstream_name_shown('        wakeWhy = "Friday had something to tell him"')


def test_the_name_in_a_comment_or_through_config_is_fine():
    assert not upstream_name_shown('        x = 1   // "woke: Friday asked" was all it said')
    assert not upstream_name_shown('        wakeWhy = "\\(Config.agentName) had something to tell him"')
    assert not upstream_name_shown('    /// Friday\'s answer to him taking a while')
    assert not upstream_name_shown('        let day = "Fridays"')


# ── upstream's Body.swift is split by job; a rule finds its text in whichever file holds it ──────────────────────
def test_an_edit_applies_in_whichever_split_file_has_it(tmp_path):
    from sync_from_friday import _edit_any
    a, b = tmp_path / "BodyGaze.swift", tmp_path / "Menu.swift"
    a.write_text('let s = "Friday speaking through her"\n')
    b.write_text('m.addItem(withTitle: "Quit Iris")\n')
    _edit_any([a, b], ('"Friday speaking through her"', '"\\(Config.agentName) speaking through her"'),
              ('m.addItem(withTitle: "Quit Iris")', 'm.addItem(withTitle: "Welcome…")\nm.addItem(withTitle: "Quit Iris")'))
    assert a.read_text() == 'let s = "\\(Config.agentName) speaking through her"\n'
    assert b.read_text().startswith('m.addItem(withTitle: "Welcome…")')


def test_an_edit_no_file_has_stops_the_sync(tmp_path):
    import pytest
    from sync_from_friday import SyncError, _edit_any
    a = tmp_path / "BodyGaze.swift"
    a.write_text("let x = 1\n")
    with pytest.raises(SyncError):
        _edit_any([a], ("not there", "anything"))


def test_the_agent_name_in_her_words_is_the_configured_one():
    from sync_from_friday import agent_in_strings
    assert agent_in_strings('log("menu: asked Friday for \\(what)")') == 'log("menu: asked \\(Config.agentName) for \\(what)")'
    # Core's data keys and code names stay as they are
    assert agent_in_strings('let x = ["friday": "Friday\'s voice"]') == 'let x = ["friday": "\\(Config.agentName)\'s voice"]'
    assert agent_in_strings("guard let t = lastFridayContact else { return nil }") == \
        "guard let t = lastFridayContact else { return nil }"


def test_her_sentences_are_about_whoever_is_at_the_mac():
    from sync_from_friday import person_in_strings
    assert person_in_strings('notice("he hovered his cursor over you")') == \
        'notice("the person hovered their cursor over you")'
    assert person_in_strings('events.append("he just came back to the Mac")') == \
        'events.append("the person just came back to the Mac")'
    assert person_in_strings('why: "he\'s carrying her"') == 'why: "they\'re carrying her"'
    assert person_in_strings('String(format: "waiting for him: away %.0f min", hisIdle / 60)') == \
        'String(format: "waiting for them: away %.0f min", hisIdle / 60)'


def test_one_word_keys_and_code_stay():
    from sync_from_friday import person_in_strings
    line = 'if now < talkUntil { lookAtHim(); gazeMode = "him"; return }  // he looks'
    assert person_in_strings(line) == line


def test_a_leading_time_tag_goes():
    assert scrub_comments("        // 02:5x: after a power cut she crashed at launch") == \
        "        // after a power cut she crashed at launch"
    assert scrub_comments("        // 14:05: the tap failed") == "        // the tap failed"
    assert scrub_comments("    let t = 3   // waits 02:30 at most") == "    let t = 3   // waits 02:30 at most"


def test_her_comments_are_about_whoever_is_at_the_mac_too():
    from sync_from_friday import person_in_comments
    assert person_in_comments('    /// whether he switched her into shares (Menu)') == \
        '    /// whether the person switched her into shares (Menu)'
    assert person_in_comments('let w = hisIdle   // his pointer resting on her') == \
        'let w = hisIdle   // their pointer resting on her'
    assert person_in_comments('gazeMode = "him"') == 'gazeMode = "him"'           # code is not a comment

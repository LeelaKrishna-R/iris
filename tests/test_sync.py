"""The sync's comment scrubber: no first-user quotes or diary dates reach this repo, and nothing else changes."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from sync_from_friday import scrub_comments  # noqa: E402


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

"""Her ears never install a tap they can't have. With no microphone attached the input node can report a sample
rate and no channels, and installTap on that raises an Objective-C exception Swift can't catch: she crashed at
launch and launchd restarted her every few seconds. Now that's "no_microphone" and she retries, alive."""
from pathlib import Path

EARS = (Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris" / "Ears.swift").read_text(encoding="utf-8")


def test_no_tap_without_input_channels():
    begin = EARS[EARS.index("private func begin()"):]
    begin = begin[:begin.index("input.installTap(")]
    assert "fmt.channelCount > 0" in begin, "a format with no channels must not reach installTap"
    assert "hw.channelCount > 0" in begin and "hw.sampleRate == fmt.sampleRate" in begin, \
        "the tap's format must match the hardware's"
    assert 'problem = "no_microphone"; retry(); return' in begin

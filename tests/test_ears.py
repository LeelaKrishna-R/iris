"""Her ears never install a tap they can't have. With no microphone attached the input node can report a sample
rate and no channels, and installTap on that raises an Objective-C exception Swift can't catch: she crashed at
launch and launchd restarted her every few seconds. Now that's "no_microphone" and she retries, alive."""
from pathlib import Path

EARS = (Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris" / "Ears.swift").read_text(encoding="utf-8")


def test_no_tap_without_input_channels():
    begin = EARS[EARS.index("private func begin()"):]
    begin = begin[:begin.index("input.installTap(")]
    assert "fmt.channelCount > 0" in begin, "a format with no channels must not reach installTap"
    # the tap takes the hardware's own input format, so its rate matches by construction (a 96 kHz USB mic was
    # refused when the engine's output format disagreed on the rate)
    assert "let fmt = input.inputFormat(forBus: 0)" in begin, "the tap must use the hardware's input format"
    assert "outputFormat(forBus" not in begin
    assert 'problem = "no_microphone"; watchMic(); retry(); return' in begin


def test_a_hung_microphone_never_freezes_her():
    # the mic is asked first on a background thread by a throwaway engine, held alive while it's read
    probe = EARS[EARS.index("private func whenMicAnswers"):]
    probe = probe[:probe.index("\n    }\n")]
    assert "DispatchQueue.global" in probe and "withExtendedLifetime(probe)" in probe
    assert 'problem = "microphone_not_answering"' in probe

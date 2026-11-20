"""Her ears never install a tap they can't have. With no microphone attached the input node can report a sample
rate and no channels, and installTap on that raises an Objective-C exception Swift can't catch: she crashed at
launch and launchd restarted her every few seconds. Now that's "no_microphone" and she retries, alive."""
from pathlib import Path

EARS = (Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris" / "Ears.swift").read_text(encoding="utf-8")


def test_no_tap_without_input_channels():
    begin = EARS[EARS.index("private func begin()"):]
    begin = begin[:begin.index("input.installTap(")]
    assert "guard fmt.sampleRate > 0, fmt.channelCount > 0 else" in begin, "a format with no channels must not reach installTap"
    # the tap takes the hardware's own input format, so its rate matches by construction (a 96 kHz USB mic was
    # refused when the engine's output format disagreed on the rate); the output format only with voice processing
    # on, and only one her ears can read
    assert "let fmt = processed ? input.outputFormat(forBus: 0) : input.inputFormat(forBus: 0)" in begin
    assert "processed = SharedAudio.usable(input.outputFormat(forBus: 0))" in begin
    assert 'problem = "no_microphone"; watchMic(); retry(); return' in begin


def test_voice_processing_is_off_unless_turned_on_and_falls_back_to_the_plain_microphone():
    shared = (Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris" / "SharedAudio.swift").read_text(encoding="utf-8")
    assert 'static let wantedKey = "voiceProcessing"' in shared
    assert "UserDefaults.standard.object(forKey: wantedKey) as? Bool ?? false" in shared
    begin = EARS[EARS.index("private func begin()"):]
    begin = begin[:begin.index("input.installTap(")]
    # asked for, not failed before, and a microphone present; anything that goes wrong is the plain microphone
    assert "if SharedAudio.wanted, !SharedAudio.failedWithProcessing, input.inputFormat(forBus: 0).channelCount > 0 {" in begin
    assert begin.count("try? input.setVoiceProcessingEnabled(false)") >= 3
    assert "SharedAudio.processing = processed" in begin


def test_a_hung_microphone_never_freezes_her():
    # the mic is asked first on a background thread by a throwaway engine, held alive while it's read
    probe = EARS[EARS.index("private func whenMicAnswers"):]
    probe = probe[:probe.index("\n    }\n")]
    assert "DispatchQueue.global" in probe and "withExtendedLifetime(probe)" in probe
    assert 'problem = "microphone_not_answering"' in probe


def test_the_recognizer_gets_mono_when_the_microphone_has_more_than_two_channels():
    # with voice processing on the microphone arrives as four identical channels; her gate reads the first, and the
    # recognizer was being handed all four
    shared = (Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris" / "SharedAudio.swift").read_text(encoding="utf-8")
    assert "static func forRecognizer(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer?" in shared
    assert "guard buf.format.channelCount > 2" in shared
    assert "let heard = SharedAudio.forRecognizer(buf) ?? buf" in EARS and "req?.append(heard)" in EARS


def test_echo_cancelling_is_a_menu_switch_that_restarts_her_ears():
    src = Path(__file__).resolve().parents[1] / "app" / "Sources" / "Iris"
    menu = (src / "Menu.swift").read_text(encoding="utf-8")
    assert "UserDefaults.standard.set(!SharedAudio.wanted, forKey: SharedAudio.wantedKey)" in menu
    assert '"Echo Cancelling (Trial)"' in (src / "BodyAgent.swift").read_text(encoding="utf-8")
    assert "func voiceProcessingChanged()" in EARS

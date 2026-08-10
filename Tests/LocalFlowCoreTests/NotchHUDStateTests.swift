import LocalFlowCore
import Foundation

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition { passed += 1 }
    else { failed += 1; fputs("FAIL: \(message) (\(file):\(line))\n", stderr) }
}

let hidden = NotchHUDState.hidden
assert(hidden.isVisible == false, "idle HUD is hidden")

let listening = NotchHUDState.listening
assert(listening.isVisible, "listening HUD is visible")
assert(listening.tone == .listening, "listening uses listening tone")
assert(listening.label == "Listening", "listening label is concise")
assert(listening.autoDismissAfter == nil, "listening stays visible")

let processing = NotchHUDState.processing("Cleaning up")
assert(processing.tone == .processing, "processing uses amber tone")
assert(processing.label == "Cleaning up", "processing keeps safe label")

let success = NotchHUDState.success(milliseconds: 812.4)
assert(success.tone == .success, "success uses success tone")
assert(success.label == "Pasted · 812 ms", "success rounds latency")
assert(success.autoDismissAfter == .milliseconds(700), "success dismisses quickly")

let emptyFailure = NotchHUDState.failure(.emptyTranscript)
assert(emptyFailure.label == "No speech detected", "empty speech has actionable copy")
assert(emptyFailure.autoDismissAfter == .milliseconds(2_500), "failure remains readable")

let privateFailure = NotchHUDState.failure(.transcriptionFailed("secret transcript detail"))
assert(privateFailure.label == "Transcription failed", "failure omits private error details")
assert(!privateFailure.label.contains("secret"), "failure cannot leak transcript details")

let unavailableTarget = NotchHUDState.failure(.pasteTargetUnavailable)
assert(unavailableTarget.label == "Copied · target unavailable", "unavailable target has safe recovery copy")

assert(NotchHUDLayout.clampedWidth(160) == 220, "notch width has a readable minimum")
assert(NotchHUDLayout.clampedWidth(320) == 320, "notch keeps a user-selected width")
assert(NotchHUDLayout.clampedWidth(600) == 420, "notch width has a restrained maximum")

let compactSize = NotchHUDLayout.size(for: .compact, preferredWidth: 280)
assert(compactSize == NotchHUDSize(width: 170, height: 38), "compact notch is waveform-sized")

let resultSize = NotchHUDLayout.size(for: .result, preferredWidth: 280)
assert(resultSize == NotchHUDSize(width: 520, height: 148), "result expands from preferred width")

let historySize = NotchHUDLayout.size(for: .history, preferredWidth: 280)
assert(historySize == NotchHUDSize(width: 560, height: 360), "history has room for filters and recent strip")

assert(NotchHUDLayout.size(for: .result, preferredWidth: 900).width == 620, "result width is bounded")
assert(NotchHUDLayout.size(for: .history, preferredWidth: 120).width == 500, "history width keeps a usable minimum")
assert(NotchHUDLayout.clampedWidth(.nan) == NotchHUDLayout.defaultWidth, "notch width rejects NaN")
assert(NotchHUDLayout.clampedWidth(.infinity) == NotchHUDLayout.defaultWidth, "notch width rejects positive infinity")
assert(NotchHUDLayout.clampedWidth(-.infinity) == NotchHUDLayout.defaultWidth, "notch width rejects negative infinity")
assert(
    NotchHUDLayout.size(for: .result, preferredWidth: .nan) == NotchHUDSize(width: 520, height: 148),
    "result notch falls back to the default width for NaN"
)

print("\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)

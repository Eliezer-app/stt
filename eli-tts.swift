/// eli-tts — persistent text-to-speech service for macOS
/// Reads text lines from stdin, speaks them using AVSpeechSynthesizer.
///
/// Protocol:
///   stdin:  text to speak (one line = one utterance)
///   stdin:  STOP           — interrupt current utterance
///   stdout: DONE           — utterance finished (or stopped)
///   stderr: "TTS: ready"   — ready for input

import AppKit
import AVFoundation

var voiceName = ""
var rate: Float = AVSpeechUtteranceDefaultSpeechRate

// Parse args
var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "-v", "--voice":
        i += 1
        voiceName = CommandLine.arguments[i]
    case "-r", "--rate":
        i += 1
        rate = Float(CommandLine.arguments[i]) ?? AVSpeechUtteranceDefaultSpeechRate
    case "-h", "--help":
        fputs("eli-tts — text-to-speech service\n", stderr)
        fputs("Usage: eli-tts [-v voice] [-r rate]\n", stderr)
        fputs("  -v  Voice name or identifier (default: system default)\n", stderr)
        fputs("  -r  Speech rate (0.0-1.0, default: \(AVSpeechUtteranceDefaultSpeechRate))\n", stderr)
        fputs("Reads text lines from stdin, speaks them, prints DONE after each.\n", stderr)
        fputs("\nAvailable voices:\n", stderr)
        for voice in AVSpeechSynthesisVoice.speechVoices() {
            if voice.language.hasPrefix("en") {
                fputs("  \(voice.name) [\(voice.language)] quality=\(voice.quality.rawValue)\n", stderr)
            }
        }
        exit(0)
    default:
        break
    }
    i += 1
}

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let synthesizer = AVSpeechSynthesizer()
    let ttsDelegate = TTSDelegate()
    var selectedVoice: AVSpeechSynthesisVoice?

    func applicationDidFinishLaunching(_ notification: Notification) {
        synthesizer.delegate = ttsDelegate

        // Find voice
        if !voiceName.isEmpty {
            let voices = AVSpeechSynthesisVoice.speechVoices()
            let matches = voices.filter { $0.name.localizedCaseInsensitiveContains(voiceName) }
            selectedVoice = matches.max(by: { $0.quality.rawValue < $1.quality.rawValue })
                ?? voices.first { $0.identifier.localizedCaseInsensitiveContains(voiceName) }
            if let v = selectedVoice {
                fputs("TTS: using voice \(v.name) [\(v.language)]\n", stderr)
            } else {
                fputs("TTS: voice '\(voiceName)' not found, using default\n", stderr)
            }
        }

        fputs("TTS: ready\n", stderr)

        // Read text lines on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                if text == "STOP" {
                    DispatchQueue.main.async {
                        if self.synthesizer.isSpeaking {
                            self.synthesizer.stopSpeaking(at: .immediate)
                        }
                    }
                    continue
                }

                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    self.speak(text) { sem.signal() }
                }
                sem.wait()
            }
            // stdin closed — wait for any in-progress speech
            DispatchQueue.main.async {
                if self.synthesizer.isSpeaking {
                    self.ttsDelegate.onFinish = { exit(0) }
                } else {
                    exit(0)
                }
            }
        }
    }

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voice = selectedVoice {
            utterance.voice = voice
        }

        ttsDelegate.onFinish = {
            print("DONE")
            fflush(stdout)
            completion?()
        }

        synthesizer.speak(utterance)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()

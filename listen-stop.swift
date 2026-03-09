/// listen-stop — detect stop words while TTS is playing (with AEC)
/// Persistent process: stays running, activated via stdin.
///
/// Protocol:
///   stdin:  START            — begin listening (AEC on)
///   stdin:  STOP             — stop listening
///   stdout: STOPPED          — stop word detected
///   stderr: status messages

import AppKit
import AVFoundation
import Speech

var stopWords: [String] = ["stop"]

// Parse args
var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "-w", "--stop-words":
        i += 1
        stopWords = CommandLine.arguments[i].split(separator: ",").map { String($0).lowercased() }
    case "-h", "--help":
        fputs("listen-stop — detect stop words during TTS playback\n", stderr)
        fputs("Usage: listen-stop [-w word1,word2,...]\n", stderr)
        fputs("  -w  Stop words, comma-separated (default: stop)\n", stderr)
        exit(0)
    default:
        break
    }
    i += 1
}

var audioEngine: AVAudioEngine?
var currentTask: SFSpeechRecognitionTask?
var currentRequest: SFSpeechAudioBufferRecognitionRequest?
var sessionActive = false

func endSession(detected: Bool = false) {
    guard sessionActive else { return }
    sessionActive = false
    currentTask?.cancel()
    currentTask = nil
    currentRequest?.endAudio()
    currentRequest = nil
    if let engine = audioEngine {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }
    if detected {
        print("STOPPED")
        fflush(stdout)
    }
    fputs("listen-stop: idle\n", stderr)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var recognizer: SFSpeechRecognizer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                fputs("Speech recognition not authorized\n", stderr)
                exit(1)
            }
            DispatchQueue.main.async { self.setup() }
        }
    }

    func setup() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            fputs("Cannot create recognizer\n", stderr)
            exit(1)
        }
        recognizer = rec

        let engine = AVAudioEngine()
        audioEngine = engine

        fputs("listen-stop: ready (words: \(stopWords.joined(separator: ", ")))\n", stderr)

        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                DispatchQueue.main.async {
                    switch trimmed {
                    case "START":
                        self.startSession()
                    case "STOP":
                        endSession()
                    default:
                        fputs("listen-stop: unknown command: \(trimmed)\n", stderr)
                    }
                }
            }
            DispatchQueue.main.async { exit(0) }
        }
    }

    func startSession() {
        if sessionActive { endSession() }
        guard let recognizer = recognizer, let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            fputs("listen-stop: failed to enable voice processing: \(error)\n", stderr)
            return
        }

        let micFormat = inputNode.outputFormat(forBus: 0)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: micFormat.sampleRate,
                                        channels: 1, interleaved: false)!

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        currentRequest = request

        currentTask = recognizer.recognitionTask(with: request) { result, error in
            guard sessionActive else { return }
            if error != nil {
                DispatchQueue.main.async { endSession() }
                return
            }
            guard let result = result else { return }
            let text = result.bestTranscription.formattedString.lowercased()
            for word in stopWords {
                if text.contains(word) {
                    DispatchQueue.main.async { endSession(detected: true) }
                    return
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 3200, format: micFormat) { buffer, _ in
            let n = buffer.frameLength
            guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: n) else { return }
            mono.frameLength = n
            memcpy(mono.floatChannelData![0], buffer.floatChannelData![0], Int(n) * MemoryLayout<Float>.size)
            request.append(mono)
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                fputs("listen-stop: failed to start engine: \(error)\n", stderr)
                return
            }
        }

        sessionActive = true
        fputs("listen-stop: active\n", stderr)
    }
}

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()

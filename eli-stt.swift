/// eli-stt — persistent speech recognition service for macOS
/// Reads JSON commands on stdin, captures audio from microphone.
///
/// Protocol:
///   stdin:  {"cmd":"START"}  — begin listening session
///   stdin:  {"cmd":"STOP"}   — stop current session
///   stdout: transcription lines (each line = full text so far)
///   stdout: END              — session over (silence timeout)
///   stdout: CANCEL           — session cancelled (stop-word detected)
///   stderr: "STT: ready"    — recognizer loaded, ready for commands

import AppKit
import AVFoundation
import Speech

let sampleRate: Double = 16000
let playbackRate: Double = 48000
var timeout: Double = 0
var locale = "en-US"
var useOnDevice = true
var addPunctuation = true
var contextualStrings: [String] = []
var stopWord: String = ""

// Parse args
var i = 1
while i < CommandLine.arguments.count {
    let arg = CommandLine.arguments[i]
    switch arg {
    case "-t", "--timeout":
        i += 1
        timeout = Double(CommandLine.arguments[i]) ?? 0
    case "-l", "--locale":
        i += 1
        locale = CommandLine.arguments[i]
    case "-d", "--device":
        useOnDevice = true
    case "-p", "--punctuation":
        addPunctuation = true
    case "-s", "--stop-word":
        i += 1
        stopWord = CommandLine.arguments[i]
    case "-c", "--context":
        i += 1
        contextualStrings.append(contentsOf: CommandLine.arguments[i].split(separator: ",").map { String($0) })
    case "-h", "--help":
        fputs("eli-stt — persistent speech recognition service\n", stderr)
        fputs("Usage: eli-stt [-d] [-p] [-l locale] [-t timeout] [-s stop-word]\n", stderr)
        fputs("  -d  On-device recognition (default)\n", stderr)
        fputs("  -p  Add punctuation (default)\n", stderr)
        fputs("  -l  Locale (default: en-US)\n", stderr)
        fputs("  -t  Silence timeout in seconds (0 = no timeout)\n", stderr)
        fputs("  -s  Stop word — end session when detected unquoted\n", stderr)
        fputs("  -c  Contextual strings, comma-separated\n", stderr)
        fputs("Reads JSON commands on stdin, captures audio from microphone.\n", stderr)
        exit(0)
    default:
        break
    }
    i += 1
}

// Global state
var audioEngine: AVAudioEngine?
var currentTask: SFSpeechRecognitionTask?
var currentRequest: SFSpeechAudioBufferRecognitionRequest?
var timeoutTimer: Timer?
var sessionActive = false

func resetTimer() {
    timeoutTimer?.invalidate()
    guard timeout > 0 else { return }
    timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
        endSession()
    }
}

func endSession(stopped: Bool = false) {
    guard sessionActive else { return }
    sessionActive = false
    timeoutTimer?.invalidate()
    timeoutTimer = nil
    currentTask?.cancel()
    currentTask = nil
    currentRequest?.endAudio()
    currentRequest = nil
    // Remove mic tap
    if let engine = audioEngine, engine.isRunning {
        engine.inputNode.removeTap(onBus: 0)
    }
    playIdleBeep()
    print(stopped ? "CANCEL" : "END")
    fflush(stdout)
    fputs("STT: idle\n", stderr)
}

func playTone(freq: Float, duration: Double, volume: Float = 0.3) -> [Float] {
    let count = Int(playbackRate * duration)
    let fade = Int(playbackRate * 0.01)
    var samples = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let t = Float(i) / Float(playbackRate)
        samples[i] = sin(2 * .pi * freq * t) * volume
    }
    for i in 0..<fade {
        samples[i] *= Float(i) / Float(fade)
    }
    for i in 0..<fade {
        samples[count - 1 - i] *= Float(i) / Float(fade)
    }
    return samples
}

func playSound(_ samples: [Float]) {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: playbackRate,
                               channels: 1,
                               interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                  frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    memcpy(buffer.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)

    let player = AVAudioPlayerNode()
    let engine = AVAudioEngine()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try? engine.start()
    player.scheduleBuffer(buffer, at: nil)
    player.play()
    let duration = Double(samples.count) / playbackRate + 0.05
    Thread.sleep(forTimeInterval: duration)
    engine.stop()
}

func playBeep() {
    playSound(playTone(freq: 880, duration: 0.1))
}

func playIdleBeep() {
    let gap = [Float](repeating: 0, count: Int(playbackRate * 0.01))
    let sound = playTone(freq: 660, duration: 0.08) + gap + playTone(freq: 440, duration: 0.1)
    playSound(sound)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var recognizer: SFSpeechRecognizer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                fputs("Speech recognition not authorized: \(status.rawValue)\n", stderr)
                exit(1)
            }
            DispatchQueue.main.async { self.setup() }
        }
    }

    func setup() {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            fputs("Cannot create recognizer for locale \(locale)\n", stderr)
            exit(1)
        }
        if useOnDevice && !rec.supportsOnDeviceRecognition {
            fputs("On-device recognition not supported for \(locale)\n", stderr)
            exit(1)
        }
        recognizer = rec

        // Prepare audio engine (stays alive)
        let engine = AVAudioEngine()
        audioEngine = engine

        fputs("STT: ready\n", stderr)

        // Read commands on stdin in background
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                var cmd = trimmed
                // Try JSON
                if let data = trimmed.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let c = json["cmd"] as? String {
                    cmd = c
                }

                DispatchQueue.main.async {
                    switch cmd {
                    case "START":
                        self.startSession()
                    case "STOP":
                        endSession()
                    default:
                        fputs("STT: unknown command: \(cmd)\n", stderr)
                    }
                }
            }
            // stdin closed
            DispatchQueue.main.async { exit(0) }
        }
    }

    func startSession() {
        // Stop any existing session
        if sessionActive {
            endSession()
        }

        guard let recognizer = recognizer, let engine = audioEngine else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = useOnDevice
        request.addsPunctuation = addPunctuation
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        currentRequest = request

        var finalized = ""
        var prevSegment = ""

        currentTask = recognizer.recognitionTask(with: request) { result, error in
            guard sessionActive else { return }

            if let error = error {
                fputs("STT: error: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async { endSession() }
                return
            }
            guard let result = result else { return }

            DispatchQueue.main.async { resetTimer() }

            let segment = result.bestTranscription.formattedString

            // Detect reset: text got much shorter → new utterance segment
            if !prevSegment.isEmpty && segment.count < prevSegment.count / 2 {
                finalized = finalized.isEmpty ? prevSegment : finalized + " " + prevSegment
            }
            prevSegment = segment

            let full = finalized.isEmpty ? segment : finalized + " " + segment

            // Stop-word: end session if unquoted match found (don't output the trigger line)
            if !stopWord.isEmpty {
                let lower = full.lowercased()
                let sw = stopWord.lowercased()
                if let range = lower.range(of: sw) {
                    let prefix = full[full.startIndex..<range.lowerBound]
                    if !prefix.contains("\"") {
                        DispatchQueue.main.async { endSession(stopped: true) }
                        return
                    }
                }
            }

            print(full)
            fflush(stdout)

            if result.isFinal {
                finalized = full
                prevSegment = ""
            }
        }

        // Install mic tap
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 3200, format: micFormat) { buffer, _ in
            request.append(buffer)
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                fputs("STT: failed to start audio engine: \(error)\n", stderr)
                return
            }
        }

        sessionActive = true
        playBeep()
        resetTimer()
        fputs("STT: active\n", stderr)
    }
}

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()

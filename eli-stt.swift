/// eli-stt — command line speech recognition for macOS
/// Reads 16kHz mono float32 PCM from stdin, outputs incremental transcription.
/// Usage: eli-stt [-t timeout] [-l locale]
///   Audio on stdin: raw float32 PCM, 16kHz, mono
///   No stdin (tty): captures from system microphone

import AppKit
import AVFoundation
import Speech

let sampleRate: Double = 16000
var timeout: Double = 0
var locale = "en-US"
var useOnDevice = true
var addPunctuation = true
var contextualStrings: [String] = []

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
    case "-c", "--context":
        i += 1
        contextualStrings.append(contentsOf: CommandLine.arguments[i].split(separator: ",").map { String($0) })
    case "-h", "--help":
        fputs("eli-stt — speech recognition from stdin or microphone\n", stderr)
        fputs("Usage: eli-stt [-d] [-p] [-l locale] [-t timeout]\n", stderr)
        fputs("  -d  On-device recognition (default)\n", stderr)
        fputs("  -p  Add punctuation (default)\n", stderr)
        fputs("  -l  Locale (default: en-US)\n", stderr)
        fputs("  -t  Silence timeout in seconds (0 = no timeout)\n", stderr)
        fputs("  -c  Contextual strings, comma-separated (e.g. \"Eliezer,Yudkowsky\")\n", stderr)
        fputs("Audio: 16kHz mono float32 PCM on stdin, or microphone if stdin is a tty\n", stderr)
        exit(0)
    default:
        break
    }
    i += 1
}

let useMic = isatty(STDIN_FILENO) != 0

// Keep engine alive for mic mode
var audioEngine: AVAudioEngine?
var timeoutTimer: Timer?

func resetTimer() {
    timeoutTimer?.invalidate()
    guard timeout > 0 else { return }
    timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
        exit(0)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                fputs("Speech recognition not authorized: \(status.rawValue)\n", stderr)
                exit(1)
            }
            DispatchQueue.main.async { self.startRecognition() }
        }
    }

    func startRecognition() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            fputs("Cannot create recognizer for locale \(locale)\n", stderr)
            exit(1)
        }

        if useOnDevice && !recognizer.supportsOnDeviceRecognition {
            fputs("On-device recognition not supported for \(locale)\n", stderr)
            exit(1)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = useOnDevice
        request.addsPunctuation = addPunctuation
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        // Accumulate text across recognition segments (recognizer resets on pauses)
        var finalized = ""
        var prevSegment = ""

        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                return
            }
            guard let result = result else { return }

            resetTimer()

            let segment = result.bestTranscription.formattedString

            // Detect reset: text got much shorter → new utterance segment
            if !prevSegment.isEmpty && segment.count < prevSegment.count / 2 {
                finalized = finalized.isEmpty ? prevSegment : finalized + " " + prevSegment
            }
            prevSegment = segment

            let full = finalized.isEmpty ? segment : finalized + " " + segment
            print(full)
            fflush(stdout)

            if result.isFinal {
                finalized = full
                prevSegment = ""
            }
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!

        if useMic {
            let engine = AVAudioEngine()
            audioEngine = engine  // prevent deallocation
            let inputNode = engine.inputNode
            inputNode.installTap(onBus: 0, bufferSize: 3200,
                                 format: inputNode.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            do {
                try engine.start()
            } catch {
                fputs("Failed to start audio engine: \(error)\n", stderr)
                exit(1)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let chunkSize = 1600  // 100ms at 16kHz
                let buf = UnsafeMutablePointer<Float>.allocate(capacity: chunkSize)
                defer { buf.deallocate() }

                while true {
                    let n = fread(buf, MemoryLayout<Float>.size, chunkSize, stdin)
                    if n == 0 {
                        request.endAudio()
                        break
                    }
                    let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(n))!
                    pcm.frameLength = AVAudioFrameCount(n)
                    memcpy(pcm.floatChannelData![0], buf, n * MemoryLayout<Float>.size)
                    request.append(pcm)
                }
            }
        }

        resetTimer()
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()

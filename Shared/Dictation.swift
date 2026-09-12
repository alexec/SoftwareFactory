@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

/// Dictating a task title. One on-device engine, `SpeechAnalyzer` with a
/// `SpeechTranscriber`: its volatile results put words on screen as they are recognised,
/// and its finalised text replaces them as it settles. Nothing leaves the device.
@Observable
@MainActor
final class Dictation {
    enum Standing: Equatable {
        case notAsked
        case allowed
        case denied
        case unavailable(String)
    }

    private(set) var standing: Standing = .notAsked
    private(set) var isListening = false
    /// What has settled so far.
    private(set) var settled = ""
    /// What is still being recognised, shown after `settled`.
    private(set) var volatile = ""

    var text: String {
        let parts = [settled, volatile].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: _Concurrency.Task<Void, Never>?

    init() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: standing = .allowed
        case .denied: standing = .denied
        default: standing = .notAsked
        }
    }

    /// The primer's one button calls this; it is what shows the microphone alert.
    func ask() async {
        let ok = await AVAudioApplication.requestRecordPermission()
        standing = ok ? .allowed : .denied
    }

    func start(locale: Locale = .current) async {
        guard standing == .allowed, !isListening else { return }
        settled = ""
        volatile = ""
        do {
            guard SpeechTranscriber.isAvailable else {
                standing = .unavailable("Dictation is not available on this device.")
                return
            }
            var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            if resolved == nil { resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) }
            let resolvedLocale = resolved ?? locale
            let transcriber = SpeechTranscriber(locale: resolvedLocale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                standing = .unavailable("No audio format the recogniser can use.")
                return
            }
            let node = engine.inputNode
            let micFormat = node.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
                standing = .unavailable("No microphone.")
                return
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = continuation
            self.transcriber = transcriber
            self.analyzer = analyzer

            results = _Concurrency.Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let words = String(result.text.characters)
                        await MainActor.run {
                            guard let self else { return }
                            if result.isFinal {
                                self.settled = self.settled.isEmpty ? words : self.settled + " " + words
                                self.volatile = ""
                            } else {
                                self.volatile = words
                            }
                        }
                    }
                } catch {
                    await MainActor.run { self?.standing = .unavailable(error.localizedDescription) }
                }
            }

            guard let tap = TapConverter(from: micFormat, to: format) else {
                standing = .unavailable("No audio format the recogniser can use.")
                return
            }
            node.removeTap(onBus: 0)
            // The tap block runs on the audio thread, never on the main actor, so
            // everything it touches lives in the converter helper below.
            node.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { @Sendable buffer, _ in
                if let out = tap.convert(buffer) { continuation.yield(AnalyzerInput(buffer: out)) }
            }
            try await analyzer.start(inputSequence: stream)
            engine.prepare()
            try engine.start()
            isListening = true
        } catch {
            standing = .unavailable(error.localizedDescription)
            await stop()
        }
    }

    /// Stops listening and lets the last words settle. Returns everything recognised.
    @discardableResult
    func stop() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        if let results {
            let watchdog = _Concurrency.Task { try? await _Concurrency.Task.sleep(for: .seconds(3)); results.cancel() }
            await results.value
            watchdog.cancel()
        }
        results = nil
        analyzer = nil
        transcriber = nil
        isListening = false
        if !volatile.isEmpty {
            settled = settled.isEmpty ? volatile : settled + " " + volatile
            volatile = ""
        }
        return settled
    }

    func clear() {
        settled = ""
        volatile = ""
    }
}

/// Resamples microphone buffers to the recogniser's format, on the audio thread. Only
/// that thread touches it, one buffer at a time, which is why it can claim to be Sendable.
private final class TapConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let from: AVAudioFormat
    private let to: AVAudioFormat

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: from, to: to) else { return nil }
        self.converter = converter
        self.from = from
        self.to = to
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * to.sampleRate / from.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: capacity) else { return nil }
        let once = Once()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            guard once.first() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// True the first time, false after: the converter's input block is handed one buffer.
private final class Once: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()

    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

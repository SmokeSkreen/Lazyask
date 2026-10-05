import AppKit
import AVFoundation
import CoreMedia
import LazyAskCore
import ScreenCaptureKit

enum CaptureEvent: Sendable {
    case audio(AudioChunk)
    case tick(Double)
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let system: AsyncThrowingStream<CaptureEvent, Error>
    let microphone: AsyncThrowingStream<CaptureEvent, Error>
    private let systemContinuation: AsyncThrowingStream<CaptureEvent, Error>.Continuation
    private let micContinuation: AsyncThrowingStream<CaptureEvent, Error>.Continuation
    private let queue = DispatchQueue(label: "app.lazyask.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    // Converters are accessed only on the audio queue.
    private var converters: [AudioSource: PCMConverter] = [:]
    private let epochOffsetMs = Date().timeIntervalSince1970 * 1_000
        - CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000

    override init() {
        (system, systemContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(256))
        (microphone, micContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(256))
        super.init()
    }

    @MainActor
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw LazyAskError.api("No display is available for meeting audio capture.")
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 24_000
        config.channelCount = 1
        config.captureMicrophone = true
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        // ScreenCaptureKit needs a screen output even though no screen frames are used.
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = newStream
        try await newStream.startCapture()
        if Task.isCancelled {
            try? await newStream.stopCapture()
            throw CancellationError()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970 * 1_000
            self.emit(.tick(now), to: .system)
            self.emit(.tick(now), to: .mic)
        }
        self.timer = timer
        timer.resume()
    }

    @MainActor
    func stop() async {
        timer?.cancel()
        timer = nil
        let old = stream
        stream = nil
        if let old { try? await old.stopCapture() }
        systemContinuation.finish()
        micContinuation.finish()
        queue.async { [weak self] in self?.converters.removeAll() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        systemContinuation.finish(throwing: error)
        micContinuation.finish(throwing: error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        let source: AudioSource = type == .audio ? .system : .mic
        do {
            let converter = converters[source] ?? PCMConverter()
            converters[source] = converter
            let data = try converter.convert(sampleBuffer)
            guard !data.isEmpty else { return }
            let presentationMs = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp) * 1_000 + epochOffsetMs
            let now = Date().timeIntervalSince1970 * 1_000
            let durationMs = Double(data.count / 2) / 24_000 * 1_000
            let timestamp = presentationMs.isFinite && abs(now - presentationMs) < 10_000
                ? presentationMs : now - durationMs
            emit(.audio(AudioChunk(source: source, pcm16: data, timestampMs: timestamp)), to: source)
        } catch {
            systemContinuation.finish(throwing: error)
            micContinuation.finish(throwing: error)
        }
    }

    private func emit(_ event: CaptureEvent, to source: AudioSource) {
        let continuation = source == .system ? systemContinuation : micContinuation
        if case .dropped = continuation.yield(event) {
            continuation.finish(throwing: LazyAskError.api("The audio connection is too slow. Start listening again."))
        }
    }
}

final class PCMConverter {
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                            channels: 1, interleaved: true)!

    func convert(_ sample: CMSampleBuffer) throws -> Data {
        guard let description = sample.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let input = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw LazyAskError.invalidAudio
        }
        input.frameLength = AVAudioFrameCount(sample.numSamples)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList
        )
        guard copyStatus == noErr else { throw LazyAskError.invalidAudio }
        if inputFormat != format {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { throw LazyAskError.invalidAudio }
        let frames = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else {
            throw LazyAskError.invalidAudio
        }
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else { throw LazyAskError.invalidAudio }
        guard let data = output.int16ChannelData?.pointee else { return Data() }
        return Data(bytes: data, count: Int(output.frameLength) * 2)
    }
}

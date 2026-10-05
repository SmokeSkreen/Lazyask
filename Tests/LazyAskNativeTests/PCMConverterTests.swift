import AVFoundation
import CoreMedia
import Foundation
import LazyAskCore
import Testing
@testable import LazyAsk

@Suite("Native PCM conversion")
struct PCMConverterTests {
    @Test func convertsNativeMicrophoneAndStereoMeetingAudio() throws {
        let converter = PCMConverter()
        for (rate, channels) in [(48_000.0, AVAudioChannelCount(2)), (44_100.0, AVAudioChannelCount(1))] {
            let sample = try makeSample(rate: rate, channels: channels)
            let data = try converter.convert(sample)
            let chunk = AudioChunk(source: .mic, pcm16: data, timestampMs: 0)
            // A streaming resampler holds a short filter tail for the next input buffer.
            #expect(chunk.durationMs > 80)
            #expect(chunk.durationMs <= 100)
            #expect(abs(chunk.rms - 0.25) < 0.02)
        }
    }

    @Test func handlesConsecutiveFramesWithoutEndingConverter() throws {
        let converter = PCMConverter()
        let sample = try makeSample(rate: 48_000, channels: 1)
        var data = Data()
        for _ in 0..<10 { data.append(try converter.convert(sample)) }
        let audio = AudioChunk(source: .system, pcm16: data, timestampMs: 0)
        #expect(audio.durationMs > 980)
        #expect(audio.durationMs <= 1_000)
        #expect(abs(audio.rms - 0.25) < 0.02)
    }

    private func makeSample(rate: Double, channels: AVAudioChannelCount) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: channels, interleaved: false))
        let frameCount = AVAudioFrameCount(rate / 10)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        pcm.frameLength = frameCount
        let channelData = try #require(pcm.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) { channelData[channel][frame] = 0.25 }
        }
        var description: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        #expect(formatStatus == noErr)
        let audioDescription = try #require(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: audioDescription,
            sampleCount: Int(frameCount), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        #expect(status == noErr)
        let result = try #require(sample)
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(result,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList)
        #expect(dataStatus == noErr)
        #expect(CMSampleBufferSetDataReady(result) == noErr)
        return result
    }
}

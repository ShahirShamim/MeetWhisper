import AVFoundation

/// Accepts PCM buffers in any format and appends them to a 16 kHz mono 16-bit WAV file.
/// Not thread-safe: each recorder owns one writer and feeds it from a single callback queue.
final class WavWriter {
    static let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Running peak of everything written, for dead-track detection (e.g. mic
    /// permission silently missing). -180 dB = nothing but digital silence.
    private(set) var peakLevel: Float = 0
    var peakDB: Float { 20 * log10(max(peakLevel, 1e-9)) }

    init(url: URL) throws {
        file = try AVAudioFile(
            forWriting: url,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, buffer.frameLength > 0 else { return }
        if converter == nil || sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
        }
        guard let converter else { return }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return
        }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        if out.frameLength > 0 {
            if let data = out.floatChannelData?[0] {
                for i in 0..<Int(out.frameLength) {
                    peakLevel = max(peakLevel, abs(data[i]))
                }
            }
            try file.write(from: out)
        }
    }

    /// Drains the converter's resampler tail and closes the file.
    func finish() {
        if let converter, let file,
           let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: 8192) {
            var conversionError: NSError?
            converter.convert(to: out, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if conversionError == nil, out.frameLength > 0 {
                try? file.write(from: out)
            }
        }
        converter = nil
        file = nil // AVAudioFile finalizes the WAV header on dealloc
    }
}

import AVFoundation
import Foundation

struct AudioChunk {
    let start: TimeInterval // offset from session t=0
    let duration: TimeInterval
    let url: URL
}

/// Splits a 16 kHz mono WAV into utterance chunks using energy-based voice activity
/// detection. TypeWhisper returns no timestamps, so each chunk's start offset becomes
/// its timestamp in the merged transcript.
enum VADChunker {
    struct Config {
        var frameDuration: TimeInterval = 0.03 // RMS window
        var speechStartFrames = 3 // 90 ms of speech opens a segment
        var silenceEndDuration: TimeInterval = 0.7 // this much silence closes it
        var padding: TimeInterval = 0.25 // context around each segment
        var minUtterance: TimeInterval = 0.4 // drop blips (whisper hallucinates on them)
        var mergeGap: TimeInterval = 0.3 // merge segments closer than this
        var thresholdAboveFloorDB: Float = 9
        var minThresholdDB: Float = -48
    }

    static func chunk(
        wav url: URL,
        into directory: URL,
        label: String,
        config: Config = Config()
    ) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0, format.channelCount == 1 else { return [] }

        let framesPerWindow = Int(sampleRate * config.frameDuration)
        let rmsDB = try computeRMS(file: file, framesPerWindow: framesPerWindow)
        guard !rmsDB.isEmpty else { return [] }

        let threshold = detectionThreshold(rmsDB: rmsDB, config: config)
        var segments = detectSegments(rmsDB: rmsDB, threshold: threshold, config: config)
            .map { seg -> (start: TimeInterval, end: TimeInterval) in
                let start = max(0, TimeInterval(seg.startFrame) * config.frameDuration - config.padding)
                let end = min(
                    TimeInterval(totalFrames) / sampleRate,
                    TimeInterval(seg.endFrame) * config.frameDuration + config.padding
                )
                return (start, end)
            }
        segments = merge(segments, gap: config.mergeGap)
        segments = segments.filter { $0.end - $0.start >= config.minUtterance }

        var chunks: [AudioChunk] = []
        for (index, segment) in segments.enumerated() {
            let chunkURL = directory.appendingPathComponent(String(format: "%@-%04d.wav", label, index))
            try extract(segment: segment, from: url, to: chunkURL)
            chunks.append(AudioChunk(start: segment.start, duration: segment.end - segment.start, url: chunkURL))
        }
        return chunks
    }

    // MARK: - Internals

    private static func computeRMS(file: AVAudioFile, framesPerWindow: Int) throws -> [Float] {
        let format = file.processingFormat
        let blockFrames = AVAudioFrameCount(framesPerWindow * 128)
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            return []
        }

        var rmsDB: [Float] = []
        var leftover: [Float] = []
        leftover.reserveCapacity(framesPerWindow * 2)

        while file.framePosition < file.length {
            try file.read(into: block)
            guard block.frameLength > 0, let data = block.floatChannelData?[0] else { break }
            leftover.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(block.frameLength)))

            var offset = 0
            while leftover.count - offset >= framesPerWindow {
                var sum: Float = 0
                for i in offset..<(offset + framesPerWindow) {
                    sum += leftover[i] * leftover[i]
                }
                let rms = (sum / Float(framesPerWindow)).squareRoot()
                rmsDB.append(20 * log10(max(rms, 1e-9)))
                offset += framesPerWindow
            }
            leftover.removeFirst(offset)
        }
        return rmsDB
    }

    private static func detectionThreshold(rmsDB: [Float], config: Config) -> Float {
        let sorted = rmsDB.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.2)]
        return max(noiseFloor + config.thresholdAboveFloorDB, config.minThresholdDB)
    }

    private static func detectSegments(
        rmsDB: [Float],
        threshold: Float,
        config: Config
    ) -> [(startFrame: Int, endFrame: Int)] {
        let endFrames = max(1, Int(config.silenceEndDuration / config.frameDuration))
        var segments: [(startFrame: Int, endFrame: Int)] = []
        var inSpeech = false
        var speechRun = 0
        var silenceRun = 0
        var currentStart = 0

        for (i, db) in rmsDB.enumerated() {
            let isSpeech = db > threshold
            if !inSpeech {
                if isSpeech {
                    speechRun += 1
                    if speechRun >= config.speechStartFrames {
                        inSpeech = true
                        currentStart = i - speechRun + 1
                        silenceRun = 0
                    }
                } else {
                    speechRun = 0
                }
            } else {
                if isSpeech {
                    silenceRun = 0
                } else {
                    silenceRun += 1
                    if silenceRun >= endFrames {
                        segments.append((currentStart, i - silenceRun + 1))
                        inSpeech = false
                        speechRun = 0
                    }
                }
            }
        }
        if inSpeech {
            segments.append((currentStart, rmsDB.count))
        }
        return segments
    }

    private static func merge(
        _ segments: [(start: TimeInterval, end: TimeInterval)],
        gap: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for segment in segments {
            if let last = merged.last, segment.start - last.end < gap {
                merged[merged.count - 1].end = max(last.end, segment.end)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func extract(
        segment: (start: TimeInterval, end: TimeInterval),
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        let sampleRate = format.sampleRate

        let startFrame = AVAudioFramePosition(segment.start * sampleRate)
        let endFrame = min(AVAudioFramePosition(segment.end * sampleRate), source.length)
        var remaining = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard remaining > 0 else { return }

        let destination = try AVAudioFile(
            forWriting: destinationURL,
            settings: WavWriter.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        source.framePosition = startFrame
        let blockCapacity: AVAudioFrameCount = 65536
        guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockCapacity) else {
            return
        }
        while remaining > 0 {
            try source.read(into: block, frameCount: min(remaining, blockCapacity))
            guard block.frameLength > 0 else { break }
            try destination.write(from: block)
            remaining -= block.frameLength
        }
    }
}

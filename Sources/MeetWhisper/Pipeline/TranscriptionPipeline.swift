import Foundation

/// Post-recording pipeline: VAD-chunk both tracks, transcribe every chunk through
/// TypeWhisper, merge by start offset into an interleaved Me/Them transcript.
final class TranscriptionPipeline {
    struct Progress {
        let completed: Int
        let total: Int
    }

    private let client = TypeWhisperClient()

    func run(session: Session, onProgress: @escaping (Progress) -> Void) async throws -> URL {
        // Connectivity check up front so the user gets a clear error before chunking.
        _ = try await client.status()

        let chunksDir = session.folderURL.appendingPathComponent("chunks", isDirectory: true)
        try? FileManager.default.removeItem(at: chunksDir)
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunksDir) }

        var jobs: [(chunk: AudioChunk, speaker: String)] = []
        if FileManager.default.fileExists(atPath: session.micURL.path) {
            for chunk in try VADChunker.chunk(wav: session.micURL, into: chunksDir, label: "me") {
                jobs.append((chunk, "Me"))
            }
        }
        if FileManager.default.fileExists(atPath: session.systemURL.path) {
            for chunk in try VADChunker.chunk(wav: session.systemURL, into: chunksDir, label: "them") {
                jobs.append((chunk, "Them"))
            }
        }
        jobs.sort { $0.chunk.start < $1.chunk.start }

        var lines: [TranscriptLine] = []
        for (index, job) in jobs.enumerated() {
            let text = try await client.transcribe(fileURL: job.chunk.url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append(TranscriptLine(
                    start: job.chunk.start,
                    duration: job.chunk.duration,
                    speaker: job.speaker,
                    text: text
                ))
            }
            onProgress(Progress(completed: index + 1, total: jobs.count))
        }

        let markdown = TranscriptBuilder.build(
            lines: lines,
            sessionDate: session.startedAt,
            duration: session.duration
        )
        try markdown.write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        return session.transcriptURL
    }
}

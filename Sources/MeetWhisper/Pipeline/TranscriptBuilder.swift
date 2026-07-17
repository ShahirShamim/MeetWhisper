import Foundation

struct TranscriptLine {
    let start: TimeInterval
    let duration: TimeInterval
    let speaker: String
    var text: String

    var end: TimeInterval { start + duration }
}

enum TranscriptBuilder {
    static func build(lines: [TranscriptLine], sessionDate: Date, duration: TimeInterval?) -> String {
        let lines = dedupe(lines)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        var output = "# Meeting — \(dateFormatter.string(from: sessionDate))\n\n"
        if let duration {
            output += "Duration: \(timestamp(duration))\n\n"
        }
        for line in lines.sorted(by: { $0.start < $1.start }) {
            output += "[\(timestamp(line.start))] **\(line.speaker):** \(line.text)\n\n"
        }
        return output
    }

    /// Removes speaker-bleed duplicates: without echo cancellation, meeting audio
    /// played over speakers is picked up by the mic, so the same words appear on
    /// both tracks at overlapping times. The later-starting copy is the leaked one
    /// (acoustic path / echo is always delayed). Near-identical text → drop it;
    /// partially-contained text (bleed fused with real speech in one chunk) →
    /// trim the matching run of words and keep the rest.
    static func dedupe(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var sorted = lines.sorted { $0.start < $1.start }
        var dropped = Set<Int>()

        for i in sorted.indices {
            guard !dropped.contains(i) else { continue }
            for j in (i + 1)..<sorted.count {
                guard !dropped.contains(j) else { continue }
                let a = sorted[i]
                let b = sorted[j]
                if b.start > a.end + 1.0 { break }
                guard a.speaker != b.speaker else { continue }

                let wordsA = normalizedWords(a.text)
                let wordsB = normalizedWords(b.text)
                guard wordsA.count >= 3, wordsB.count >= 3 else { continue }
                let shared = Set(wordsA).intersection(Set(wordsB)).count
                let jaccard = Double(shared) / Double(Set(wordsA).union(Set(wordsB)).count)
                let containment = Double(shared) / Double(min(wordsA.count, wordsB.count))

                let lengthRatio = Double(max(wordsA.count, wordsB.count))
                    / Double(min(wordsA.count, wordsB.count))
                if jaccard >= 0.75, lengthRatio <= 1.3 {
                    // Pure duplicate. Near-simultaneous starts = local speaker
                    // bleed → the mic ("Me") copy is the leaked one regardless of
                    // order; clearly delayed = echo → drop the later copy.
                    if b.start - a.start < 0.3 {
                        dropped.insert(a.speaker == "Me" ? i : j)
                    } else {
                        dropped.insert(j)
                    }
                    if dropped.contains(i) { break }
                } else if containment >= 0.8, shared >= 5 {
                    // Mixed chunk: bleed fused with genuine speech. Trim the
                    // overlapping word run from the longer line.
                    let longerIsB = wordsB.count > wordsA.count
                    let longer = longerIsB ? b : a
                    let shorter = longerIsB ? a : b
                    let trimmed = trimSharedRun(from: longer.text, matching: shorter.text)
                    let index = longerIsB ? j : i
                    if normalizedWords(trimmed).count >= 3 {
                        sorted[index].text = trimmed
                    } else {
                        dropped.insert(index)
                    }
                }
            }
        }
        return sorted.indices.filter { !dropped.contains($0) }.map { sorted[$0] }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Removes the longest run of words at the start or end of `text` that
    /// matches the start/end of `reference` (case/punctuation-insensitive).
    private static func trimSharedRun(from text: String, matching reference: String) -> String {
        let textWords = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let refWords = normalizedWords(reference)
        guard !textWords.isEmpty, !refWords.isEmpty else { return text }

        func norm(_ word: String) -> String {
            word.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }

        var prefixRun = 0
        while prefixRun < textWords.count, prefixRun < refWords.count,
              norm(textWords[prefixRun]) == refWords[prefixRun] {
            prefixRun += 1
        }
        var suffixRun = 0
        while suffixRun < textWords.count - prefixRun, suffixRun < refWords.count,
              norm(textWords[textWords.count - 1 - suffixRun]) == refWords[refWords.count - 1 - suffixRun] {
            suffixRun += 1
        }
        if prefixRun >= suffixRun, prefixRun >= 3 {
            return textWords.dropFirst(prefixRun).joined(separator: " ")
        }
        if suffixRun >= 3 {
            return textWords.dropLast(suffixRun).joined(separator: " ")
        }
        return text
    }

    static func timestamp(_ time: TimeInterval) -> String {
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

import Foundation

enum SessionStatus: String, Codable {
    case recording
    case recorded
    case transcribing
    case done
    case failed
}

struct Session: Codable, Identifiable, Equatable {
    var id: String // folder name, e.g. "2026-07-17 14.30.05"
    var startedAt: Date
    var duration: TimeInterval?
    var status: SessionStatus
    var errorMessage: String?
    /// Absolute folder path, stored so sessions stay addressable even after the
    /// output root setting changes mid-flight. Optional for pre-setting sessions;
    /// `loadAll` always overwrites it with the scanned location.
    var folderPath: String?

    var folderURL: URL {
        if let folderPath {
            return URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        return SessionStore.rootURL.appendingPathComponent(id, isDirectory: true)
    }

    var micURL: URL { folderURL.appendingPathComponent("mic.wav") }
    var systemURL: URL { folderURL.appendingPathComponent("system.wav") }
    var transcriptURL: URL { folderURL.appendingPathComponent("transcript.md") }
    var metadataURL: URL { folderURL.appendingPathComponent("session.json") }

    var hasAudio: Bool {
        FileManager.default.fileExists(atPath: micURL.path)
            || FileManager.default.fileExists(atPath: systemURL.path)
    }
}

enum SessionStore {
    static var rootURL: URL { SettingsStore.shared.outputRootURL }

    static func newSession() throws -> Session {
        let now = Date()
        let baseName = SettingsStore.renderSessionName(
            template: SettingsStore.shared.sessionNameTemplate,
            date: now
        )
        // Ensure the folder name is unique under the current root.
        var name = baseName
        var counter = 2
        while FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent(name).path
        ) {
            name = "\(baseName) \(counter)"
            counter += 1
        }

        let folderURL = rootURL.appendingPathComponent(name, isDirectory: true)
        let session = Session(
            id: name,
            startedAt: now,
            duration: nil,
            status: .recording,
            errorMessage: nil,
            folderPath: folderURL.path
        )
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try save(session)
        return session
    }

    static func save(_ session: Session) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: session.metadataURL)
    }

    static func loadAll() -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs
            .compactMap { dir -> Session? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                      var session = try? decoder.decode(Session.self, from: data) else {
                    return nil
                }
                session.folderPath = dir.path // scanned location is authoritative
                return session
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

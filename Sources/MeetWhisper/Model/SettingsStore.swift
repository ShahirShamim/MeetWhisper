import Combine
import Foundation

/// User preferences, persisted in UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let outputRoot = "outputRootPath"
        static let keepRawAudio = "keepRawAudio"
        static let nameTemplate = "sessionNameTemplate"
    }

    static let defaultRootPath = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingTranscripts", isDirectory: true)
        .path
    static let defaultNameTemplate = "{date} {time}"
    static let templateTokens = [
        "{date}", "{time}", "{year}", "{month}", "{day}",
        "{hour}", "{minute}", "{second}", "{weekday}",
    ]

    @Published var outputRootPath: String {
        didSet { UserDefaults.standard.set(outputRootPath, forKey: Keys.outputRoot) }
    }
    @Published var keepRawAudio: Bool {
        didSet { UserDefaults.standard.set(keepRawAudio, forKey: Keys.keepRawAudio) }
    }
    @Published var sessionNameTemplate: String {
        didSet { UserDefaults.standard.set(sessionNameTemplate, forKey: Keys.nameTemplate) }
    }

    private init() {
        let defaults = UserDefaults.standard
        outputRootPath = defaults.string(forKey: Keys.outputRoot) ?? Self.defaultRootPath
        keepRawAudio = defaults.object(forKey: Keys.keepRawAudio) as? Bool ?? true
        sessionNameTemplate = defaults.string(forKey: Keys.nameTemplate) ?? Self.defaultNameTemplate
    }

    var outputRootURL: URL {
        URL(fileURLWithPath: outputRootPath, isDirectory: true)
    }

    /// Renders a session folder name from a token template. Falls back to the
    /// default timestamp when the template renders to nothing usable, and strips
    /// characters that are invalid in folder names.
    static func renderSessionName(template: String, date: Date) -> String {
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        let values: [String: String] = [
            "{date}": format("yyyy-MM-dd"),
            "{time}": format("HH.mm.ss"),
            "{year}": format("yyyy"),
            "{month}": format("MM"),
            "{day}": format("dd"),
            "{hour}": format("HH"),
            "{minute}": format("mm"),
            "{second}": format("ss"),
            "{weekday}": format("EEEE"),
        ]
        var name = template
        for (token, value) in values {
            name = name.replacingOccurrences(of: token, with: value)
        }
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = format("yyyy-MM-dd HH.mm.ss")
        }
        return name
    }
}

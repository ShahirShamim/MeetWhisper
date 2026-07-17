import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--test-pipeline") {
            guard args.count > flagIndex + 2 else {
                print("Usage: MeetWhisper --test-pipeline <me.wav> <them.wav>")
                exit(2)
            }
            exit(HeadlessRunner.runTestPipeline(
                micPath: args[flagIndex + 1],
                systemPath: args[flagIndex + 2]
            ))
        }
        if let flagIndex = args.firstIndex(of: "--test-record") {
            guard args.count > flagIndex + 3, let seconds = Int(args[flagIndex + 1]) else {
                print("Usage: MeetWhisper --test-record <seconds> <raw|vp> <outputDir>")
                exit(2)
            }
            exit(HeadlessRunner.runTestRecord(
                seconds: seconds,
                mode: args[flagIndex + 2],
                outputDir: args[flagIndex + 3],
                inputName: args.count > flagIndex + 4 ? args[flagIndex + 4] : nil
            ))
        }
        MeetWhisperApp.main()
    }
}

struct MeetWhisperApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Emoji keeps its color in the menu bar (SF Symbols get templated),
        // which doubles as a state indicator you can read at a glance.
        Text(emoji)
    }

    private var emoji: String {
        switch state.phase {
        case .recording: "🔴"
        case .processing: "⏳"
        case .error: "⚠️"
        case .idle, .done: "🎙️"
        }
    }
}

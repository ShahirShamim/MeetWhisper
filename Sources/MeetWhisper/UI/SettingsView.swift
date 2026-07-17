import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Save recordings to") {
                    HStack(spacing: 8) {
                        Text(abbreviatedPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Keep raw audio files", isOn: $settings.keepRawAudio)
                Text("mic.wav and system.wav. When off, they are deleted after a successful transcription — retrying that transcription later becomes impossible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Naming") {
                TextField("Folder name template", text: $settings.sessionNameTemplate)
                    .textFieldStyle(.roundedBorder)
                Text("Tokens: \(SettingsStore.templateTokens.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Preview") {
                    Text(SettingsStore.renderSessionName(
                        template: settings.sessionNameTemplate,
                        date: Date()
                    ))
                    .foregroundStyle(.secondary)
                }
                Button("Reset to defaults") {
                    settings.sessionNameTemplate = SettingsStore.defaultNameTemplate
                    settings.outputRootPath = SettingsStore.defaultRootPath
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var abbreviatedPath: String {
        (settings.outputRootPath as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputRootURL
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputRootPath = url.path
        }
    }
}

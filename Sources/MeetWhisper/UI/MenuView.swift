import SwiftUI

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            phaseView
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            Divider()

            sessionList
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("🎙️")
            Text("MeetWhisper")
                .font(.headline)
            Spacer()
            Text(phaseCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var phaseCaption: String {
        switch state.phase {
        case .idle: "ready"
        case .recording: "recording"
        case .processing: "transcribing"
        case .done: "done"
        case .error: "error"
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch state.phase {
        case .idle:
            Button(action: state.startRecording) {
                Label("Record Meeting", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut("r")

        case let .recording(startedAt):
            HStack(spacing: 10) {
                PulsingDot()
                Text(startedAt, style: .timer)
                    .font(.system(.title2, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                Spacer()
                Button {
                    state.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("s")
            }
            .padding(.vertical, 2)

        case let .processing(completed, total):
            VStack(alignment: .leading, spacing: 6) {
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                    Text("Transcribing chunk \(completed) of \(total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Detecting speech segments…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case let .done(session):
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcript ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                if state.micSilentWarning {
                    Text("Mic track recorded pure silence — only other participants were transcribed. Check System Settings → Privacy & Security → Microphone.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        state.openTranscript(session)
                    } label: {
                        Label("Open", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        state.copyTranscript(session)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        state.revealInFinder(session)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show in Finder")
                    Spacer()
                    Button {
                        state.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                .controlSize(.small)
            }

        case let .error(message, session):
            VStack(alignment: .leading, spacing: 8) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let session, session.hasAudio {
                        Button {
                            state.transcribe(session)
                        } label: {
                            Label("Retry Transcription", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Dismiss") { state.dismiss() }
                }
                .controlSize(.small)
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            if state.sessions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "tray")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text("No recordings yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            ForEach(state.sessions.prefix(5)) { session in
                SessionRow(session: session, state: state)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button {
                state.openTranscriptsFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open transcripts folder")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .simultaneousGesture(TapGesture().onEnded {
                // LSUIElement app: bring the settings window to the front.
                NSApp.activate(ignoringOtherApps: true)
            })

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit MeetWhisper")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.system(size: 13))
    }
}

private struct PulsingDot: View {
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(dimmed ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

private struct SessionRow: View {
    let session: Session
    @ObservedObject var state: AppState
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(friendlyDate)
                    .font(.callout)
                if let duration = session.duration {
                    Text(TranscriptBuilder.timestamp(duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var actions: some View {
        switch session.status {
        case .done:
            HStack(spacing: 10) {
                Button {
                    state.openTranscript(session)
                } label: {
                    Image(systemName: "doc.text")
                }
                .help("Open transcript")
                Button {
                    state.copyTranscript(session)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .help("Copy transcript")
                Button {
                    state.revealInFinder(session)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        case .failed, .recorded:
            if session.hasAudio {
                Button {
                    state.transcribe(session)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Retry transcription")
            }
        default:
            EmptyView()
        }
    }

    private var friendlyDate: String {
        let calendar = Calendar.current
        let time = session.startedAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(session.startedAt) {
            return "Today \(time)"
        }
        if calendar.isDateInYesterday(session.startedAt) {
            return "Yesterday \(time)"
        }
        let day = session.startedAt.formatted(.dateTime.day().month(.abbreviated))
        return "\(day), \(time)"
    }

    private var statusIcon: String {
        switch session.status {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .transcribing: "arrow.triangle.2.circlepath"
        case .recording, .recorded: "waveform"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .done: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

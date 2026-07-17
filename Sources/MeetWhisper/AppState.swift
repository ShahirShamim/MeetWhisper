import AVFoundation
import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case idle
        case recording(startedAt: Date)
        case processing(completed: Int, total: Int)
        case done(Session)
        case error(String, Session?)
    }

    @Published var phase: Phase = .idle
    @Published var sessions: [Session] = []
    @Published var micSilentWarning = false

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let pipeline = TranscriptionPipeline()
    private var currentSession: Session?
    private var cancellables = Set<AnyCancellable>()

    init() {
        refreshSessions()
        SettingsStore.shared.$outputRootPath
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSessions() }
            .store(in: &cancellables)
    }

    func refreshSessions() {
        sessions = SessionStore.loadAll()
    }

    func startRecording() {
        micSilentWarning = false
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                phase = .error(
                    "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.",
                    nil
                )
                return
            }
            do {
                var session = try SessionStore.newSession()
                currentSession = session
                do {
                    try mic.start(writingTo: session.micURL)
                    try system.start(writingTo: session.systemURL)
                } catch {
                    mic.stop()
                    system.stop()
                    session.status = .failed
                    session.errorMessage = error.localizedDescription
                    try? SessionStore.save(session)
                    throw error
                }
                phase = .recording(startedAt: session.startedAt)
            } catch {
                phase = .error("Could not start recording: \(error.localizedDescription)", nil)
            }
        }
    }

    func stopRecording() {
        guard var session = currentSession else {
            phase = .idle
            return
        }
        mic.stop()
        system.stop()
        micSilentWarning = mic.lastPeakDB <= -120
        session.duration = Date().timeIntervalSince(session.startedAt)
        session.status = .recorded
        try? SessionStore.save(session)
        currentSession = nil
        transcribe(session)
    }

    func transcribe(_ session: Session) {
        var session = session
        phase = .processing(completed: 0, total: 0)
        session.status = .transcribing
        session.errorMessage = nil
        try? SessionStore.save(session)
        refreshSessions()

        Task {
            do {
                _ = try await pipeline.run(session: session) { progress in
                    Task { @MainActor in
                        self.phase = .processing(completed: progress.completed, total: progress.total)
                    }
                }
                session.status = .done
                try? SessionStore.save(session)
                if !SettingsStore.shared.keepRawAudio {
                    try? FileManager.default.removeItem(at: session.micURL)
                    try? FileManager.default.removeItem(at: session.systemURL)
                }
                phase = .done(session)
            } catch {
                session.status = .failed
                session.errorMessage = error.localizedDescription
                try? SessionStore.save(session)
                phase = .error(error.localizedDescription, session)
            }
            refreshSessions()
        }
    }

    func dismiss() {
        phase = .idle
    }

    // MARK: - Session actions

    func openTranscript(_ session: Session) {
        NSWorkspace.shared.open(session.transcriptURL)
    }

    func revealInFinder(_ session: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([session.folderURL])
    }

    func copyTranscript(_ session: Session) {
        guard let text = try? String(contentsOf: session.transcriptURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openTranscriptsFolder() {
        NSWorkspace.shared.open(SessionStore.rootURL)
    }
}

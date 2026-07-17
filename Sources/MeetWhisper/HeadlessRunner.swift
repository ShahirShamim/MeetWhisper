import AVFoundation
import Foundation

/// Headless pipeline test: `MeetWhisper --test-pipeline <me.wav> <them.wav>`
/// Creates a session from two prerecorded tracks and runs the full VAD →
/// TypeWhisper → transcript pipeline. Used for end-to-end verification
/// without touching the recording layer or the UI.
enum HeadlessRunner {
    static func runTestPipeline(micPath: String, systemPath: String) -> Int32 {
        var exitCode: Int32 = 1
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            defer { semaphore.signal() }
            do {
                var session = try SessionStore.newSession()
                let fm = FileManager.default
                try fm.copyItem(at: URL(fileURLWithPath: micPath), to: session.micURL)
                try fm.copyItem(at: URL(fileURLWithPath: systemPath), to: session.systemURL)
                session.duration = max(
                    wavDuration(session.micURL) ?? 0,
                    wavDuration(session.systemURL) ?? 0
                )
                session.status = .recorded
                try SessionStore.save(session)

                let pipeline = TranscriptionPipeline()
                let transcriptURL = try await pipeline.run(session: session) { progress in
                    print("chunk \(progress.completed)/\(progress.total)")
                }
                session.status = .done
                try SessionStore.save(session)

                print("Transcript: \(transcriptURL.path)")
                print("----")
                print(try String(contentsOf: transcriptURL, encoding: .utf8))
                exitCode = 0
            } catch {
                print("FAILED: \(error.localizedDescription)")
            }
        }

        semaphore.wait()
        return exitCode
    }

    /// `MeetWhisper --test-record <seconds> <raw|vp> <outputDir> [inputDeviceNameSubstring]`
    /// Records mic + system audio headlessly and reports TCC state, devices, and
    /// each track's peak/RMS. Also writes the report to <outputDir>/test-report.txt
    /// because launching via `open` swallows stdout.
    static func runTestRecord(seconds: Int, mode: String, outputDir: String, inputName: String?) -> Int32 {
        var report: [String] = []
        func log(_ line: String) {
            print(line)
            report.append(line)
        }
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? report.joined(separator: "\n")
                .write(to: dir.appendingPathComponent("test-report.txt"), atomically: true, encoding: .utf8)
        }

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        log("mic TCC status: \(auth.rawValue) (\(["notDetermined", "restricted", "denied", "authorized"][Int(auth.rawValue)]))")

        // Block until the mic permission dialog is answered, so the measured
        // window never overlaps with the user still clicking prompts.
        let promptSemaphore = DispatchSemaphore(value: 0)
        var micGranted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            micGranted = granted
            promptSemaphore.signal()
        }
        promptSemaphore.wait()
        log("mic access granted: \(micGranted)")

        let devices = AudioInputDevices.all()
        let defaultID = AudioInputDevices.defaultInputID()
        for device in devices {
            log("input device: [\(device.id)] \(device.name)\(device.id == defaultID ? "  (default)" : "")")
        }

        var chosenID: AudioDeviceID?
        if let inputName {
            guard let match = devices.first(where: { $0.name.localizedCaseInsensitiveContains(inputName) }) else {
                log("NO INPUT DEVICE MATCHING '\(inputName)'")
                return 1
            }
            chosenID = match.id
            log("using input device: \(match.name)")
        }

        let micURL = dir.appendingPathComponent("test-mic.wav")
        let systemURL = dir.appendingPathComponent("test-system.wav")
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        let mic = MicRecorder()
        let system = SystemAudioRecorder()
        do {
            try mic.start(writingTo: micURL, useVoiceProcessing: mode == "vp", inputDeviceID: chosenID)
        } catch {
            log("MIC START FAILED: \(error.localizedDescription)")
            return 1
        }
        do {
            try system.start(writingTo: systemURL)
        } catch {
            log("SYSTEM START FAILED (continuing with mic only): \(error.localizedDescription)")
        }

        // The system-audio permission prompt fires on tap creation and cannot be
        // awaited; give the user time to accept it before the measured window.
        let graceSeconds = 10
        log("grace period \(graceSeconds)s for permission prompts — accept them now…")
        Thread.sleep(forTimeInterval: TimeInterval(graceSeconds))
        log("recording \(seconds)s (mode: \(mode), voice processing: \(mic.isVoiceProcessingEnabled))…")
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        mic.stop()
        system.stop()

        for (label, url) in [("mic", micURL), ("system", systemURL)] {
            if let stats = levelStats(url, tailSeconds: seconds) {
                log("\(label): peak \(String(format: "%.1f", stats.peakDB)) dB, rms \(String(format: "%.1f", stats.rmsDB)) dB\(stats.peakDB <= -120 ? "  << SILENT" : "")")
            } else {
                log("\(label): no file / unreadable")
            }
        }
        return 0
    }

    private static func levelStats(_ url: URL, tailSeconds: Int = 120) -> (peakDB: Float, rmsDB: Float)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let tailFrames = AVAudioFramePosition(file.processingFormat.sampleRate * Double(tailSeconds))
        file.framePosition = max(0, file.length - tailFrames)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(file.length, tailFrames))
        ) else { return nil }
        try? file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var peak: Float = 0
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            let v = abs(data[i])
            peak = max(peak, v)
            sum += v * v
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return (20 * log10(max(peak, 1e-9)), 20 * log10(max(rms, 1e-9)))
    }

    private static func wavDuration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return TimeInterval(file.length) / file.processingFormat.sampleRate
    }
}

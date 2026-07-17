import AVFoundation
import AudioToolbox
import CoreAudio

/// Records the user's microphone to a 16 kHz mono WAV via AVAudioEngine.
///
/// Voice processing (echo cancellation) is unusable via AVAudioEngine on this
/// setup: input-only VP gates the mic to digital silence (no far-end reference),
/// and adding any output render path fails engine start with -10875. Verified
/// empirically on macOS 26 / MacBook Air (3-ch mic). Speaker bleed is instead
/// handled by the transcript dedupe pass; a direct VPIO AudioUnit is the future
/// fix if real AEC is wanted.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var writer: WavWriter?
    private(set) var isVoiceProcessingEnabled = false
    private(set) var lastPeakDB: Float = -180

    func start(
        writingTo url: URL,
        useVoiceProcessing: Bool = false,
        inputDeviceID: AudioDeviceID? = nil
    ) throws {
        let input = engine.inputNode
        if let inputDeviceID, let audioUnit = input.audioUnit {
            var deviceID = inputDeviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioError.osStatus("Select input device", status)
            }
        }
        if useVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                try? engine.outputNode.setVoiceProcessingEnabled(true)
                isVoiceProcessingEnabled = true
                // Don't attenuate the meeting audio while the user speaks — the
                // system track still needs to hear it at full volume.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                isVoiceProcessingEnabled = false
            }
        }

        let writer = try WavWriter(url: url)
        self.writer = writer

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.osStatus("Microphone input format unavailable", -1)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.writer?.append(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lastPeakDB = writer?.peakDB ?? -180
        writer?.finish()
        writer = nil
    }
}

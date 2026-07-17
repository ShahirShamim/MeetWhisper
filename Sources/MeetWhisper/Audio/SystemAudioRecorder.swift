import AVFoundation
import CoreAudio
import Foundation

enum AudioError: LocalizedError {
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .osStatus(operation, code):
            return "\(operation) failed (OSStatus \(code))"
        }
    }
}

/// Records everything the system plays (the meeting audio) to a 16 kHz mono WAV,
/// using a Core Audio process tap (macOS 14.4+). No virtual audio driver required.
///
/// Flow: global process tap → private aggregate device containing the tap →
/// IOProc pulls tap buffers → WavWriter converts/appends.
/// First use triggers the "System Audio Recording" permission prompt.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: WavWriter?
    private var tapFormat: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "com.shahir.meetwhisper.system-audio")

    func start(writingTo url: URL) throws {
        writer = try WavWriter(url: url)

        // Tap the mixed output of every process. Private: not visible as a device.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "MeetWhisper system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            cleanup()
            throw AudioError.osStatus("AudioHardwareCreateProcessTap", status)
        }
        tapID = newTapID

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw AudioError.osStatus("Get tap stream format", status)
        }
        tapFormat = format

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetWhisper Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.shahir.meetwhisper.aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [Any](),
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanup()
            throw AudioError.osStatus("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = newAggregateID

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(bufferList: inInputData)
        }
        guard status == noErr, ioProcID != nil else {
            cleanup()
            throw AudioError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            throw AudioError.osStatus("AudioDeviceStart", status)
        }
    }

    func stop() {
        cleanup()
        // Drain any in-flight IO block before finalizing the file.
        ioQueue.sync {}
        writer?.finish()
        writer = nil
    }

    private func handle(bufferList: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let writer else { return }
        let mutableList = UnsafeMutablePointer(mutating: bufferList)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: mutableList,
            deallocator: nil
        ) else { return }
        try? writer.append(buffer)
    }

    private func cleanup() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapFormat = nil
    }
}

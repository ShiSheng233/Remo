import AVFAudio
import Foundation

/// Optional per-session recordings. PCM is interleaved float32, with format and frame offsets in the CSV.
final class AudioPCMTrace: Sendable {
    private let pcm: FileHandle
    private let index: FileHandle
    private let writer = DispatchQueue(label: "RemoEngine.PCMTrace", qos: .utility)
    private let slots = DispatchSemaphore(value: 96)

    static func open(_ stage: String, in directory: URL?) -> AudioPCMTrace? {
        guard let directory else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = directory.appendingPathComponent("\(stage)-\(UUID().uuidString)")
            return try AudioPCMTrace(base: base)
        } catch {
            NSLog("Cannot open %@ audio diagnostics: %@", stage, error.localizedDescription)
            return nil
        }
    }

    private init(base: URL) throws {
        let dataURL = base.appendingPathExtension("f32le")
        let indexURL = base.appendingPathExtension("csv")
        try Data().write(to: dataURL, options: .withoutOverwriting)
        let header = "hostSeconds,sequence,captureTick,frames,channels,sampleRate,playerFrame,scheduledEnd,callbackDelayMs,kind\n"
        try Data(header.utf8).write(to: indexURL, options: .withoutOverwriting)
        pcm = try FileHandle(forWritingTo: dataURL)
        index = try FileHandle(forWritingTo: indexURL)
        try index.seekToEnd()
    }

    func record(
        _ buffer: AVAudioPCMBuffer, host: UInt64 = mach_absolute_time(), sequence: UInt64? = nil,
        timestamp: Int64? = nil, playerFrame: Int64? = nil, scheduledEnd: Int64? = nil,
        callbackDelay: Double? = nil, kind: String
    ) {
        guard let samples = buffer.floatChannelData else { return }
        // Never wait for disk I/O on the capture, playback or render callback.
        guard slots.wait(timeout: .now()) == .success else {
            NSLog("Audio diagnostic writer overrun (%@)", kind)
            return
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        var bytes = Data(count: frames * channels * MemoryLayout<Float>.size)
        bytes.withUnsafeMutableBytes { storage in
            let dest = storage.bindMemory(to: Float.self)
            if buffer.format.isInterleaved {
                dest.baseAddress?.update(from: samples[0], count: dest.count)
            } else {
                for ch in 0..<channels {
                    for i in 0..<frames { dest[i * channels + ch] = samples[ch][i] }
                }
            }
        }
        let block = bytes
        writer.async { [self] in
            defer { slots.signal() }
            let fields: [String] = [
                String(AVAudioTime.seconds(forHostTime: host)), sequence.map { String($0) } ?? "",
                timestamp.map { String($0) } ?? "", String(frames), String(channels), String(rate),
                playerFrame.map { String($0) } ?? "", scheduledEnd.map { String($0) } ?? "",
                callbackDelay.map { String($0) } ?? "", kind,
            ]
            do {
                try pcm.write(contentsOf: block)
                try index.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
            } catch { NSLog("Audio diagnostic write failed: %@", error.localizedDescription) }
        }
    }
}

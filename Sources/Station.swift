//
//  Station.swift
//  One capture station = one headset = one UxPlay receiver.
//

import Foundation

@MainActor
final class Station: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case projecting
        case recording
        case stopped
        case error(String)
    }

    let id = UUID()
    let index: Int
    @Published var label: String
    @Published private(set) var state: State = .idle
    @Published private(set) var outputFile: URL?

    private let proc = UxPlayProcess()
    private struct ClipInterval {
        let start: Date
        let stop: Date
    }

    private var stagingBase: URL?
    private var destinationBase: URL?
    private var errorHandler: ((String) -> Void)?
    private var recordStartDate: Date?
    private var clipIntervals: [ClipInterval] = []

    var airplayName: String { "StudyCast-\(index + 1)" }
    var basePort: Int { 35000 + index * 10 }
    var mac: String { String(format: "02:00:00:00:00:%02X", index + 1) }

    init(index: Int, label: String) {
        self.index = index
        self.label = label
    }

    func startProjection(uxplayPath: String,
                         stagingBase: URL,
                         destinationBase: URL,
                         onError: @escaping (String) -> Void) {
        do {
            self.stagingBase = stagingBase
            self.destinationBase = destinationBase
            self.errorHandler = onError
            recordStartDate = nil
            clipIntervals = []
            outputFile = nil
            try proc.start(uxplayPath: uxplayPath,
                           name: airplayName,
                           basePort: basePort,
                           mac: mac,
                           mp4Base: stagingBase)
            state = .projecting
        } catch {
            state = .error(error.localizedDescription)
            onError("\(label): 投屏接收端启动失败 — \(error.localizedDescription)")
        }
    }

    func startRecording() {
        guard recordStartDate == nil else { return }
        recordStartDate = Date()
        state = .recording
    }

    func stopRecording() {
        guard let recordStartDate else { return }
        clipIntervals.append(ClipInterval(start: recordStartDate, stop: Date()))
        self.recordStartDate = nil
        state = .projecting
    }

    func stopReceiver() async {
        if recordStartDate != nil {
            stopRecording()
        }
        await proc.stopProjection()
    }

    /// Finalizes UxPlay's continuous master MP4, then creates user-requested
    /// recording clips by trimming/re-encoding from the master. The recording
    /// button only marks intervals, so projection stays live until this stop.
    func finalizeProjectionOutput() {
        do {
            outputFile = try finalizeMasterAndClips()
            try moveLog()
            state = .stopped
        } catch {
            state = .error(error.localizedDescription)
            errorHandler?("\(label): 停止投屏时保存失败 — \(error.localizedDescription)")
        }
        clearSessionState()
    }

    private func finalizeMasterAndClips() throws -> URL? {
        guard let master = try moveMasterToDestination() else { return nil }
        guard let destinationBase else { return master }

        guard !clipIntervals.isEmpty else {
            return master
        }

        let masterStart = (try? master.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? (try? master.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? clipIntervals[0].start

        var lastOutput: URL?
        for (idx, interval) in clipIntervals.enumerated() {
            let output: URL
            if clipIntervals.count == 1 {
                output = URL(fileURLWithPath: destinationBase.path + ".mp4")
            } else {
                output = URL(fileURLWithPath: "\(destinationBase.path)_clip\(idx + 1).mp4")
            }

            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }

            let offset = max(0, interval.start.timeIntervalSince(masterStart))
            let duration = max(0.25, interval.stop.timeIntervalSince(interval.start))
            try runFFmpegTrim(input: master, output: output, offset: offset, duration: duration)
            lastOutput = output
        }

        return lastOutput
    }

    private func moveMasterToDestination() throws -> URL? {
        guard let stagingBase, let destinationBase else { return nil }

        let fm = FileManager.default
        let stagingDir = stagingBase.deletingLastPathComponent()
        let stagingPrefix = stagingBase.lastPathComponent + "."
        guard fm.fileExists(atPath: stagingDir.path) else { return nil }

        let candidates = try fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix(stagingPrefix)
                && url.pathExtension.lowercased() == "mp4"
        }
        .sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        guard let recorded = candidates.first else { return nil }

        let suffix = String(recorded.lastPathComponent.dropFirst(stagingBase.lastPathComponent.count))
        let masterURL = destinationBase.deletingLastPathComponent()
            .appendingPathComponent(destinationBase.lastPathComponent + ".master" + suffix)

        if fm.fileExists(atPath: masterURL.path) {
            try fm.removeItem(at: masterURL)
        }
        try fm.moveItem(at: recorded, to: masterURL)
        return masterURL
    }

    private func runFFmpegTrim(input: URL, output: URL, offset: TimeInterval, duration: TimeInterval) throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw StudyCastError("找不到 ffmpeg: \(ffmpeg)")
        }

        let start = String(format: "%.3f", offset)
        let length = String(format: "%.3f", duration)
        let audioHasPackets = hasAudioPackets(input: input)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)

        if audioHasPackets {
            p.arguments = [
                "-y",
                "-i", input.path,
                "-filter_complex",
                "[0:v:0]trim=start=\(start):duration=\(length),setpts=PTS-STARTPTS[v];[0:a:0]asetpts=N/SR/TB,atrim=start=\(start):duration=\(length),asetpts=PTS-STARTPTS[a]",
                "-map", "[v]",
                "-map", "[a]",
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-crf", "18",
                "-c:a", "aac",
                "-ar", "44100",
                "-ac", "2",
                "-movflags", "+faststart",
                output.path,
            ]
        } else {
            p.arguments = [
                "-y",
                "-i", input.path,
                "-filter_complex",
                "[0:v:0]trim=start=\(start):duration=\(length),setpts=PTS-STARTPTS[v]",
                "-map", "[v]",
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-crf", "18",
                "-movflags", "+faststart",
                output.path,
            ]
        }

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "ffmpeg failed"
            throw StudyCastError(message)
        }
    }

    private func hasAudioPackets(input: URL) -> Bool {
        let ffprobe = "/opt/homebrew/bin/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            return false
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = [
            "-v", "error",
            "-count_packets",
            "-select_streams", "a:0",
            "-show_entries", "stream=nb_read_packets",
            "-of", "default=noprint_wrappers=1:nokey=1",
            input.path,
        ]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return false
        }

        guard p.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return Int(output).map { $0 > 0 } ?? false
    }

    private func moveLog() throws {
        guard let stagingBase, let destinationBase else { return }

        let fm = FileManager.default
        let stagingLog = URL(fileURLWithPath: stagingBase.path + ".uxplay.log")
        guard fm.fileExists(atPath: stagingLog.path) else { return }

        let finalLog = destinationBase.deletingLastPathComponent()
            .appendingPathComponent(destinationBase.lastPathComponent + ".uxplay.log")
        if fm.fileExists(atPath: finalLog.path) {
            try fm.removeItem(at: finalLog)
        }
        try fm.moveItem(at: stagingLog, to: finalLog)
    }

    private func clearSessionState() {
        stagingBase = nil
        destinationBase = nil
        errorHandler = nil
        recordStartDate = nil
        clipIntervals = []
    }
}

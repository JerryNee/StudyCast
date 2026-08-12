//
//  Station.swift
//  One capture station = one AirPlay-capable device = one UxPlay receiver.
//

import Foundation

@MainActor
final class Station: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case projecting
        case recording
        case stopped
        /// The receiver helper died while projection was still running. Kept
        /// separate from `error` because it is recoverable: this one station
        /// can be restarted without disturbing the others.
        case receiverDied
        case error(String)
    }

    let id = UUID()
    let index: Int
    let preview = StationMediaPreviewModel()
    @Published var label: String
    @Published var selectedAudioOutputUID: String {
        didSet {
            guard oldValue != selectedAudioOutputUID else { return }
            UserDefaults.standard.set(selectedAudioOutputUID, forKey: Self.audioOutputDefaultsKey(index: index))
            applySelectedAudioOutput()
        }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var outputFile: URL?

    private let proc = UxPlayProcess()
    private weak var audioOutputManager: AudioOutputManager?
    private struct ClipInterval {
        let start: Date
        let stop: Date
    }

    /// Slack allowed when deciding whether a marked interval predates the
    /// segment being trimmed. Filesystem creation dates are coarse, so an
    /// interval marked at the very start of a segment can read as slightly
    /// earlier than the file itself.
    private static let segmentBoundaryTolerance: TimeInterval = 0.5

    private var stagingBase: URL?
    private var destinationBase: URL?
    private var launchSettings: LaunchSettings?

    private struct LaunchSettings {
        let uxplayPath: String
        let useMacWireIdentity: Bool
    }
    private var errorHandler: ((String) -> Void)?
    private var recordStartDate: Date?
    private var clipIntervals: [ClipInterval] = []

    var airplayName: String { "StudyCast-\(index + 1)" }
    var basePort: Int { 35000 + index * 10 }
    var mac: String { String(format: "02:00:00:00:00:%02X", index + 1) }
    var mediaPorts: StationMediaPorts { StationMediaPorts(stationIndex: index) }

    /// AirPlay pairing code the sender is asked for.
    ///
    /// UxPlay only turns on feature bit 27 ("supports legacy pairing") when a
    /// PIN is configured, and that bit is part of what makes senders offer the
    /// receiver over Apple peer-to-peer. One memorable code per station also
    /// keeps a room full of senders from casting to the wrong screen.
    var pairingPIN: String { String(repeating: "\(index + 1)", count: 4) }

    init(index: Int, label: String, audioOutputManager: AudioOutputManager) {
        self.index = index
        self.label = label
        self.audioOutputManager = audioOutputManager
        selectedAudioOutputUID = UserDefaults.standard.string(
            forKey: Self.audioOutputDefaultsKey(index: index)
        ) ?? AudioOutputDevice.systemDefaultUID
    }

    func startProjection(uxplayPath: String,
                         useMacWireIdentity: Bool,
                         stagingBase: URL,
                         destinationBase: URL,
                         onError: @escaping (String) -> Void) {
        self.stagingBase = stagingBase
        self.destinationBase = destinationBase
        self.errorHandler = onError
        self.launchSettings = LaunchSettings(uxplayPath: uxplayPath,
                                             useMacWireIdentity: useMacWireIdentity)
        recordStartDate = nil
        clipIntervals = []
        outputFile = nil
        preview.start(ports: mediaPorts, audioOutputDeviceID: resolvedSelectedAudioOutputDeviceID)
        launchReceiver(isRestart: false)
    }

    /// Relaunches this station's receiver after it died, leaving the other
    /// stations and this station's recording state alone.
    func restartReceiver() {
        guard state == .receiverDied else { return }
        launchReceiver(isRestart: true)
    }

    private func launchReceiver(isRestart: Bool) {
        guard let stagingBase, let launchSettings else { return }
        do {
            try proc.start(uxplayPath: launchSettings.uxplayPath,
                           name: airplayName,
                           basePort: basePort,
                           mac: mac,
                           pairingPIN: pairingPIN,
                           useMacWireIdentity: launchSettings.useMacWireIdentity,
                           mediaPorts: mediaPorts,
                           mp4Base: stagingBase,
                           onStreamingChanged: { [weak self] streaming in
                               guard let self, !streaming else { return }
                               self.preview.clearFrame()
                           },
                           onUnexpectedExit: { [weak self] status in
                               self?.handleReceiverDeath(status: status)
                           })
            // A restart keeps any recording intervals already marked; UxPlay
            // starts a new numbered segment, and every segment is preserved.
            state = recordStartDate == nil ? .projecting : .recording
        } catch {
            if !isRestart {
                preview.stop()
            }
            state = .error(error.localizedDescription)
            errorHandler?("\(label): 投屏接收端启动失败 — \(error.localizedDescription)")
        }
    }

    private func handleReceiverDeath(status: Int32) {
        guard state != .stopped, state != .idle else { return }
        preview.clearFrame()

        // Close any open interval at the moment of death, so no marked interval
        // straddles two segments. Restarting makes UxPlay begin a new segment,
        // and an interval spanning the boundary cannot be trimmed from either.
        // Recording does not resume by itself: the operator restarts the
        // receiver, then presses record again if they still want it.
        let wasRecording = recordStartDate != nil
        if wasRecording {
            stopRecording()
        }

        state = .receiverDied
        let suffix = wasRecording
            ? "，录制已在该点停止（已标记的区间已保存），重启后需要重新开始录制"
            : ""
        errorHandler?("\(label): 接收端意外退出（状态 \(status)），可在该工位上重启\(suffix)")
    }

    func applySelectedAudioOutput() {
        preview.setAudioOutputDeviceID(resolvedSelectedAudioOutputDeviceID)
    }

    func isSelectedAudioOutputUnavailable(using manager: AudioOutputManager) -> Bool {
        selectedAudioOutputUID != AudioOutputDevice.systemDefaultUID
            && !manager.isAvailable(uid: selectedAudioOutputUID)
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
        preview.stop()
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
        let segments = try moveMasterToDestination()
        guard let newest = segments.last?.url else { return nil }
        guard let destinationBase else { return newest }

        guard !clipIntervals.isEmpty else {
            return newest
        }

        let tolerance = Station.segmentBoundaryTolerance
        var lastOutput: URL?
        var orphaned: [Int] = []

        for (idx, interval) in clipIntervals.enumerated() {
            // Each interval is trimmed from the segment it was marked during,
            // not from the newest one. A projection run produces a segment per
            // sender connection, so an interval marked before a receiver
            // restart or a sender reconnect lives in an earlier file; offsets
            // computed against the newest segment would cut unrelated footage.
            //
            // Matching on the interval's start is deliberate. An interval is
            // closed when its segment ends, so its start is the point that
            // reliably identifies which segment it belongs to.
            guard let segment = segments.last(where: {
                $0.covers(interval.start, tolerance: tolerance)
            }) else {
                orphaned.append(idx + 1)
                continue
            }

            let output: URL
            if clipIntervals.count == 1 {
                output = URL(fileURLWithPath: destinationBase.path + ".mp4")
            } else {
                output = URL(fileURLWithPath: "\(destinationBase.path)_clip\(idx + 1).mp4")
            }

            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }

            let offset = max(0, interval.start.timeIntervalSince(segment.start))
            // Never ask ffmpeg for footage past the end of this segment: an
            // interval left open when a receiver died is closed at the moment
            // of death, but a coarse timestamp can still put its stop marginally
            // beyond the file.
            let stop = min(interval.stop, segment.end)
            let duration = max(0.25, stop.timeIntervalSince(interval.start))
            try runFFmpegTrim(input: segment.url, output: output, offset: offset, duration: duration)
            lastOutput = output
        }

        if !orphaned.isEmpty {
            let list = orphaned.map(String.init).joined(separator: "、")
            errorHandler?("""
            \(label): 第 \(list) 段标记找不到对应的录像片段，未生成剪辑。
            所有片段都已保留为 `.master*` 文件，可手动裁剪。
            """)
        }

        return lastOutput
    }

    /// One continuous MP4 written by UxPlay, with the wall-clock window it
    /// covers. A projection run yields one per sender connection.
    private struct MasterSegment {
        let url: URL
        let start: Date
        let end: Date

        /// Whether an interval marked at `date` belongs to this segment.
        /// `tolerance` absorbs the coarseness of filesystem timestamps.
        func covers(_ date: Date, tolerance: TimeInterval) -> Bool {
            date >= start - tolerance && date <= end + tolerance
        }
    }

    private func moveMasterToDestination() throws -> [MasterSegment] {
        guard let stagingBase, let destinationBase else { return [] }

        let fm = FileManager.default
        let stagingDir = stagingBase.deletingLastPathComponent()
        let stagingPrefix = stagingBase.lastPathComponent + "."
        guard fm.fileExists(atPath: stagingDir.path) else { return [] }

        let candidates = try fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix(stagingPrefix)
                && url.pathExtension.lowercased() == "mp4"
        }

        // UxPlay starts a new numbered MP4 every time a sender connects, so a
        // single projection run produces one segment per cast. Keep them all:
        // taking only the newest silently discarded everything recorded before
        // a sender dropped and reconnected. The staging name already carries
        // the segment number, so the destination names stay distinct.
        //
        // The window each segment covers is read here, before the move, and
        // carried alongside the destination URL. A segment's creation date is
        // when UxPlay opened the file and its modification date is when it
        // stopped writing, which is exactly the wall-clock span the footage
        // covers -- that is what lets a marked interval be matched to the
        // segment it was actually marked during.
        var moved: [MasterSegment] = []
        for recorded in candidates {
            let values = try? recorded.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey])
            let start = values?.creationDate
                ?? values?.contentModificationDate
                ?? .distantPast
            let end = values?.contentModificationDate ?? .distantFuture

            let suffix = String(
                recorded.lastPathComponent.dropFirst(stagingBase.lastPathComponent.count))
            let masterURL = destinationBase.deletingLastPathComponent()
                .appendingPathComponent(destinationBase.lastPathComponent + ".master" + suffix)

            if fm.fileExists(atPath: masterURL.path) {
                try fm.removeItem(at: masterURL)
            }
            try fm.moveItem(at: recorded, to: masterURL)
            moved.append(MasterSegment(url: masterURL, start: start, end: max(start, end)))
        }

        return moved.sorted { $0.start < $1.start }
    }

    private func runFFmpegTrim(input: URL, output: URL, offset: TimeInterval, duration: TimeInterval) throws {
        guard let ffmpeg = RuntimePaths.executable(
            bundledName: "ffmpeg",
            environmentKey: "FFMPEG_PATH",
            fallbackNames: ["ffmpeg"]
        ) else {
            throw StudyCastError("找不到 ffmpeg。Release builds expect bundled ffmpeg; source builds can set FFMPEG_PATH.")
        }

        let start = String(format: "%.3f", offset)
        let length = String(format: "%.3f", duration)
        let audioHasPackets = hasAudioPackets(input: input)

        let p = Process()
        p.executableURL = ffmpeg
        p.environment = processEnvironment()

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
        guard let ffprobe = RuntimePaths.executable(
            bundledName: "ffprobe",
            environmentKey: "FFPROBE_PATH",
            fallbackNames: ["ffprobe"]
        ) else {
            return false
        }

        let p = Process()
        p.executableURL = ffprobe
        p.environment = processEnvironment()
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
        for suffix in [UxPlayProcess.logSuffix, UxPlayProcess.ap2CaptureSuffix] {
            let staged = URL(fileURLWithPath: stagingBase.path + suffix)
            guard fm.fileExists(atPath: staged.path) else { continue }

            let final = destinationBase.deletingLastPathComponent()
                .appendingPathComponent(destinationBase.lastPathComponent + suffix)
            if fm.fileExists(atPath: final.path) {
                try fm.removeItem(at: final)
            }
            try fm.moveItem(at: staged, to: final)
        }
    }

    private func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = RuntimePaths.pathEnvironment()
        return env
    }

    private func clearSessionState() {
        stagingBase = nil
        destinationBase = nil
        errorHandler = nil
        recordStartDate = nil
        clipIntervals = []
        preview.stop()
    }

    private var resolvedSelectedAudioOutputDeviceID: Int? {
        guard selectedAudioOutputUID != AudioOutputDevice.systemDefaultUID else {
            return 0
        }
        return audioOutputManager?.outputDeviceID(for: selectedAudioOutputUID)
    }

    private static func audioOutputDefaultsKey(index: Int) -> String {
        "StudyCast.station.\(index).audioOutputUID"
    }
}

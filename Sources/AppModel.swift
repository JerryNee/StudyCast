//
//  AppModel.swift
//  Owns station count, output location, projection lifecycle, and recording lifecycle.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var studyName: String = "Study"
    @Published var uxplayPath: String = AppModel.defaultUxplayPath

    /// Where finished recordings land. Change it with `setOutputDirectory`.
    @Published private(set) var outputDirectory: URL = AppModel.defaultOutputDirectory
    @Published var stations: [Station]
    @Published var macWireIdentityEnabled = false
    @Published private(set) var isProjecting = false
    @Published private(set) var isRecording = false
    @Published private(set) var currentSessionDir: URL?
    @Published var lastError: String?
    @Published var lastWarning: String?

    let audioOutputManager: AudioOutputManager

    private var currentStagingDir: URL?

    /// Last-resort helper path, used only when no helper was bundled.
    ///
    /// A stock Homebrew uxplay will run, but it is not the vendored build in
    /// `third_party/UxPlay`, so it cannot be reached over Apple peer-to-peer --
    /// stations fall back to whatever the local network allows. Build the
    /// vendored tree, or point UXPLAY_PATH at a build of it.
    static let defaultUxplayPath = ProcessInfo.processInfo.environment["UXPLAY_PATH"]
        ?? "/opt/homebrew/bin/uxplay"

    /// Whether macOS's own AirPlay Receiver is switched on.
    ///
    /// Stations are published over Apple peer-to-peer, and on macOS 27 that
    /// path only carries an incoming connection while this system setting is
    /// enabled. With it off, a sender still discovers the station and lists it,
    /// but the connection is refused and the helper never sees a single byte --
    /// no `Accepted IPv6 client`, no `Remote:`, nothing. Measured 8/8 success
    /// with it on against 0/3 with it off, same host and sender; `awdl0` stayed
    /// up in both states, so the interface is not what goes away.
    ///
    /// Returns nil when the key has never been written, which is not the same
    /// as "off" -- a machine whose setting was never touched should not be
    /// warned at.
    static var systemAirPlayReceiverEnabled: Bool? {
        let value = CFPreferencesCopyValue("AirplayReceiverEnabled" as CFString,
                                           "com.apple.controlcenter" as CFString,
                                           kCFPreferencesCurrentUser,
                                           kCFPreferencesCurrentHost)
        guard let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// `~/Movies/StudyCast` in whichever account is running the app.
    ///
    /// `.moviesDirectory` resolves per user, so this is a different absolute
    /// path on every machine -- there is nothing machine-specific baked in.
    /// Movies rather than Desktop/Documents/Downloads on purpose: those three
    /// are TCC-protected, and the first write raises a permission dialog, which
    /// on the recording path would land mid-session.
    static var defaultOutputDirectory: URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return movies.appendingPathComponent("StudyCast", isDirectory: true)
    }

    private static let outputDirectoryDefaultsKey = "StudyCast.outputDirectory"

    init() {
        let audioOutputManager = AudioOutputManager()
        self.audioOutputManager = audioOutputManager
        stations = (0..<3).map {
            Station(index: $0, label: "Station \($0 + 1)", audioOutputManager: audioOutputManager)
        }

        let restored = AppModel.restoredOutputDirectory()
        outputDirectory = restored.url
        if let unreachable = restored.unreachablePath {
            lastWarning = """
            上次选择的录制位置当前不可用，已临时改用 \(AppModel.defaultOutputDirectory.path)。
            原位置：\(unreachable)
            （外置磁盘重新接上后会自动恢复，设置未被覆盖。）
            """
        }
    }

    /// Points recordings at `url`, keeping the current location if it is unusable.
    ///
    /// Creates the folder now rather than at Start Projection: the user just
    /// named a place, and a location that turns out to be unwritable should be
    /// reported while they can still pick another one.
    @discardableResult
    func setOutputDirectory(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        } catch {
            lastError = "无法使用该录制位置：\(error.localizedDescription)"
            return false
        }
        guard FileManager.default.isWritableFile(atPath: resolved.path) else {
            lastError = "该录制位置不可写入：\(resolved.path)"
            return false
        }
        outputDirectory = resolved
        UserDefaults.standard.set(resolved.path, forKey: Self.outputDirectoryDefaultsKey)
        lastError = nil
        lastWarning = nil
        return true
    }

    func resetOutputDirectory() {
        setOutputDirectory(AppModel.defaultOutputDirectory)
    }

    var isUsingDefaultOutputDirectory: Bool {
        outputDirectory.standardizedFileURL.path
            == AppModel.defaultOutputDirectory.standardizedFileURL.path
    }

    /// `~/Movies/StudyCast` reads better in a control bar than `/Users/…/Movies/StudyCast`.
    var outputDirectoryDisplayPath: String {
        (outputDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    /// Where this session's files actually land -- two levels below the root
    /// shown in the control bar, which is the part people get wrong.
    var sessionDestinationDescription: String {
        if let currentSessionDir { return currentSessionDir.path }
        return outputDirectory
            .appendingPathComponent(sanitize(studyName), isDirectory: true)
            .appendingPathComponent("<时间戳>", isDirectory: true)
            .path
    }

    /// The remembered location, or the default when it can no longer be reached.
    ///
    /// A path on an external volume outlives the volume in defaults. Recording
    /// into a stub directory that macOS recreates under `/Volumes` is worse
    /// than saying so, so an unreachable parent falls back -- without
    /// overwriting the stored preference, so re-attaching the disk restores it.
    private static func restoredOutputDirectory() -> (url: URL, unreachablePath: String?) {
        guard let path = UserDefaults.standard.string(forKey: outputDirectoryDefaultsKey),
              !path.isEmpty else {
            return (defaultOutputDirectory, nil)
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        // The folder itself may legitimately be missing -- it is recreated at
        // Start Projection -- so an existing parent is enough.
        if isDirectory(url) || isDirectory(url.deletingLastPathComponent()) {
            return (url, nil)
        }
        return (defaultOutputDirectory, path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func setStationCount(_ count: Int) {
        let clamped = max(1, min(count, 8))
        guard clamped != stations.count else { return }
        if clamped < stations.count {
            stations = Array(stations.prefix(clamped))
        } else {
            for i in stations.count..<clamped {
                stations.append(Station(index: i, label: "Station \(i + 1)", audioOutputManager: audioOutputManager))
            }
        }
    }

    func refreshAudioOutputDevices() {
        audioOutputManager.refresh()
        for station in stations {
            station.applySelectedAudioOutput()
        }
    }

    func startProjection() {
        guard !isProjecting else { return }
        lastError = nil
        lastWarning = nil

        if AppModel.systemAirPlayReceiverEnabled == false {
            lastWarning = """
            隔空播放接收器已关闭，工位可能"看得到、连不上"。
            System Settings > General > AirDrop & Handoff > AirPlay Receiver.
            Senders will still discover the stations, but the connection is
            refused and nothing reaches the helper. Projection continues in
            case the sender can reach a station over the local network instead.
            """
        }

        guard UxPlayProcess.canResolveUxPlay(developmentPath: uxplayPath) else {
            lastError = """
            找不到可执行的 uxplay。
            Release builds expect StudyCast.app/Contents/Helpers/uxplay.
            Source builds should build the vendored helper:
              cd third_party/UxPlay && cmake . && make
            or set UXPLAY_PATH to a build of that tree. A stock Homebrew
            uxplay lacks the peer-to-peer changes stations rely on.
            """
            return
        }

        let stamp = AppModel.timestamp()
        let destDir = outputDirectory
            .appendingPathComponent(sanitize(studyName), isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        let stagingDir = AppModel.stagingRoot().appendingPathComponent(stamp, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            lastError = "无法创建输出目录: \(error.localizedDescription)"
            return
        }

        currentSessionDir = destDir
        currentStagingDir = stagingDir

        for station in stations {
            let stagingBase = stagingDir.appendingPathComponent("s\(station.index)")
            let destBase = destDir.appendingPathComponent("\(station.index + 1)_\(sanitize(station.label))")
            station.startProjection(uxplayPath: uxplayPath,
                                    useMacWireIdentity: macWireIdentityEnabled && station.index == 0,
                                    stagingBase: stagingBase,
                                    destinationBase: destBase,
                                    onError: { [weak self] message in
                self?.lastError = message
            })
        }
        isProjecting = stations.contains { station in
            if case .error = station.state { return false }
            return true
        }
    }

    func stopProjection() async {
        guard isProjecting else { return }
        if isRecording {
            stopRecording()
        }
        for station in stations {
            await station.stopReceiver()
        }
        for station in stations {
            station.finalizeProjectionOutput()
        }
        isProjecting = false
        cleanupStagingDir()
    }

    func startRecording() {
        guard isProjecting, !isRecording else { return }
        lastError = nil
        for station in stations {
            station.startRecording()
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        for station in stations {
            station.stopRecording()
        }
        isRecording = false
    }

    func revealOutputInFinder() {
        guard let currentSessionDir else { return revealOutputDirectory() }
        NSWorkspace.shared.activateFileViewerSelecting([currentSessionDir])
    }

    /// Opens the recording root, creating it first if nothing has been recorded
    /// yet: an empty Finder window answers "where do the files go" -- asking
    /// Finder to reveal a folder that does not exist does nothing at all.
    func revealOutputDirectory() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            lastError = "无法打开录制位置：\(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(outputDirectory)
    }

    private func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let mapped = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "Untitled" : mapped
    }

    private func cleanupStagingDir() {
        guard let currentStagingDir else { return }
        try? FileManager.default.removeItem(at: currentStagingDir)
        self.currentStagingDir = nil
    }

    private static func stagingRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StudyCast", isDirectory: true)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}

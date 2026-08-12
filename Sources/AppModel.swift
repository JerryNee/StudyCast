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
    @Published var outputDirectory: URL = AppModel.defaultOutputDirectory
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

    static var defaultOutputDirectory: URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return movies.appendingPathComponent("StudyCast", isDirectory: true)
    }

    init() {
        let audioOutputManager = AudioOutputManager()
        self.audioOutputManager = audioOutputManager
        stations = (0..<3).map {
            Station(index: $0, label: "Station \($0 + 1)", audioOutputManager: audioOutputManager)
        }
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
        let url = currentSessionDir ?? outputDirectory
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

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

    let audioOutputManager: AudioOutputManager

    private var currentStagingDir: URL?

    static let defaultUxplayPath = ProcessInfo.processInfo.environment["UXPLAY_PATH"]
        ?? "/opt/homebrew/bin/uxplay"

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

        guard UxPlayProcess.canResolveUxPlay(developmentPath: uxplayPath) else {
            lastError = """
            找不到可执行的 uxplay。
            Release builds expect StudyCast.app/Contents/Helpers/uxplay.
            Source builds can set UXPLAY_PATH or install uxplay at /opt/homebrew/bin/uxplay.
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

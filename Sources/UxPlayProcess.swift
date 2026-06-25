//
//  UxPlayProcess.swift
//  Thin wrapper around one `uxplay` subprocess.
//
//  Reliable mode: UxPlay records continuously from projection start using
//  its native `-mp4` path. StudyCast later trims the finalized master MP4.
//

import Foundation

@MainActor
final class UxPlayProcess {
    private var process: Process?
    private var logHandle: FileHandle?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(uxplayPath: String,
               name: String,
               basePort: Int,
               mac: String,
               mediaPorts: StationMediaPorts,
               mp4Base: URL) throws {
        guard process == nil else { return }

        let p = Process()
        p.executableURL = try Self.resolveUxPlayURL(developmentPath: uxplayPath)
        p.arguments = [
            "-n", name,
            "-nh",
            "-p", "\(basePort)",
            "-m", mac,
            "-vsync", "no",
            "-vol", "1.0",
            "-vrtp", "pt=96 config-interval=1 ! udpsink host=127.0.0.1 port=\(mediaPorts.videoRTP) sync=false async=false",
            "-artp", "pt=97 ! udpsink host=127.0.0.1 port=\(mediaPorts.audioRTP) sync=false async=false",
            "-mp4", mp4Base.path,
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        Self.configureGStreamerEnvironment(&env)
        p.environment = env

        let logURL = URL(fileURLWithPath: mp4Base.path + ".uxplay.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        p.standardOutput = handle
        p.standardError = handle
        logHandle = handle

        try p.run()
        process = p
    }

    func stopProjection() async {
        guard let p = process else { return }
        p.interrupt()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                p.waitUntilExit()
                cont.resume()
            }
        }
        try? logHandle?.close()
        logHandle = nil
        process = nil
    }

    private static func resolveUxPlayURL(developmentPath: String) throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("uxplay")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        #if DEBUG
        if FileManager.default.isExecutableFile(atPath: developmentPath) {
            return URL(fileURLWithPath: developmentPath)
        }
        #endif

        throw StudyCastError("找不到 bundled uxplay helper: \(bundled.path)")
    }

    private static func configureGStreamerEnvironment(_ env: inout [String: String]) {
        let runtime = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("GStreamer", isDirectory: true)
        let plugins = runtime.appendingPathComponent("plugins", isDirectory: true)
        let scanner = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("gst-plugin-scanner")

        if FileManager.default.fileExists(atPath: plugins.path) {
            env["GST_PLUGIN_PATH"] = plugins.path
            env["GST_PLUGIN_SYSTEM_PATH"] = plugins.path
            let registry = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("StudyCast-gstreamer-helper-registry.bin")
            try? FileManager.default.removeItem(at: registry)
            env["GST_REGISTRY"] = registry.path
            if FileManager.default.isExecutableFile(atPath: scanner.path) {
                env["GST_PLUGIN_SCANNER"] = scanner.path
            }
            env["DYLD_LIBRARY_PATH"] = runtime
                .appendingPathComponent("lib", isDirectory: true)
                .path
        }
        env["GST_DEBUG_NO_COLOR"] = "1"
    }
}

struct StudyCastError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

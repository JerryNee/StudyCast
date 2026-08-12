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
    static let logSuffix = ".uxplay.log"
    static let ap2CaptureSuffix = ".ap2capture"

    /// Research profile for the AP2 media-key investigation, or empty for the
    /// normal configuration.
    ///
    /// Stations are normally published over Apple peer-to-peer with UxPlay's
    /// own advertisement left untouched (the helper's `-p2p` option). That is
    /// what lets a sender reach StudyCast directly, with no managed-network
    /// registration, while still negotiating the legacy FairPlay media setup
    /// UxPlay can decrypt.
    ///
    /// `mac-p2p` instead impersonates a Mac receiver. It also reaches AWDL,
    /// but a Mac identity makes senders switch to the AP2 media path, which
    /// omits the legacy ekey and derives the media key by an unpublished
    /// route -- video then arrives but cannot be decrypted. It exists only to
    /// capture samples; see docs/AP2_MIRRORING_KEY_SEARCH.md.
    static let researchProfile = ProcessInfo.processInfo
        .environment["STUDYCAST_DISCOVERY_PROFILE"] ?? ""

    private var process: Process?
    private var logHandle: FileHandle?
    private var outputPipe: Pipe?
    /// Distinguishes a helper we asked to quit from one that died on its own.
    private var isStopping = false

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(uxplayPath: String,
               name: String,
               basePort: Int,
               mac: String,
               pairingPIN: String,
               useMacWireIdentity: Bool,
               mediaPorts: StationMediaPorts,
               mp4Base: URL,
               onStreamingChanged: @escaping (Bool) -> Void,
               onUnexpectedExit: @escaping (Int32) -> Void) throws {
        guard process == nil else { return }

        let p = Process()
        p.executableURL = try Self.resolveUxPlayURL(developmentPath: uxplayPath)
        // Only the research profile impersonates a Mac receiver. Normally the
        // station keeps its own name, Device ID and ports, so the sender sees
        // a plain UxPlay receiver and negotiates the legacy media setup.
        let usesMacIdentity =
            useMacWireIdentity && Self.researchProfile.hasPrefix("mac")
        // Never reuse the built-in receiver's instance name or Device ID:
        // visionOS merges them and routes the selection to ControlCenter.
        let effectiveName = usesMacIdentity ? "StudyCast-HKP-Probe15" : name
        let effectiveMac = usesMacIdentity ? "02:00:00:00:00:6F" : mac
        var arguments = [
            "-n", effectiveName,
            "-nh",
            // -pin is also what turns on feature bit 27, which senders look
            // at when deciding to offer the receiver over peer-to-peer.
            "-pin", pairingPIN,
            // Publish over Apple peer-to-peer as well as the local network.
            // This is what lets a sender reach StudyCast without the network
            // operator registering the receiver first, and it also opts the
            // listening sockets into accepting AWDL-delivered traffic.
            "-p2p",
        ]
        if usesMacIdentity {
            // The research profiles need the legacy AirPlay ports and verbose
            // logging; only one station can hold them, so they stay opt-in.
            arguments += ["-d", "-p"]
        } else {
            arguments += ["-p", "\(basePort)"]
        }
        arguments += [
            "-m", effectiveMac,
            "-vsync", "no",
            "-vol", "1.0",
            "-vrtp", "pt=96 config-interval=1 ! udpsink host=127.0.0.1 port=\(mediaPorts.videoRTP) sync=false async=false",
            "-artp", "pt=97 ! udpsink host=127.0.0.1 port=\(mediaPorts.audioRTP) sync=false async=false",
            "-mp4", mp4Base.path,
        ]
        p.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = RuntimePaths.pathEnvironment()
        if usesMacIdentity {
            // Research path only: the Mac-identity profile pushes the sender
            // onto the AP2 media setup, which omits the legacy ekey. Dump the
            // session material and first encrypted payloads so
            // scripts/ap2_key_search.py can search for the media key offline.
            env["UXPLAY_DISCOVERY_PROFILE"] = Self.researchProfile
            env["UXPLAY_HKP_MEDIA_KEY_MODE"] = "fairplay"
            env["UXPLAY_AP2_CAPTURE"] = mp4Base.path + Self.ap2CaptureSuffix
        } else {
            env.removeValue(forKey: "UXPLAY_DISCOVERY_PROFILE")
            env.removeValue(forKey: "UXPLAY_HKP_MEDIA_KEY_MODE")
            env.removeValue(forKey: "UXPLAY_AP2_CAPTURE")
        }
        Self.configureGStreamerEnvironment(&env)
        p.environment = env

        let logURL = URL(fileURLWithPath: mp4Base.path + Self.logSuffix)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        logHandle = handle

        // Tee UxPlay's output: it still lands in the session log verbatim, but
        // we also watch it for the mirroring stream's start/stop lines. Frames
        // simply stop arriving when a sender disconnects, so without an
        // explicit signal the preview would keep showing the last frame.
        // A no-frames timeout would be simpler but blanks a live session
        // whenever a sender holds a static screen.
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        outputPipe = pipe

        let scanner = LogScanner(logHandle: handle) { streaming in
            Task { @MainActor in onStreamingChanged(streaming) }
        }
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            scanner.consume(fileHandle.availableData)
        }

        // The helper can die on its own -- GStreamer has aborted during
        // teardown after a sender disconnects. Nothing else notices: the
        // station simply stops receiving and disappears from AirPlay lists,
        // with no error anywhere. Report it so the tile can say so.
        p.terminationHandler = { finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished, !self.isStopping else {
                    return
                }
                self.process = nil
                onUnexpectedExit(finished.terminationStatus)
            }
        }

        isStopping = false
        try p.run()
        process = p
    }

    /// Mirrors UxPlay's output to the log file while watching for the lines
    /// that bracket an active mirroring stream. Runs off the main actor
    /// because `readabilityHandler` is called on a background queue.
    private final class LogScanner: @unchecked Sendable {
        private static let startMarker = "raop_rtp_mirror starting mirroring"
        // A sender that stops mirroring tears the stream down cleanly. One
        // that switches to a different receiver may just drop the connection,
        // so the teardown line never appears -- watch for the socket closing
        // too, or the tile freezes on the last frame it received.
        private static let stopMarkers = [
            "raop_rtp_mirror->running is no longer true",
            "Connection closed on socket",
        ]

        private let logHandle: FileHandle
        private let onStreamingChanged: (Bool) -> Void
        private var pending = Data()
        // Connections open and close during pairing, before any video flows.
        // Only report a stop for a stream that actually started.
        private var streaming = false

        init(logHandle: FileHandle,
             onStreamingChanged: @escaping (Bool) -> Void) {
            self.logHandle = logHandle
            self.onStreamingChanged = onStreamingChanged
        }

        func consume(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            try? logHandle.write(contentsOf: chunk)

            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(
                    data: pending[pending.startIndex..<newline], encoding: .utf8)
                pending.removeSubrange(pending.startIndex...newline)
                guard let line else { continue }
                if line.contains(Self.startMarker) {
                    streaming = true
                    onStreamingChanged(true)
                } else if streaming,
                          Self.stopMarkers.contains(where: line.contains) {
                    streaming = false
                    onStreamingChanged(false)
                }
            }
        }
    }

    func stopProjection() async {
        guard let p = process else {
            cleanUpOutput()
            return
        }
        isStopping = true
        p.interrupt()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                p.waitUntilExit()
                cont.resume()
            }
        }
        cleanUpOutput()
        process = nil
    }

    /// Drains whatever UxPlay wrote as it shut down, then detaches the handler
    /// so the pipe can be released. Safe to call when the helper already died.
    private func cleanUpOutput() {
        if let pipe = outputPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? pipe.fileHandleForReading.readToEnd(),
               !remaining.isEmpty {
                try? logHandle?.write(contentsOf: remaining)
            }
            outputPipe = nil
        }
        try? logHandle?.close()
        logHandle = nil
    }

    static func canResolveUxPlay(developmentPath: String) -> Bool {
        (try? resolveUxPlayURL(developmentPath: developmentPath)) != nil
    }

    private static func resolveUxPlayURL(developmentPath: String) throws -> URL {
        if let url = RuntimePaths.executable(
            bundledName: "uxplay",
            environmentKey: "UXPLAY_PATH",
            developmentPath: developmentPath,
            fallbackNames: ["uxplay"]
        ) {
            return url
        }

        throw StudyCastError("找不到 uxplay helper。请安装 release 包或设置 UXPLAY_PATH。")
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

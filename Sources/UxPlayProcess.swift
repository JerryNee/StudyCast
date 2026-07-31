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

    /// Discovery profile every station runs.
    ///
    /// `p2p` registers the receiver over Apple peer-to-peer (AWDL) in addition
    /// to the normal interfaces, while leaving UxPlay's own advertisement
    /// untouched. That combination is what lets a sender reach StudyCast
    /// directly, with no managed-network registration, and still negotiate the
    /// legacy FairPlay media setup UxPlay can decrypt.
    ///
    /// The `mac-*` profiles impersonate a Mac receiver. They also win AWDL,
    /// but a Mac identity makes senders switch to the AP2 media path, which
    /// omits the legacy ekey and derives the media key by an unpublished
    /// route -- video then arrives but cannot be decrypted. They are kept for
    /// research only; see docs/AP2_MIRRORING_KEY_SEARCH.md.
    static let discoveryProfile = ProcessInfo.processInfo
        .environment["STUDYCAST_DISCOVERY_PROFILE"] ?? "p2p"

    private var process: Process?
    private var logHandle: FileHandle?
    private var outputPipe: Pipe?

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
               onStreamingChanged: @escaping (Bool) -> Void) throws {
        guard process == nil else { return }

        let p = Process()
        p.executableURL = try Self.resolveUxPlayURL(developmentPath: uxplayPath)
        // Only the research "mac-*" profiles impersonate a Mac receiver. The
        // default "p2p" profile keeps the station's own name, Device ID and
        // ports so the sender sees a plain UxPlay receiver and negotiates the
        // legacy media setup.
        let usesMacIdentity =
            useMacWireIdentity && Self.discoveryProfile.hasPrefix("mac")
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
        // Every station registers over Apple peer-to-peer. This is what lets a
        // sender reach StudyCast without the network operator registering the
        // receiver first.
        env["UXPLAY_DISCOVERY_PROFILE"] = Self.discoveryProfile
        // Registering over AWDL is not enough on its own: a conventional BSD
        // listener drops traffic delivered by that interface unless it opts in,
        // so the receiver would be visible but never see the connection.
        env["UXPLAY_AWDL_RECV_ANYIF"] = "1"
        if useMacWireIdentity {
            // Research path only: Mac-identity profiles push the sender onto
            // the AP2 media setup, which omits the legacy ekey. Dump the
            // session material and first encrypted payloads so
            // scripts/ap2_key_search.py can search for the media key offline.
            env["UXPLAY_HKP_MEDIA_KEY_MODE"] = "fairplay"
            env["UXPLAY_AP2_CAPTURE"] = mp4Base.path + Self.ap2CaptureSuffix
        } else {
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
        guard let p = process else { return }
        p.interrupt()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                p.waitUntilExit()
                cont.resume()
            }
        }
        // Drain whatever UxPlay wrote as it shut down, then detach the handler
        // so the pipe can be released.
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
        process = nil
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

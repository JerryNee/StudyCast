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
               mp4Base: URL) throws {
        guard process == nil else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: uxplayPath)
        p.arguments = [
            "-n", name,
            "-nh",
            "-p", "\(basePort)",
            "-m", mac,
            "-vsync", "no",
            "-mp4", mp4Base.path,
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
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

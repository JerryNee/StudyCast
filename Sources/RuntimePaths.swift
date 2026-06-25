//
//  RuntimePaths.swift
//  StudyCast
//
//  Resolves bundled helper binaries first, then developer-provided paths.
//

import Foundation

enum RuntimePaths {
    static let helperDirectory = Bundle.main.bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Helpers", isDirectory: true)

    static func helper(named name: String) -> URL {
        helperDirectory.appendingPathComponent(name)
    }

    static func executable(
        bundledName: String,
        environmentKey: String,
        developmentPath: String? = nil,
        fallbackNames: [String] = []
    ) -> URL? {
        let bundled = helper(named: bundledName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let envPath = ProcessInfo.processInfo.environment[environmentKey]
        if let envPath, FileManager.default.isExecutableFile(atPath: envPath) {
            return URL(fileURLWithPath: envPath)
        }

        if let developmentPath,
           !developmentPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: developmentPath) {
            return URL(fileURLWithPath: developmentPath)
        }

        for candidate in fallbackNames.flatMap(Self.pathCandidates(named:)) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    static func pathEnvironment(with extraDirectories: [URL] = []) -> String {
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let prefixes = (extraDirectories + [helperDirectory])
            .map(\.path)
            .filter { !$0.isEmpty }
        return (prefixes + [existing]).joined(separator: ":")
    }

    private static func pathCandidates(named name: String) -> [String] {
        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
    }
}

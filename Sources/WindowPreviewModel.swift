//
//  WindowPreviewModel.swift
//  Captures one UxPlay window for a station tile preview.
//

import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

final class WindowPreviewModel: NSObject, ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var statusText = "未开始"

    private var stream: SCStream?
    private var retryTask: Task<Void, Never>?
    private let sampleQueue = DispatchQueue(label: "StudyCast.WindowPreviewModel.sample")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func start(processID: pid_t, expectedTitle: String) {
        stop()
        update(image: nil, statusText: "等待投屏窗口")

        retryTask = Task { [weak self] in
            await self?.captureLoop(processID: processID, expectedTitle: expectedTitle)
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil

        let runningStream = stream
        stream = nil
        if let runningStream {
            Task {
                try? await runningStream.stopCapture()
            }
        }

        update(image: nil, statusText: "未开始")
    }

    private func captureLoop(processID: pid_t, expectedTitle: String) async {
        while !Task.isCancelled {
            do {
                if let window = try await findUxPlayWindow(processID: processID, expectedTitle: expectedTitle) {
                    try await startCapture(window: window)
                    return
                }
                update(image: nil, statusText: "等待 UxPlay 窗口")
            } catch {
                update(image: nil, statusText: previewErrorMessage(for: error))
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func findUxPlayWindow(processID: pid_t, expectedTitle: String) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == processID
        }

        return windows.sorted { lhs, rhs in
            windowScore(lhs, expectedTitle: expectedTitle) > windowScore(rhs, expectedTitle: expectedTitle)
        }.first
    }

    private func windowScore(_ window: SCWindow, expectedTitle: String) -> Int {
        let title = window.title ?? ""
        let area = window.frame.width * window.frame.height
        var score = area > 10_000 ? 10 : 0
        if title.localizedCaseInsensitiveContains(expectedTitle) {
            score += 100
        }
        if title.localizedCaseInsensitiveContains("UxPlay") {
            score += 20
        }
        return score
    }

    private func startCapture(window: SCWindow) async throws {
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = max(640, Int(window.frame.width * scale))
        configuration.height = max(360, Int(window.frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        try await newStream.startCapture()

        update(image: nil, statusText: "等待画面")
    }

    private func update(image: CGImage?, statusText: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.image = image
            if let statusText {
                self?.statusText = statusText
            }
        }
    }

    private func previewErrorMessage(for error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("denied")
            || text.localizedCaseInsensitiveContains("permission")
            || text.localizedCaseInsensitiveContains("authorized") {
            return "需要屏幕录制权限"
        }
        return "预览不可用"
    }
}

extension WindowPreviewModel: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        update(image: cgImage, statusText: nil)
    }
}

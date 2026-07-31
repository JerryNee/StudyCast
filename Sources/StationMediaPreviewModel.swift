//
//  StationMediaPreviewModel.swift
//  StudyCast
//
//  Receives one station's local RTP preview stream through GStreamer.
//

import CoreGraphics
import Foundation

@MainActor
final class StationMediaPreviewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var statusText = "未开始"
    @Published private(set) var audioOutputStatusText: String?
    @Published var isMuted = false {
        didSet {
            engine.setMuted(isMuted)
        }
    }
    @Published var volume = 1.0 {
        didSet {
            let clamped = max(0, min(volume, 1))
            if clamped != volume {
                volume = clamped
                return
            }
            engine.setVolume(clamped)
        }
    }

    private let engine = GStreamerPreviewEngine()
    private var ports: StationMediaPorts?

    func start(ports: StationMediaPorts, audioOutputDeviceID: Int?) {
        stop()
        self.ports = ports
        statusText = "等待视频流"
        audioOutputStatusText = audioOutputDeviceID == nil ? "输出设备不可用" : nil
        engine.setMuted(isMuted)
        engine.setVolume(volume)

        let started = engine.start(
            withVideoPort: ports.videoRTP,
            audioPort: ports.audioRTP,
            audioOutputDeviceID: audioOutputDeviceID ?? -1,
            onFrame: { [weak self] frame in
                Task { @MainActor in
                    self?.image = frame
                    self?.statusText = "投屏接收中"
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    if message.hasPrefix("音频输出不可用") {
                        self?.audioOutputStatusText = message
                        return
                    }
                    self?.image = nil
                    self?.statusText = message
                }
            }
        )

        if !started {
            statusText = "预览不可用"
        }
    }

    /// Drops the displayed frame while leaving the receiver running, so the
    /// tile returns to its waiting state instead of freezing on the last frame
    /// a disconnected sender happened to send.
    func clearFrame() {
        guard ports != nil else { return }
        image = nil
        statusText = "等待视频流"
    }

    func setAudioOutputDeviceID(_ audioOutputDeviceID: Int?) {
        audioOutputStatusText = audioOutputDeviceID == nil ? "输出设备不可用" : nil
        guard ports != nil else { return }

        let restarted = engine.restartAudio(withOutputDeviceID: audioOutputDeviceID ?? -1)
        if !restarted {
            audioOutputStatusText = "音频输出不可用"
        }
    }

    func stop() {
        engine.stop()
        ports = nil
        image = nil
        audioOutputStatusText = nil
        statusText = "未开始"
    }
}

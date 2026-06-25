//
//  StudyCastApp.swift
//  StudyCast — record multiple Vision Pro first-person POVs at once.
//
//  Orchestrates one UxPlay (AirPlay-2 mirror receiver) subprocess per headset,
//  each recording its own MP4 via UxPlay's built-in `-mp4`. See project plan:
//  ~/.claude/plans/reflector-distributed-floyd.md
//

import SwiftUI

@main
struct StudyCastApp: App {
    @StateObject private var model = AppModel()

    init() {
        GStreamerPreviewEngine.configureRuntimeEnvironment()
    }

    var body: some Scene {
        WindowGroup("StudyCast") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
    }
}
